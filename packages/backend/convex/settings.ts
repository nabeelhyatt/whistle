import { v } from "convex/values";
import {
  internalMutation,
  mutation,
  query,
  type MutationCtx,
} from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { requireUser } from "./lib/auth";
import type { ConductorCreds, ConductorEnvironment } from "./conductorClient";

const DEFAULT_AGENT = "claude";
const DEFAULT_SCREENSHOTS_ENABLED = true;

function normalizedEnvironment(
  conductorEnvironment: string | undefined,
): ConductorEnvironment {
  return conductorEnvironment === "staging" ? "staging" : "prod";
}

/** Exported for reuse by admin.ts's `accountReport` (masked lastFour). The
 * base URL is not a secret, so `environment` is included alongside the
 * masked key fields — only `conductorApiKey` itself stays stripped. */
export function maskedKeyFields(
  conductorApiKey: string | undefined,
  conductorEnvironment?: string,
) {
  return {
    hasKey: conductorApiKey !== undefined && conductorApiKey.length > 0,
    lastFour:
      conductorApiKey !== undefined && conductorApiKey.length > 0
        ? conductorApiKey.slice(-4)
        : undefined,
    environment: normalizedEnvironment(conductorEnvironment),
  };
}

/**
 * Builds `ConductorCreds` from a settings row, defaulting an absent
 * `conductorEnvironment` to `"prod"` (KTD5 — the one place this default
 * lives; every stored-key read path uses this instead of re-deriving it).
 * Returns `undefined` when the row has no key at all.
 */
export function credsFromSettings(
  row:
    | { conductorApiKey?: string; conductorEnvironment?: string }
    | null
    | undefined,
): ConductorCreds | undefined {
  const apiKey = row?.conductorApiKey;
  if (apiKey === undefined || apiKey.length === 0) return undefined;
  return { apiKey, environment: normalizedEnvironment(row?.conductorEnvironment) };
}

/**
 * Returns the calling user's settings. `conductorApiKey` is NEVER included —
 * only a `hasKey` boolean and the last four characters, so the raw key never
 * reaches the client (TECH-SPEC §9).
 */
export const get = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const row = await ctx.db
      .query("settings")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .unique();

    if (row === null) {
      return {
        defaultProjectId: undefined,
        agent: DEFAULT_AGENT,
        model: undefined,
        screenshotsEnabled: DEFAULT_SCREENSHOTS_ENABLED,
        ...maskedKeyFields(undefined),
      };
    }

    const {
      conductorApiKey,
      conductorEnvironment,
      userId: _userId,
      ...rest
    } = row;
    return {
      ...rest,
      ...maskedKeyFields(conductorApiKey, conductorEnvironment),
    };
  },
});

/**
 * Updates non-secret settings fields. If no settings row exists yet, creates
 * one with defaults (`agent: "claude"`, `screenshotsEnabled: true`) merged
 * with whatever fields were passed.
 */
export const update = mutation({
  args: {
    // `defaultProjectId`/`model` are tri-state: the key absent (`undefined`)
    // means "leave untouched", an explicit `null` means "clear it", and a
    // string means "set it". This is what lets the client's "clear" UI
    // affordances (empty model field, deselecting the default project)
    // actually clear the field instead of being silent no-ops — a plain
    // `v.optional(v.string())` can't distinguish "not sent" from "send null
    // to clear" since both collapse to `undefined` on the wire.
    defaultProjectId: v.optional(v.union(v.string(), v.null())),
    agent: v.optional(v.string()),
    model: v.optional(v.union(v.string(), v.null())),
    screenshotsEnabled: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const existing = await ctx.db
      .query("settings")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .unique();

    if (existing === null) {
      await ctx.db.insert("settings", {
        userId: user._id,
        agent: args.agent ?? DEFAULT_AGENT,
        // No existing row to clear, so `null` and `undefined` both just mean
        // "no value" here.
        model: args.model ?? undefined,
        defaultProjectId: args.defaultProjectId ?? undefined,
        screenshotsEnabled:
          args.screenshotsEnabled ?? DEFAULT_SCREENSHOTS_ENABLED,
      });
      return;
    }

    await ctx.db.patch(existing._id, {
      // `ctx.db.patch(id, { field: undefined })` unsets `field`; omitting
      // the key entirely leaves it untouched. So an explicit `null` maps to
      // `undefined` here (unset), while `undefined` args stay omitted from
      // the patch object (untouched).
      ...(args.defaultProjectId !== undefined && {
        defaultProjectId:
          args.defaultProjectId === null ? undefined : args.defaultProjectId,
      }),
      ...(args.agent !== undefined && { agent: args.agent }),
      ...(args.model !== undefined && {
        model: args.model === null ? undefined : args.model,
      }),
      ...(args.screenshotsEnabled !== undefined && {
        screenshotsEnabled: args.screenshotsEnabled,
      }),
    });
  },
});

/** Exported for reuse by `projects.setAndValidateKey`'s single atomic
 * mutation, which patches settings + upserts projectsCache in one
 * transaction (KTD3) and so needs direct `ctx.db` access to this rather than
 * a separate `ctx.runMutation`. */
export async function patchConductorKey(
  ctx: MutationCtx,
  userId: Id<"users">,
  conductorApiKey: string,
  conductorEnvironment: ConductorEnvironment,
): Promise<void> {
  const existing = await ctx.db
    .query("settings")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .unique();

  if (existing === null) {
    await ctx.db.insert("settings", {
      userId,
      conductorApiKey,
      conductorEnvironment,
      agent: DEFAULT_AGENT,
      screenshotsEnabled: DEFAULT_SCREENSHOTS_ENABLED,
    });
    return;
  }

  await ctx.db.patch(existing._id, {
    conductorApiKey,
    conductorEnvironment,
  });
}

/**
 * Stores (or replaces) the caller's Conductor API key and the environment it
 * was probed against, keyed by `userId` — used from `projects.setAndValidateKey`
 * (which folds this into its single atomic mutation, KTD3) and by tests that
 * need to seed a key directly. There is deliberately no public mutation for
 * this: entering/replacing a key must go through the probe-before-store path
 * in `projects.setAndValidateKey`, never write the key straight to storage
 * (clean break, KTD6).
 */
export const setConductorKeyInternal = internalMutation({
  args: {
    userId: v.id("users"),
    conductorApiKey: v.string(),
    conductorEnvironment: v.union(v.literal("prod"), v.literal("staging")),
  },
  handler: async (ctx, args) => {
    await patchConductorKey(
      ctx,
      args.userId,
      args.conductorApiKey,
      args.conductorEnvironment,
    );
  },
});
