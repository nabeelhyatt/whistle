// Conductor project listing + key validation — TECH-SPEC §7.
//
// The app never holds the Conductor key; project listing goes through this
// backend cache (`projectsCache` table, one row per org key) so the client
// only ever sees already-fetched project metadata.
//
// `setAndValidateKey`/`validateKey` survive as back-compat shims for shipped
// single-key clients — new clients use orgs.addKey and friends (orgs.ts).

import { v } from "convex/values";
import { action, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { internalMutation, internalQuery } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { requireUser } from "./lib/auth";
import {
  listAllProjects,
  getMe,
  resolveConductorEnvironment,
  ConductorApiError,
  type ConductorEnvironment,
} from "./conductorClient";
import { credsFromSettings } from "./settings";
import {
  INVALID_KEY_MESSAGE,
  NETWORK_UNREACHABLE_MESSAGE,
  orgDisplayName,
  orgsForUser,
  projectSetChanged,
  shimTargetOrg,
  upsertOrgProjectsCache,
} from "./orgs";

/** Both actions below resolve the caller via `users.getSelfInternal` since
 * actions don't have direct `ctx.db` access and `requireUser` is a
 * QueryCtx/MutationCtx-only helper (see lib/auth.ts). */

/**
 * Cached projects for the calling user, merged across all org caches —
 * client persists the latest yield into GRDB for offline picker use.
 *
 * Each item carries `orgId`/`orgLabel` (display name) so the picker can group
 * by org; a legacy pre-migration cache row contributes items with both
 * undefined, which old and new clients alike render ungrouped (added optional
 * fields are ignored by shipped clients' Codable decoding — no wire break).
 *
 * Groups are ordered legacy-first then org `createdAt`; within a group,
 * cache order is preserved (what Conductor returned — same as the single-key
 * era). Duplicate project ids across rows (two keys for one org, possible
 * when GET /me was unavailable for dedupe) collapse to the first occurrence:
 * `Project` is Identifiable by project id on the client and duplicate ids in
 * a SwiftUI ForEach is undefined behavior.
 */
export const list = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const cacheRows = await ctx.db
      .query("projectsCache")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .collect();
    if (cacheRows.length === 0) return [];

    const orgs = await orgsForUser(ctx, user._id);
    const orgOrder = new Map(orgs.map((org, i) => [org._id, i]));
    const orgById = new Map(orgs.map((org) => [org._id, org]));

    const ordered = cacheRows.sort((a, b) => {
      const ai = a.orgId === undefined ? -1 : (orgOrder.get(a.orgId) ?? Number.MAX_SAFE_INTEGER);
      const bi = b.orgId === undefined ? -1 : (orgOrder.get(b.orgId) ?? Number.MAX_SAFE_INTEGER);
      return ai - bi;
    });

    const seen = new Set<string>();
    const merged: Array<{
      id: string;
      name: string;
      gitRemote: string;
      orgId?: Id<"conductorOrgs">;
      orgLabel?: string;
    }> = [];
    for (const row of ordered) {
      const org = row.orgId === undefined ? undefined : orgById.get(row.orgId);
      for (const project of row.projects) {
        if (seen.has(project.id)) continue;
        seen.add(project.id);
        merged.push({
          ...project,
          orgId: org?._id,
          orgLabel: org === undefined ? undefined : orgDisplayName(org),
        });
      }
    }
    return merged;
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

/** One org's cache row (or the legacy no-org row when `orgId` is absent).
 * Always pinned on by_user_org — `.unique()` on by_user alone throws once a
 * user has 2+ cache rows. */
export const getProjectsCacheForUserInternal = internalQuery({
  args: {
    userId: v.id("users"),
    orgId: v.optional(v.id("conductorOrgs")),
  },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("projectsCache")
      .withIndex("by_user_org", (q) =>
        q.eq("userId", args.userId).eq("orgId", args.orgId),
      )
      .unique();
  },
});

export const writeProjectsCacheInternal = internalMutation({
  args: {
    userId: v.id("users"),
    orgId: v.optional(v.id("conductorOrgs")),
    projects: v.array(
      v.object({ id: v.string(), name: v.string(), gitRemote: v.string() }),
    ),
  },
  handler: async (ctx, args) => {
    await upsertOrgProjectsCache(ctx, args.userId, args.orgId, args.projects);
  },
});

/**
 * Old-client shim: re-checks a *stored* Conductor key via `GET /v0/projects`
 * against its stored environment and, on success, refreshes that org's
 * projectsCache. Pre-migration users validate the legacy settings key;
 * post-migration the target org row is picked by `shimTargetOrg`.
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
    const legacyCreds = credsFromSettings(settingsRow ?? undefined);

    let creds = legacyCreds;
    let orgId: Id<"conductorOrgs"> | undefined;
    if (creds === undefined) {
      const orgs = await ctx.runQuery(internal.orgs.getOrgsForUserInternal, {
        userId: user._id,
      });
      const target = shimTargetOrg(orgs);
      if (target !== undefined) {
        creds = {
          apiKey: target.conductorApiKey,
          environment: target.conductorEnvironment,
        };
        orgId = target._id;
      }
    }

    if (creds === undefined) {
      return { ok: false, error: "No API key provided or stored." };
    }

    try {
      // Capture the prior project set before overwriting the cache, so we can
      // tell the client whether this key sees a different set of Conductor
      // projects than the last one — a cheap proxy (predates GET /me) for
      // "this key may belong to a different Conductor account."
      const previous = await ctx.runQuery(
        internal.projects.getProjectsCacheForUserInternal,
        { userId: user._id, orgId },
      );
      const projects = await listAllProjects(creds, { limit: 50 });
      const changedFromPrevious = projectSetChanged(
        previous?.projects,
        projects,
      );
      await ctx.runMutation(internal.projects.writeProjectsCacheInternal, {
        userId: user._id,
        orgId,
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

/**
 * Refreshes every org's project cache independently — one bad key must not
 * block the others. Also backfills best-effort GET /me metadata
 * (`organizationId`/`organizationName`) onto rows that lack it, so existing
 * keys pick up server org names the day the API ships them (the seam).
 *
 * Pre-migration users (legacy settings key, no org rows) refresh the legacy
 * no-org cache row. Returns the old `{ ok, error? }` shape old clients decode
 * plus a `failures` array new clients can surface.
 */
export const refreshProjects = action({
  args: {},
  handler: async (
    ctx,
  ): Promise<{
    ok: boolean;
    error?: string;
    failures?: { orgId: Id<"conductorOrgs">; label: string; error: string }[];
  }> => {
    const user = await ctx.runQuery(internal.users.getSelfInternal, {});
    if (user === null) {
      return { ok: false, error: "Not authenticated" };
    }

    const orgs = await ctx.runQuery(internal.orgs.getOrgsForUserInternal, {
      userId: user._id,
    });

    if (orgs.length === 0) {
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
        const message =
          err instanceof ConductorApiError
            ? err.userMessage
            : (err as Error).message;
        return { ok: false, error: message };
      }
    }

    const failures: { orgId: Id<"conductorOrgs">; label: string; error: string }[] =
      [];
    for (const org of orgs) {
      const creds = {
        apiKey: org.conductorApiKey,
        environment: org.conductorEnvironment,
      };
      try {
        const projects = await listAllProjects(creds, { limit: 50 });
        await ctx.runMutation(internal.projects.writeProjectsCacheInternal, {
          userId: user._id,
          orgId: org._id,
          projects,
        });
      } catch (err) {
        const message =
          err instanceof ConductorApiError
            ? err.userMessage
            : (err as Error).message;
        failures.push({
          orgId: org._id,
          label: orgDisplayName(org),
          error: message,
        });
        continue;
      }

      if (org.organizationId === undefined || org.organizationName === undefined) {
        const me = await getMe(creds);
        if (me !== undefined) {
          await ctx.runMutation(internal.orgs.patchOrgIdentityInternal, {
            orgId: org._id,
            organizationId: me.organizationId,
            organizationName: me.organizationName,
          });
        }
      }
    }

    if (failures.length === orgs.length) {
      return { ok: false, error: failures[0]?.error, failures };
    }
    return failures.length > 0 ? { ok: true, failures } : { ok: true };
  },
});

/**
 * Old-client shim over the multi-org store. Probes both Conductor hosts for
 * `apiKey` (`resolveConductorEnvironment`) and, on success, commits the key
 * into a `conductorOrgs` row via the same single internal mutation as
 * `orgs.addKey` (KTD3 — row + cache in one transaction, seeded from the
 * probe's own project list). Row resolution: a GET /me `organizationId`
 * match wins (refreshing that row's metadata); else `shimTargetOrg`;
 * else insert a new row labeled "Default" (fresh user on an old client). On
 * failure nothing is stored.
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

    const me = await getMe({
      apiKey: args.apiKey,
      environment: resolved.environment,
    });
    const orgs = await ctx.runQuery(internal.orgs.getOrgsForUserInternal, {
      userId: user._id,
    });
    const target =
      (me?.organizationId !== undefined
        ? orgs.find((o) => o.organizationId === me.organizationId)
        : undefined) ?? shimTargetOrg(orgs);

    const { projectsChanged } = await ctx.runMutation(
      internal.orgs.commitValidatedOrgKeyInternal,
      {
        userId: user._id,
        orgId: target?._id,
        label: target?.label ?? "Default",
        conductorApiKey: args.apiKey,
        conductorEnvironment: resolved.environment,
        organizationId: me?.organizationId,
        organizationName: me?.organizationName,
        projects: resolved.projects,
      },
    );

    return { ok: true, environment: resolved.environment, projectsChanged };
  },
});
