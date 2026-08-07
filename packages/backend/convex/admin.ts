// Canonical-accounts migration tooling (2026-07-18 plan, §2). Internal-only
// — every export here is an internalQuery/internalMutation, never reachable
// from the client (no `api.admin.*` surface; only `npx convex run admin:...`
// or another internal function can call these). Used to snapshot and merge
// the two Convex users that resulted from the July 9 / July 17 Auth0 split
// (docs/plans/2026-07-18-002-canonical-accounts-plan.md).
//
// Absolute guardrails per the plan: no deletes anywhere, both Conductor
// keys preserved, dry-run before every mutating step, every step
// idempotent and individually reversible.

import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { maskedKeyFields } from "./settings";

/**
 * Before/after verification for the migration runbook. Returns one entry
 * per `users` row associated with `email`: matched via the `by_email`
 * index, PLUS a full-scan fallback for rows whose `email` field is
 * undefined — those can't be found by an indexed email lookup at all, but
 * they're exactly the rows a split can produce (e.g. a GitHub identity
 * whose token carried no email claim), so an account audit that silently
 * excluded them would miss half the picture. The users table is small
 * enough that a full scan here is cheap.
 */
export const accountReport = internalQuery({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const byEmail = await ctx.db
      .query("users")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .collect();

    const allUsers = await ctx.db.query("users").collect();
    const noEmail = allUsers.filter((u) => u.email === undefined);

    const seen = new Set<string>();
    const candidates = [...byEmail, ...noEmail].filter((u) => {
      if (seen.has(u._id)) return false;
      seen.add(u._id);
      return true;
    });

    return await Promise.all(
      candidates.map(async (user) => {
        const captures = await ctx.db
          .query("captures")
          .withIndex("by_user_time", (q) => q.eq("userId", user._id))
          .collect();
        const promptTemplates = await ctx.db
          .query("promptTemplates")
          .withIndex("by_user", (q) => q.eq("userId", user._id))
          .collect();
        const projectsCache = await ctx.db
          .query("projectsCache")
          .withIndex("by_user", (q) => q.eq("userId", user._id))
          .collect();
        const settingsRow = await ctx.db
          .query("settings")
          .withIndex("by_user", (q) => q.eq("userId", user._id))
          .unique();
        const orgRows = await ctx.db
          .query("conductorOrgs")
          .withIndex("by_user", (q) => q.eq("userId", user._id))
          .collect();

        return {
          userId: user._id,
          authSubject: user.authSubject,
          email: user.email,
          createdAt: user.createdAt,
          mergedInto: user.mergedInto,
          captureCount: captures.length,
          promptTemplateCount: promptTemplates.length,
          hasProjectsCache: projectsCache.length > 0,
          settings:
            settingsRow === null
              ? { present: false, hasKey: false, lastFour: undefined }
              : {
                  present: true,
                  ...maskedKeyFields(
                    settingsRow.conductorApiKey,
                    settingsRow.conductorEnvironment,
                  ),
                },
          conductorOrgs: orgRows.map((org) => ({
            orgId: org._id,
            label: org.label,
            organizationId: org.organizationId,
            lastFour: org.conductorApiKey.slice(-4),
            environment: org.conductorEnvironment,
          })),
        };
      }),
    );
  },
});

/**
 * Repoints `captures`, `promptTemplates`, `conductorOrgs`, and
 * `projectsCache` rows from `fromUserId` to `toUserId`. Deliberately does
 * NOT move `settings` — see plan §2 "What moves where": `settings.get` uses
 * `.unique()` per user, so two settings rows on one user would break every
 * read; the `from` user's settings row stays exactly where it is, untouched
 * and unreachable by any future login once Auth0 linking freezes that
 * subject. (In the multi-org era the legacy settings key is migrated onto a
 * `conductorOrgs` row at the shell user's next launch anyway — and org rows
 * DO move, because moved captures pin their org row by id.)
 *
 * Org collision policy: a `from` org row whose `organizationId` already
 * exists under `to` is skipped (never two rows for one org), and every
 * *moved* capture pointing at the skipped row is rewritten to the surviving
 * target row — same organization, semantically the same key. A plain skip
 * would strand those captures on a foreign-user row and fail them `auth` at
 * the pipeline's ownership check. Rewrites are recorded in the manifest as
 * `captureOrgRewrites: { captureId, fromOrgId, toOrgId }[]` so the rollback
 * ledger stays complete. A *collided* capture (stays under `from`, since its
 * clientId already exists under `to`) whose orgId points at an org row that
 * IS moving is a different stranding: it isn't repointed to `to`, but the
 * org row it references is about to become foreign to `from`. That capture's
 * `orgId` is cleared instead (`captureOrgClears: Id<"captures">[]`), falling
 * through credsForCaptureInternal's chain rather than hard-failing forever.
 *
 * projectsCache rows follow their org row (keyed by orgId, so no collision
 * is possible); the legacy no-org cache row keeps the old rule — left in
 * place if `to` already has a no-org row (it's a cache; staleness is
 * harmless).
 *
 * `dryRun` (default `true`) returns the manifest of row ids that would
 * move without writing anything. A live run (`dryRun: false`) patches
 * `userId` on each manifest row, marks `from.mergedInto = to`, and returns
 * the same manifest — save this output, it's the rollback ledger.
 *
 * Idempotent: once `from`'s rows have been repointed, a second live run
 * finds zero rows left under `from` and no-ops (empty manifest;
 * `mergedInto` patched to the same value again).
 */
export const mergeUserData = internalMutation({
  args: {
    fromUserId: v.id("users"),
    toUserId: v.id("users"),
    dryRun: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const dryRun = args.dryRun ?? true;

    if (args.fromUserId === args.toUserId) {
      throw new Error("mergeUserData: fromUserId and toUserId must differ");
    }

    const [fromUser, toUser] = await Promise.all([
      ctx.db.get(args.fromUserId),
      ctx.db.get(args.toUserId),
    ]);
    if (fromUser === null) {
      throw new Error(`mergeUserData: fromUserId ${args.fromUserId} not found`);
    }
    if (toUser === null) {
      throw new Error(`mergeUserData: toUserId ${args.toUserId} not found`);
    }
    if (
      fromUser.mergedInto !== undefined &&
      fromUser.mergedInto !== args.toUserId
    ) {
      throw new Error(
        `mergeUserData: fromUserId ${args.fromUserId} is already merged into ` +
          `${fromUser.mergedInto}, not ${args.toUserId}`,
      );
    }

    const fromCaptures = await ctx.db
      .query("captures")
      .withIndex("by_user_time", (q) => q.eq("userId", args.fromUserId))
      .collect();
    const fromPromptTemplates = await ctx.db
      .query("promptTemplates")
      .withIndex("by_user", (q) => q.eq("userId", args.fromUserId))
      .collect();
    const fromProjectsCache = await ctx.db
      .query("projectsCache")
      .withIndex("by_user", (q) => q.eq("userId", args.fromUserId))
      .collect();

    // Collision check: a `from` capture whose clientId already exists
    // under `to` is skipped and reported, never overwritten (device-
    // minted UUIDs make this ~impossible, but the check is cheap).
    const captureIds: Id<"captures">[] = [];
    const collidedCaptureIds: Id<"captures">[] = [];
    for (const capture of fromCaptures) {
      const collision = await ctx.db
        .query("captures")
        .withIndex("by_client", (q) =>
          q.eq("userId", args.toUserId).eq("clientId", capture.clientId),
        )
        .unique();
      if (collision !== null) {
        collidedCaptureIds.push(capture._id);
      } else {
        captureIds.push(capture._id);
      }
    }

    // Org rows move with the user; a duplicate `organizationId` under `to`
    // is skipped, with moved captures rewritten to the surviving row.
    const fromOrgs = await ctx.db
      .query("conductorOrgs")
      .withIndex("by_user", (q) => q.eq("userId", args.fromUserId))
      .collect();
    const toOrgs = await ctx.db
      .query("conductorOrgs")
      .withIndex("by_user", (q) => q.eq("userId", args.toUserId))
      .collect();

    const conductorOrgIds: Id<"conductorOrgs">[] = [];
    const skippedConductorOrgIds: Id<"conductorOrgs">[] = [];
    const survivingOrgByFromOrg = new Map<
      Id<"conductorOrgs">,
      Id<"conductorOrgs">
    >();
    for (const org of fromOrgs) {
      const duplicate =
        org.organizationId !== undefined
          ? toOrgs.find((t) => t.organizationId === org.organizationId)
          : undefined;
      if (duplicate !== undefined) {
        skippedConductorOrgIds.push(org._id);
        survivingOrgByFromOrg.set(org._id, duplicate._id);
      } else {
        conductorOrgIds.push(org._id);
      }
    }

    const movingOrgIds = new Set(conductorOrgIds);
    const captureOrgRewrites: {
      captureId: Id<"captures">;
      fromOrgId: Id<"conductorOrgs">;
      toOrgId: Id<"conductorOrgs">;
    }[] = [];
    // A collided capture stays under `from`. If it points at an org that
    // would move, a safe merge needs to clone that org and its cache for the
    // target; clearing the pointer would instead let credential fallback
    // select an unrelated org. Refuse this rare merge before any writes.
    for (const capture of fromCaptures) {
      if (capture.orgId === undefined) continue;
      if (!captureIds.includes(capture._id)) {
        // collided; stays put
        if (movingOrgIds.has(capture.orgId)) {
          throw new Error(
            "mergeUserData: a collided capture references an organization that would move; resolve the capture collision before merging",
          );
        }
        continue;
      }
      const surviving = survivingOrgByFromOrg.get(capture.orgId);
      if (surviving !== undefined) {
        captureOrgRewrites.push({
          captureId: capture._id,
          fromOrgId: capture.orgId,
          toOrgId: surviving,
        });
      }
    }

    // Per-org cache rows follow their org row; the legacy no-org row keeps
    // the old all-or-nothing rule against `to`'s legacy row.
    const toCaches = await ctx.db
      .query("projectsCache")
      .withIndex("by_user", (q) => q.eq("userId", args.toUserId))
      .collect();
    const toHasLegacyCache = toCaches.some((row) => row.orgId === undefined);

    const projectsCacheIds: Id<"projectsCache">[] = [];
    const skippedProjectsCacheIds: Id<"projectsCache">[] = [];
    for (const cache of fromProjectsCache) {
      const moves =
        cache.orgId !== undefined
          ? movingOrgIds.has(cache.orgId)
          : !toHasLegacyCache;
      (moves ? projectsCacheIds : skippedProjectsCacheIds).push(cache._id);
    }

    const promptTemplateIds = fromPromptTemplates.map((row) => row._id);

    const manifest = {
      captures: captureIds,
      promptTemplates: promptTemplateIds,
      projectsCache: projectsCacheIds,
      conductorOrgs: conductorOrgIds,
      collisions: { captures: collidedCaptureIds },
      skippedProjectsCache: skippedProjectsCacheIds,
      skippedConductorOrgs: skippedConductorOrgIds,
      captureOrgRewrites,
    };

    if (dryRun) {
      return manifest;
    }

    for (const captureId of captureIds) {
      await ctx.db.patch(captureId, { userId: args.toUserId });
    }
    for (const rewrite of captureOrgRewrites) {
      await ctx.db.patch(rewrite.captureId, { orgId: rewrite.toOrgId });
    }
    for (const templateId of promptTemplateIds) {
      await ctx.db.patch(templateId, { userId: args.toUserId });
    }
    for (const orgId of conductorOrgIds) {
      await ctx.db.patch(orgId, { userId: args.toUserId });
    }
    for (const cacheId of projectsCacheIds) {
      await ctx.db.patch(cacheId, { userId: args.toUserId });
    }
    await ctx.db.patch(args.fromUserId, { mergedInto: args.toUserId });

    return manifest;
  },
});
