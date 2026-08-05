// Multi-org Conductor key management — one labeled API key per Conductor
// organization (keys are org-scoped and there is no org-enumeration
// endpoint, so the user enters each key explicitly).
//
// The app never holds a Conductor key (TECH-SPEC §9): keys live on
// `conductorOrgs` rows and only masked metadata leaves this module. Entering
// a key must go through the probe-before-store path in `addKey` — there is
// deliberately no public mutation that writes a key directly (KTD6).

import { v } from "convex/values";
import {
  action,
  internalMutation,
  internalQuery,
  mutation,
  query,
} from "./_generated/server";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import { requireUser } from "./lib/auth";
import {
  getMe,
  resolveConductorEnvironment,
  type ConductorEnvironment,
} from "./conductorClient";

/**
 * Copy shared with projects.setAndValidateKey's failure result (R7) —
 * distinguishes a rejected key from an unreachable host.
 */
export const INVALID_KEY_MESSAGE =
  "Conductor didn't accept that key. Check that you copied the whole key.";
export const NETWORK_UNREACHABLE_MESSAGE =
  "Couldn't reach Conductor. Check your connection and try again.";

/**
 * The one place an org's display name is computed. `label` is user-typed and
 * renameable; `organizationName` is server truth from GET /me — absent today,
 * populated the day the Conductor API starts returning org names (the seam in
 * schema.ts). Server name wins the moment it exists.
 */
export function orgDisplayName(row: {
  label: string;
  organizationName?: string;
}): string {
  return row.organizationName ?? row.label;
}

/** All of a user's org rows, oldest first — the canonical ordering everywhere
 * (orgs.list, the merged projects list, "first org wins" dedupe). */
export async function orgsForUser(
  ctx: QueryCtx | MutationCtx,
  userId: Id<"users">,
): Promise<Doc<"conductorOrgs">[]> {
  const rows = await ctx.db
    .query("conductorOrgs")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .collect();
  return rows.sort((a, b) => a.createdAt - b.createdAt);
}

/** The calling user's org keys, masked (raw key never returned — same
 * discipline as settings.get). */
export const list = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const rows = await orgsForUser(ctx, user._id);
    return rows.map((row) => ({
      orgId: row._id,
      label: row.label,
      organizationName: row.organizationName,
      displayName: orgDisplayName(row),
      lastFour: row.conductorApiKey.slice(-4),
      environment: row.conductorEnvironment,
      createdAt: row.createdAt,
    }));
  },
});

/** Full org rows (keys included) for actions — internal only. */
export const getOrgsForUserInternal = internalQuery({
  args: { userId: v.id("users") },
  handler: async (ctx, args) => {
    return await orgsForUser(ctx, args.userId);
  },
});

/**
 * Picks which org row an old single-key client's call is about, when GET /me
 * couldn't say: exactly one row ⇒ that row; else the "Default"-labeled row
 * (the migration's name for the legacy key); else the oldest. Never "the
 * Default row" blindly — the user may have renamed it, and replacing the
 * wrong row would silently repoint in-flight captures pinned to that row's
 * id. Shared by projects.setAndValidateKey/validateKey and settings.get's
 * synthesized masked-key fields.
 */
export function shimTargetOrg(
  orgs: Doc<"conductorOrgs">[],
): Doc<"conductorOrgs"> | undefined {
  if (orgs.length === 1) return orgs[0];
  return orgs.find((o) => o.label === "Default") ?? orgs[0];
}

/**
 * True when a previously-cached project set exists AND its project ids differ
 * from the newly-fetched set. Order-independent; false with no prior cache so
 * a first key never shows a spurious "changed" warning.
 */
export function projectSetChanged(
  previous: { id: string }[] | undefined,
  next: { id: string }[],
): boolean {
  if (previous === undefined) return false;
  const prevIds = [...new Set(previous.map((p) => p.id))].sort();
  const nextIds = [...new Set(next.map((p) => p.id))].sort();
  if (prevIds.length !== nextIds.length) return true;
  return prevIds.some((id, i) => id !== nextIds[i]);
}

/** Upserts one org's projectsCache row. All cache access pins `orgId` on
 * by_user_org — `.unique()` on by_user alone throws once a user has 2+ rows. */
export async function upsertOrgProjectsCache(
  ctx: MutationCtx,
  userId: Id<"users">,
  orgId: Id<"conductorOrgs"> | undefined,
  projects: { id: string; name: string; gitRemote: string }[],
): Promise<{ projectsChanged: boolean }> {
  const existing = await ctx.db
    .query("projectsCache")
    .withIndex("by_user_org", (q) => q.eq("userId", userId).eq("orgId", orgId))
    .unique();
  const projectsChanged = projectSetChanged(existing?.projects, projects);
  if (existing === null) {
    await ctx.db.insert("projectsCache", {
      userId,
      orgId,
      projects,
      fetchedAt: Date.now(),
    });
  } else {
    await ctx.db.patch(existing._id, { projects, fetchedAt: Date.now() });
  }
  return { projectsChanged };
}

/**
 * The single transactional write behind `addKey` and the old-client
 * `projects.setAndValidateKey` shim (KTD3): inserts or replaces the org row
 * AND upserts that org's projectsCache from the already-probed project list
 * in one Convex mutation, so both writes commit or fail together.
 * `projectsChanged` is computed against the prior cache *inside* this
 * mutation so a concurrent cache write can't race the read-then-decide.
 *
 * `organizationId`/`organizationName` are only written when provided — a
 * failed best-effort GET /me must never clear metadata a previous call
 * stored.
 */
export const commitValidatedOrgKeyInternal = internalMutation({
  args: {
    userId: v.id("users"),
    // Present ⇒ replace that row's key in place; absent ⇒ insert a new org.
    orgId: v.optional(v.id("conductorOrgs")),
    label: v.string(),
    conductorApiKey: v.string(),
    conductorEnvironment: v.union(v.literal("prod"), v.literal("staging")),
    organizationId: v.optional(v.string()),
    organizationName: v.optional(v.string()),
    projects: v.array(
      v.object({ id: v.string(), name: v.string(), gitRemote: v.string() }),
    ),
  },
  handler: async (
    ctx,
    args,
  ): Promise<{ orgId: Id<"conductorOrgs">; projectsChanged: boolean }> => {
    let orgId: Id<"conductorOrgs">;
    if (args.orgId !== undefined) {
      const row = await ctx.db.get(args.orgId);
      if (row === null || row.userId !== args.userId) {
        throw new Error("commitValidatedOrgKeyInternal: org row not found");
      }
      await ctx.db.patch(args.orgId, {
        conductorApiKey: args.conductorApiKey,
        conductorEnvironment: args.conductorEnvironment,
        ...(args.organizationId !== undefined && {
          organizationId: args.organizationId,
        }),
        ...(args.organizationName !== undefined && {
          organizationName: args.organizationName,
        }),
      });
      orgId = args.orgId;
    } else {
      orgId = await ctx.db.insert("conductorOrgs", {
        userId: args.userId,
        label: args.label,
        conductorApiKey: args.conductorApiKey,
        conductorEnvironment: args.conductorEnvironment,
        organizationId: args.organizationId,
        organizationName: args.organizationName,
        createdAt: Date.now(),
      });
    }

    const { projectsChanged } = await upsertOrgProjectsCache(
      ctx,
      args.userId,
      orgId,
      args.projects,
    );
    return { orgId, projectsChanged };
  },
});

/**
 * Adds a new labeled org key: probes both Conductor hosts for the
 * environment (`resolveConductorEnvironment`), best-effort GET /me for
 * organizationId/organizationName (dedupe + the org-name seam), then commits
 * row + cache in one internal mutation. On failure nothing is written.
 */
export const addKey = action({
  args: { label: v.string(), apiKey: v.string() },
  handler: async (
    ctx,
    args,
  ): Promise<
    | {
        ok: true;
        orgId: Id<"conductorOrgs">;
        environment: ConductorEnvironment;
        projectsChanged: boolean;
      }
    | { ok: false; error: string }
  > => {
    const user = await ctx.runQuery(internal.users.getSelfInternal, {});
    if (user === null) {
      return { ok: false, error: "Not authenticated" };
    }

    const apiKey = args.apiKey.trim();
    if (apiKey.length === 0) {
      return { ok: false, error: INVALID_KEY_MESSAGE };
    }
    const label = args.label.trim().length > 0 ? args.label.trim() : "Default";

    const resolved = await resolveConductorEnvironment(apiKey);
    if (!resolved.ok) {
      return {
        ok: false,
        error:
          resolved.reason === "network"
            ? NETWORK_UNREACHABLE_MESSAGE
            : INVALID_KEY_MESSAGE,
      };
    }

    // Best-effort identity: when /me is unavailable the fields stay absent
    // and dedupe silently disables (duplicate-org keys then coexist; the
    // merged projects list dedupes by project id so that stays harmless).
    const me = await getMe({ apiKey, environment: resolved.environment });

    if (me?.organizationId !== undefined) {
      const existing = await ctx.runQuery(
        internal.orgs.getOrgsForUserInternal,
        { userId: user._id },
      );
      const duplicate = existing.find(
        (row) => row.organizationId === me.organizationId,
      );
      if (duplicate !== undefined) {
        return {
          ok: false,
          error: `You already have a key for this organization ("${orgDisplayName(duplicate)}"). Remove or replace that one instead.`,
        };
      }
    }

    const { orgId, projectsChanged } = await ctx.runMutation(
      internal.orgs.commitValidatedOrgKeyInternal,
      {
        userId: user._id,
        label,
        conductorApiKey: apiKey,
        conductorEnvironment: resolved.environment,
        organizationId: me?.organizationId,
        organizationName: me?.organizationName,
        projects: resolved.projects,
      },
    );

    return { ok: true, orgId, environment: resolved.environment, projectsChanged };
  },
});

/**
 * Removes an org key. Captures still pointing at the row are repointed to a
 * same-`organizationId` sibling when one exists (possible when GET /me was
 * unavailable at add time and two keys for one org coexist) — otherwise they
 * keep the dangling id and `credsForCapture`'s deleted-row fall-through
 * resolves them. Removing the last key is allowed (the UI confirms first);
 * the zero-key state mirrors pre-onboarding.
 */
export const remove = mutation({
  args: { orgId: v.id("conductorOrgs") },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const row = await ctx.db.get(args.orgId);
    if (row === null || row.userId !== user._id) {
      throw new Error("Org key not found");
    }

    const siblings = await orgsForUser(ctx, user._id);
    const sibling =
      row.organizationId !== undefined
        ? siblings.find(
            (s) =>
              s._id !== row._id && s.organizationId === row.organizationId,
          )
        : undefined;

    if (sibling !== undefined) {
      // captures has no by-org index; per-user volumes are small and this
      // only runs on an explicit key removal.
      const captures = await ctx.db
        .query("captures")
        .withIndex("by_user_time", (q) => q.eq("userId", user._id))
        .collect();
      for (const capture of captures) {
        if (capture.orgId === row._id) {
          await ctx.db.patch(capture._id, { orgId: sibling._id });
        }
      }
    }

    const cache = await ctx.db
      .query("projectsCache")
      .withIndex("by_user_org", (q) =>
        q.eq("userId", user._id).eq("orgId", row._id),
      )
      .unique();
    if (cache !== null) {
      await ctx.db.delete(cache._id);
    }
    await ctx.db.delete(row._id);
  },
});

/** Backfills best-effort GET /me metadata onto an org row — used by
 * projects.refreshProjects so existing rows pick up `organizationName` the
 * day the API starts returning it (the seam), with no client change. Only
 * ever sets fields; never clears. */
export const patchOrgIdentityInternal = internalMutation({
  args: {
    orgId: v.id("conductorOrgs"),
    organizationId: v.optional(v.string()),
    organizationName: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const row = await ctx.db.get(args.orgId);
    if (row === null) return;
    const patch = {
      ...(args.organizationId !== undefined && {
        organizationId: args.organizationId,
      }),
      ...(args.organizationName !== undefined && {
        organizationName: args.organizationName,
      }),
    };
    if (Object.keys(patch).length > 0) {
      await ctx.db.patch(row._id, patch);
    }
  },
});

/** Renames an org key's user-typed label. Never touches `organizationName` —
 * server truth stays server truth. */
export const rename = mutation({
  args: { orgId: v.id("conductorOrgs"), label: v.string() },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const row = await ctx.db.get(args.orgId);
    if (row === null || row.userId !== user._id) {
      throw new Error("Org key not found");
    }
    const label = args.label.trim();
    if (label.length === 0) {
      throw new Error("Label can't be empty");
    }
    await ctx.db.patch(row._id, { label });
  },
});
