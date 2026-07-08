import { mutation } from "./_generated/server";
import { requireIdentity } from "./lib/auth";

/**
 * Upsert the calling user's `users` row from their auth identity.
 * Called on first login (and safely on every login thereafter).
 *
 * Dedupes on `authSubject`: the first call inserts; every subsequent call
 * for the same identity is a no-op that returns the existing row's id.
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
      return existing._id;
    }

    return await ctx.db.insert("users", {
      authSubject: identity.subject,
      email: identity.email ?? undefined,
      createdAt: Date.now(),
    });
  },
});
