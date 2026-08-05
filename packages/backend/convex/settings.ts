import { v } from "convex/values";
import {
  internalMutation,
  mutation,
  query,
  type MutationCtx,
} from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import { requireUser } from "./lib/auth";
import type { ConductorCreds, ConductorEnvironment } from "./conductorClient";
import { orgsForUser, shimTargetOrg } from "./orgs";

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
 * Old-client compatibility after the multi-org migration: once the legacy
 * `settings.conductorApiKey` is unset and the key lives on a `conductorOrgs`
 * row, shipped single-key clients still need the full masked triple —
 * `hasKey` drives onboarding gates, `lastFour` renders the masked key
 * display, and `environment` picks the staging-vs-prod dashboard link. So
 * when the legacy fields are empty, synthesize all three from the shim
 * target org row (`shimTargetOrg` — same row the setAndValidateKey shim
 * would replace).
 */
async function maskedKeyFieldsWithOrgFallback(
  ctx: Parameters<typeof orgsForUser>[0],
  userId: Id<"users">,
  row: { conductorApiKey?: string; conductorEnvironment?: string } | null,
) {
  const legacy = maskedKeyFields(
    row?.conductorApiKey,
    row?.conductorEnvironment,
  );
  if (legacy.hasKey) return legacy;

  const orgs = await orgsForUser(ctx, userId);
  const target = shimTargetOrg(orgs);
  if (target === undefined) return legacy;
  return {
    hasKey: true,
    lastFour: target.conductorApiKey.slice(-4),
    environment: target.conductorEnvironment,
  };
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
        ...(await maskedKeyFieldsWithOrgFallback(ctx, user._id, null)),
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
      ...(await maskedKeyFieldsWithOrgFallback(ctx, user._id, {
        conductorApiKey,
        conductorEnvironment,
      })),
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
 * Lazy one-shot migration of the single-key era: moves the legacy
 * `settings.conductorApiKey`/`conductorEnvironment` onto a `conductorOrgs`
 * row labeled "Default", repoints the legacy no-org `projectsCache` row, and
 * unsets the legacy fields — all in the calling mutation's transaction, so
 * there is never a window with neither key. Runs from `users.ensure` on
 * every launch; idempotent (no-op once org rows exist or no legacy key is
 * stored).
 *
 * KEEP THIS MINIMAL: a throw here fails `users.ensure`, which the client
 * surfaces as `.reauthRequired` at launch (AuthController never swallows
 * ensure errors) and rolls back ensure's own email backfill.
 */
const NON_TERMINAL_CAPTURE_STATUSES = new Set([
  "queued",
  "creating",
  "sending",
  "agentWorking",
  "readyUnverified",
]);

export async function migrateLegacyKeyToOrg(
  ctx: MutationCtx,
  userId: Id<"users">,
): Promise<void> {
  const row = await ctx.db
    .query("settings")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .unique();
  const creds = credsFromSettings(row ?? undefined);
  if (row === null || creds === undefined) return;

  const existingOrg = await ctx.db
    .query("conductorOrgs")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .first();

  if (existingOrg !== null) {
    // Coexistence state (F1): org rows already exist — reachable via an
    // admin merge that moved org rows onto this user before their next
    // relaunch, or an old-client setAndValidateKey racing first-launch
    // ensure — but the legacy settings key is still set too. Left alone it
    // would permanently shadow the org store: every orgId-less capture
    // would keep resolving the stale legacy key forever, settings.get would
    // show the stale masked triple, and validateKey would re-create a
    // legacy no-org cache row. Just clear it; never insert a second org row
    // here (credsForCaptureInternal only reads legacy settings when the
    // user has zero org rows).
    await ctx.db.patch(row._id, {
      conductorApiKey: undefined,
      conductorEnvironment: undefined,
    });
    console.log(`legacy-key-cleared-coexistence userId=${userId}`);
    return;
  }

  const orgId = await ctx.db.insert("conductorOrgs", {
    userId,
    label: "Default",
    conductorApiKey: creds.apiKey,
    conductorEnvironment: creds.environment,
    createdAt: Date.now(),
  });

  const legacyCache = await ctx.db
    .query("projectsCache")
    .withIndex("by_user_org", (q) => q.eq("userId", userId).eq("orgId", undefined))
    .unique();
  if (legacyCache !== null) {
    await ctx.db.patch(legacyCache._id, { orgId });
  }

  // F2: pin the new org row onto the caller's own in-flight (non-terminal,
  // still orgId-less) captures too, closing the ≤1h window where a
  // duplicate projectId across orgs could misroute a capture mid-flight.
  // Bounded and best-effort — a throw here would lock users out at launch
  // (see file header), so this never fails the migration.
  const recentCaptures = await ctx.db
    .query("captures")
    .withIndex("by_user_time", (q) => q.eq("userId", userId))
    .order("desc")
    .take(50);
  for (const capture of recentCaptures) {
    if (capture.orgId !== undefined) continue;
    if (!NON_TERMINAL_CAPTURE_STATUSES.has(capture.status)) continue;
    await ctx.db.patch(capture._id, { orgId });
  }

  await ctx.db.patch(row._id, {
    conductorApiKey: undefined,
    conductorEnvironment: undefined,
  });

  // Greppable marker (account-split-detected precedent, users.ts) so log
  // streaming can watch migration progress and alert on anomalies.
  console.log(
    `legacy-key-migrated userId=${userId} environment=${creds.environment}`,
  );
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
