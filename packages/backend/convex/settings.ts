import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireUser } from "./lib/auth";

const DEFAULT_AGENT = "claude";
const DEFAULT_SCREENSHOTS_ENABLED = true;

function maskedKeyFields(conductorApiKey: string | undefined) {
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
    defaultProjectId: v.optional(v.string()),
    agent: v.optional(v.string()),
    model: v.optional(v.string()),
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
        model: args.model,
        defaultProjectId: args.defaultProjectId,
        screenshotsEnabled:
          args.screenshotsEnabled ?? DEFAULT_SCREENSHOTS_ENABLED,
      });
      return;
    }

    await ctx.db.patch(existing._id, {
      ...(args.defaultProjectId !== undefined && {
        defaultProjectId: args.defaultProjectId,
      }),
      ...(args.agent !== undefined && { agent: args.agent }),
      ...(args.model !== undefined && { model: args.model }),
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
