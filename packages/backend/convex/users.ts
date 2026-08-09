import { internalQuery, mutation, query } from "./_generated/server";
import { requireIdentity, requireUser } from "./lib/auth";
import { migrateLegacyKeyToOrg } from "./settings";

/**
 * Upsert the calling user's `users` row from their auth identity.
 * Called on first login (and safely on every login thereafter).
 *
 * Dedupes on `authSubject`: the first call inserts; every subsequent call
 * for the same identity is a no-op that returns the existing row's id.
 *
 * Canonical-accounts safeguard (2026-07-18 plan §3): the backend stays
 * keyed on `authSubject` only — this function never links accounts by
 * email (that's rejected option (c) in the plan: unverifiable from
 * Convex's side, and it'd re-implement Auth0 account linking's own attack
 * surface in our code). It only *detects and logs* a future split so an
 * operator can link the identities manually via the Auth0 Management API.
 */
export const ensure = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await requireIdentity(ctx.auth);

    const existing = await ctx.db
      .query("users")
      .withIndex("by_subject", (q) => q.eq("authSubject", identity.subject))
      .unique();

    if (existing !== null) {
      // Backfill: an earlier login for this same subject may have had no
      // email claim (or an identity provider that omits it); if the
      // current identity now carries one, patch it in. Feeds both this
      // safeguard's own by_email lookups for future subjects, and §4's
      // `me` query / Settings display.
      if (existing.email === undefined && identity.email !== undefined) {
        await ctx.db.patch(existing._id, { email: identity.email });
      }
      // Multi-org lazy migration: this MUST live inside the existing-user
      // branch — everyone with a legacy key is by definition an existing
      // user, and the early return below would otherwise skip them forever.
      await migrateLegacyKeyToOrg(ctx, existing._id);
      return existing._id;
    }

    if (identity.email !== undefined) {
      const emailMatches = await ctx.db
        .query("users")
        .withIndex("by_email", (q) => q.eq("email", identity.email))
        .collect();

      const split = emailMatches.find(
        (u) => u.authSubject !== identity.subject && u.mergedInto === undefined,
      );

      if (split !== undefined) {
        // Still insert (no auto-linking — see the function doc above);
        // just log a structured, greppable line so log streaming can
        // alert on the `account-split-detected` marker.
        console.warn(
          `account-split-detected email=${identity.email} newSubject=${identity.subject} ` +
            `existingSubject=${split.authSubject} emailVerified=${identity.emailVerified}`,
        );
      }
    }

    return await ctx.db.insert("users", {
      authSubject: identity.subject,
      email: identity.email ?? undefined,
      createdAt: Date.now(),
    });
  },
});

/**
 * Returns the calling user's email and auth subject — backend-truth
 * identity display for Settings (2026-07-18 plan §4), not token-decoding
 * on the client. `email` is whatever's stored on the `users` row (may be
 * undefined for identities that never carried one, e.g. a GitHub identity
 * with email privacy enabled).
 */
export const me = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    return { email: user.email, authSubject: user.authSubject };
  },
});

/**
 * Resolves the calling user's row (or null if unauthenticated / not yet
 * `users.ensure`d), for use by actions in projects.ts and pipeline.ts which
 * cannot call `requireUser` directly (it's a QueryCtx/MutationCtx helper).
 */
export const getSelfInternal = internalQuery({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) return null;
    return await ctx.db
      .query("users")
      .withIndex("by_subject", (q) => q.eq("authSubject", identity.subject))
      .unique();
  },
});
