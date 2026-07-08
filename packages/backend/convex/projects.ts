// Conductor project listing + key validation — TECH-SPEC §7.
//
// The app never holds the Conductor key; project listing goes through this
// backend cache (`projectsCache` table) so the client only ever sees
// already-fetched project metadata.

import { v } from "convex/values";
import { action, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { internalMutation, internalQuery } from "./_generated/server";
import { requireUser } from "./lib/auth";
import { listProjects, ConductorApiError } from "./conductorClient";

/** Both actions below resolve the caller via `users.getSelfInternal` since
 * actions don't have direct `ctx.db` access and `requireUser` is a
 * QueryCtx/MutationCtx-only helper (see lib/auth.ts). */

/** Cached projects for the calling user — client persists the latest yield
 * into GRDB for offline picker use. */
export const list = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const row = await ctx.db
      .query("projectsCache")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .unique();
    return row?.projects ?? [];
  },
});

export const getSettingsForUserInternal = internalQuery({
  args: { userId: v.id("users") },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("settings")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .unique();
  },
});

export const writeProjectsCacheInternal = internalMutation({
  args: {
    userId: v.id("users"),
    projects: v.array(
      v.object({ id: v.string(), name: v.string(), gitRemote: v.string() }),
    ),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("projectsCache")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .unique();
    if (existing === null) {
      await ctx.db.insert("projectsCache", {
        userId: args.userId,
        projects: args.projects,
        fetchedAt: Date.now(),
      });
    } else {
      await ctx.db.patch(existing._id, {
        projects: args.projects,
        fetchedAt: Date.now(),
      });
    }
  },
});

/**
 * Validates a Conductor API key via `GET /v0/projects` and, on success,
 * refreshes `projectsCache`. Accepts an explicit key (for the onboarding
 * "validate before saving" flow) or falls back to the caller's stored key.
 */
export const validateKey = action({
  args: { apiKey: v.optional(v.string()) },
  handler: async (ctx, args): Promise<{ ok: boolean; error?: string }> => {
    const user = await ctx.runQuery(internal.users.getSelfInternal, {});
    if (user === null) {
      return { ok: false, error: "Not authenticated" };
    }

    let apiKey = args.apiKey;
    if (apiKey === undefined) {
      const settings = await ctx.runQuery(internal.projects.getSettingsForUserInternal, {
        userId: user._id,
      });
      apiKey = settings?.conductorApiKey;
    }

    if (apiKey === undefined || apiKey.length === 0) {
      return { ok: false, error: "No API key provided or stored." };
    }

    try {
      const result = await listProjects(apiKey, { limit: 50 });
      await ctx.runMutation(internal.projects.writeProjectsCacheInternal, {
        userId: user._id,
        projects: result.data,
      });
      return { ok: true };
    } catch (err) {
      if (err instanceof ConductorApiError) {
        return { ok: false, error: err.userMessage };
      }
      return { ok: false, error: (err as Error).message };
    }
  },
});

/** Refreshes the project cache using the caller's stored key. */
export const refreshProjects = action({
  args: {},
  handler: async (ctx): Promise<{ ok: boolean; error?: string }> => {
    const user = await ctx.runQuery(internal.users.getSelfInternal, {});
    if (user === null) {
      return { ok: false, error: "Not authenticated" };
    }

    const settings = await ctx.runQuery(internal.projects.getSettingsForUserInternal, {
      userId: user._id,
    });
    const apiKey = settings?.conductorApiKey;
    if (apiKey === undefined || apiKey.length === 0) {
      return { ok: false, error: "No API key configured." };
    }

    try {
      const result = await listProjects(apiKey, { limit: 50 });
      await ctx.runMutation(internal.projects.writeProjectsCacheInternal, {
        userId: user._id,
        projects: result.data,
      });
      return { ok: true };
    } catch (err) {
      if (err instanceof ConductorApiError) {
        return { ok: false, error: err.userMessage };
      }
      return { ok: false, error: (err as Error).message };
    }
  },
});
