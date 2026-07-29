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
import {
  listAllProjects,
  resolveConductorEnvironment,
  ConductorApiError,
  type ConductorEnvironment,
} from "./conductorClient";
import { credsFromSettings } from "./settings";

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

export const getProjectsCacheForUserInternal = internalQuery({
  args: { userId: v.id("users") },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("projectsCache")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .unique();
  },
});

/**
 * True when a previously-cached project set exists AND its project ids differ
 * from the newly-fetched set — i.e. this key can see a different set of
 * Conductor projects than the last key did. Order-independent. Returns false
 * when there is no prior cache (first key, nothing to compare against), so
 * onboarding never shows a spurious "changed" warning.
 */
function projectSetChanged(
  previous: { id: string }[] | undefined,
  next: { id: string }[],
): boolean {
  if (previous === undefined) return false;
  const prevIds = [...new Set(previous.map((p) => p.id))].sort();
  const nextIds = [...new Set(next.map((p) => p.id))].sort();
  if (prevIds.length !== nextIds.length) return true;
  return prevIds.some((id, i) => id !== nextIds[i]);
}

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
 * Re-checks the caller's *stored* Conductor key via `GET /v0/projects`
 * against its stored environment (`credsFromSettings`) and, on success,
 * refreshes `projectsCache`. Drops the old `apiKey` arg (KTD6, clean break)
 * — entering/replacing a key now goes through `setAndValidateKey` below,
 * which is the only path that can change what's stored.
 */
export const validateKey = action({
  args: {},
  handler: async (
    ctx,
  ): Promise<{ ok: boolean; error?: string; changedFromPrevious?: boolean }> => {
    const user = await ctx.runQuery(internal.users.getSelfInternal, {});
    if (user === null) {
      return { ok: false, error: "Not authenticated" };
    }

    const settingsRow = await ctx.runQuery(
      internal.projects.getSettingsForUserInternal,
      { userId: user._id },
    );
    const creds = credsFromSettings(settingsRow ?? undefined);

    if (creds === undefined) {
      return { ok: false, error: "No API key provided or stored." };
    }

    try {
      // Capture the prior project set before overwriting the cache, so we can
      // tell the client whether this key sees a different set of Conductor
      // projects than the last one — a cheap proxy (there is no whoami
      // endpoint) for "this key may belong to a different Conductor account."
      const previous = await ctx.runQuery(
        internal.projects.getProjectsCacheForUserInternal,
        { userId: user._id },
      );
      const projects = await listAllProjects(creds, { limit: 50 });
      const changedFromPrevious = projectSetChanged(
        previous?.projects,
        projects,
      );
      await ctx.runMutation(internal.projects.writeProjectsCacheInternal, {
        userId: user._id,
        projects,
      });
      return { ok: true, changedFromPrevious };
    } catch (err) {
      if (err instanceof ConductorApiError) {
        return { ok: false, error: err.userMessage };
      }
      return { ok: false, error: (err as Error).message };
    }
  },
});

/** Refreshes the project cache using the caller's stored key + environment. */
export const refreshProjects = action({
  args: {},
  handler: async (ctx): Promise<{ ok: boolean; error?: string }> => {
    const user = await ctx.runQuery(internal.users.getSelfInternal, {});
    if (user === null) {
      return { ok: false, error: "Not authenticated" };
    }

    const settingsRow = await ctx.runQuery(
      internal.projects.getSettingsForUserInternal,
      { userId: user._id },
    );
    const creds = credsFromSettings(settingsRow ?? undefined);
    if (creds === undefined) {
      return { ok: false, error: "No API key configured." };
    }

    try {
      const projects = await listAllProjects(creds, { limit: 50 });
      await ctx.runMutation(internal.projects.writeProjectsCacheInternal, {
        userId: user._id,
        projects,
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

/**
 * Copy for setAndValidateKey's failure result (R7) — distinguishes a
 * rejected key from an unreachable host.
 */
const INVALID_KEY_MESSAGE =
  "Conductor didn't accept that key. Check that you copied the whole key.";
const NETWORK_UNREACHABLE_MESSAGE =
  "Couldn't reach Conductor. Check your connection and try again.";

/**
 * One atomic action (KTD3): probes both Conductor hosts for `apiKey`
 * (`resolveConductorEnvironment`), and only on success stores the key +
 * detected environment together with a single mutation, seeding
 * `projectsCache` from the probe's own already-fetched project list (no
 * second projects fetch). On failure, nothing is stored — the previously
 * working key (if any) is left exactly as it was.
 */
export const setAndValidateKey = action({
  args: { apiKey: v.string() },
  handler: async (
    ctx,
    args,
  ): Promise<
    | { ok: true; environment: ConductorEnvironment; projectsChanged: boolean }
    | { ok: false; error: string }
  > => {
    const user = await ctx.runQuery(internal.users.getSelfInternal, {});
    if (user === null) {
      return { ok: false, error: "Not authenticated" };
    }

    if (args.apiKey.length === 0) {
      return { ok: false, error: INVALID_KEY_MESSAGE };
    }

    const resolved = await resolveConductorEnvironment(args.apiKey);
    if (!resolved.ok) {
      return {
        ok: false,
        error:
          resolved.reason === "network"
            ? NETWORK_UNREACHABLE_MESSAGE
            : INVALID_KEY_MESSAGE,
      };
    }

    // Capture the prior project set before overwriting the cache, same
    // cross-account signal validateKey has always carried
    // (`projectSetChanged`/`ConductorValidateResult.projectsChanged`).
    const previous = await ctx.runQuery(
      internal.projects.getProjectsCacheForUserInternal,
      { userId: user._id },
    );
    const projectsChanged = projectSetChanged(previous?.projects, resolved.projects);

    await ctx.runMutation(internal.settings.setConductorKeyInternal, {
      userId: user._id,
      conductorApiKey: args.apiKey,
      conductorEnvironment: resolved.environment,
    });
    await ctx.runMutation(internal.projects.writeProjectsCacheInternal, {
      userId: user._id,
      projects: resolved.projects,
    });

    return { ok: true, environment: resolved.environment, projectsChanged };
  },
});
