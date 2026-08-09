// Internal queries/mutations used only by pipeline.ts's actions. Actions
// cannot touch ctx.db directly, so every DB read/write the pipeline needs
// is exposed here as an internalQuery/internalMutation. None of these are
// part of the client-facing surface (TECH-SPEC §7) — captures.ts and
// projects.ts own the public mutations/queries that call into the pipeline.

import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import { defaultTemplate } from "./defaultTemplate";
import { credsFromSettings } from "./settings";
import { orgDisplayName, orgsForUser } from "./orgs";

export const getCaptureInternal = internalQuery({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.captureId);
  },
});

/**
 * Resolves which Conductor credentials a capture's pipeline actions should
 * use — the multi-org replacement for reading the single legacy settings
 * key. Resolution order:
 *
 *  1. `capture.orgId` points at a live row the capture's user owns → that
 *     row. A row owned by a *different* user hard-fails `auth` (a stale
 *     pointer, e.g. after an admin merge, must never leak another tenant's
 *     key). A row that's simply been deleted falls through — a working
 *     same-org sibling key may still be stored.
 *  2. Zero org rows → the legacy `settings` key (pre-migration users only;
 *     F1 — once any org row exists, `migrateLegacyKeyToOrg` clears the
 *     legacy fields on the user's next launch even in the "org rows already
 *     exist" coexistence case, so this branch never shadows a live org row).
 *  3. Exactly one org row → that row.
 *  4. The org whose projectsCache contains the capture's project, restricted
 *     to a cache row whose orgId still resolves to a live org (F5 — a cache
 *     upsert racing a concurrent `orgs.remove` must never resurrect a
 *     zombie row that then shadows a live sibling here).
 *
 * Returns the raw creds (internal-only — never client-facing) plus the org's
 * display name for error copy.
 */
export const credsForCaptureInternal = internalQuery({
  args: {
    userId: v.id("users"),
    orgId: v.optional(v.id("conductorOrgs")),
    projectId: v.string(),
  },
  handler: async (
    ctx,
    args,
  ): Promise<
    | {
        ok: true;
        apiKey: string;
        environment: "prod" | "staging";
        orgLabel?: string;
      }
    | { ok: false; error: string }
  > => {
    const fromOrg = (row: Doc<"conductorOrgs">) => ({
      ok: true as const,
      apiKey: row.conductorApiKey,
      environment: row.conductorEnvironment,
      orgLabel: orgDisplayName(row),
    });

    if (args.orgId !== undefined) {
      const row = await ctx.db.get(args.orgId);
      if (row !== null && row.userId !== args.userId) {
        return {
          ok: false,
          error:
            "This capture's organization key belongs to a different account. Update your API keys in Settings.",
        };
      }
      if (row !== null) return fromOrg(row);
      // Row deleted: fall through — a sibling key for the same org may
      // still resolve below.
    }

    const orgs = await orgsForUser(ctx, args.userId);

    if (orgs.length === 0) {
      const settings = await ctx.db
        .query("settings")
        .withIndex("by_user", (q) => q.eq("userId", args.userId))
        .unique();
      const legacy = credsFromSettings(settings ?? undefined);
      if (legacy !== undefined) {
        return { ok: true, apiKey: legacy.apiKey, environment: legacy.environment };
      }
      return { ok: false, error: "No Conductor API key configured." };
    }

    if (orgs.length === 1) return fromOrg(orgs[0]);

    const liveOrgIds = new Set(orgs.map((o) => o._id));
    const caches = await ctx.db
      .query("projectsCache")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .collect();
    const owning = caches.find(
      (cache) =>
        cache.orgId !== undefined &&
        liveOrgIds.has(cache.orgId) &&
        cache.projects.some((p) => p.id === args.projectId),
    );
    const org = orgs.find((o) => o._id === owning?.orgId);
    if (org !== undefined) return fromOrg(org);

    return {
      ok: false,
      error:
        "The API key for this capture's organization was removed — re-add it in Settings.",
    };
  },
});

export const getTemplateInternal = internalQuery({
  args: { userId: v.id("users") },
  handler: async (ctx, args) => {
    const row = await ctx.db
      .query("promptTemplates")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .unique();
    if (row !== null) return row.body;
    // Mirrors templates.get's lazy-seeding behavior (no row yet -> default).
    // Must be a static import: Convex's production runtime does not support
    // dynamic module imports, unlike the vitest environment (see regression
    // test in __tests__/pipelineInternal.test.ts).
    return defaultTemplate;
  },
});

export const getScreenshotUrlInternal = internalQuery({
  args: { storageId: v.id("_storage") },
  handler: async (ctx, args) => {
    return await ctx.storage.getUrl(args.storageId);
  },
});

/**
 * Generic patch helper for captures — every pipeline state transition goes
 * through this one mutation so state changes are centrally auditable.
 */
export const patchCaptureInternal = internalMutation({
  args: {
    captureId: v.id("captures"),
    patch: v.any(),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.captureId as Id<"captures">, args.patch);
  },
});

/**
 * Stores a computed workspace name exactly once so retries and overlapping
 * submit actions use the same name after any remote side effect.
 */
export const setWorkspaceNameIfAbsentInternal = internalMutation({
  args: {
    captureId: v.id("captures"),
    workspaceName: v.string(),
  },
  handler: async (ctx, args) => {
    const capture = await ctx.db.get(args.captureId);
    if (capture === null) throw new Error("Capture deleted while naming workspace");
    if (capture.workspaceName !== undefined) return capture.workspaceName;
    await ctx.db.patch(args.captureId, { workspaceName: args.workspaceName });
    return args.workspaceName;
  },
});
