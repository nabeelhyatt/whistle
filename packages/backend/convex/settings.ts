import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireUser } from "./lib/auth";

const DEFAULT_AGENT = "claude";
const DEFAULT_SCREENSHOTS_ENABLED = true;

/** Exported for reuse by admin.ts's `accountReport` (masked lastFour). */
export function maskedKeyFields(conductorApiKey: string | undefined) {
  return {
    hasKey: conductorApiKey !== undefined && conductorApiKey.length > 0,
    lastFour:
      conductorApiKey !== undefined && conductorApiKey.length > 0
        ? conductorApiKey.slice(-4)
        : undefined,
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
        ...maskedKeyFields(undefined),
      };
    }

    const { conductorApiKey, userId: _userId, ...rest } = row;
    return {
      ...rest,
      ...maskedKeyFields(conductorApiKey),
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

/**
 * Stores (or replaces) the caller's Conductor API key. Creates the settings
 * row with defaults if one doesn't exist yet.
 */
export const setConductorKey = mutation({
  args: { conductorApiKey: v.string() },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const existing = await ctx.db
      .query("settings")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .unique();

    if (existing === null) {
      await ctx.db.insert("settings", {
        userId: user._id,
        conductorApiKey: args.conductorApiKey,
        agent: DEFAULT_AGENT,
        screenshotsEnabled: DEFAULT_SCREENSHOTS_ENABLED,
      });
      return;
    }

    await ctx.db.patch(existing._id, {
      conductorApiKey: args.conductorApiKey,
    });
  },
});
