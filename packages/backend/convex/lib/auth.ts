import type { Auth } from "convex/server";
import type { Id } from "../_generated/dataModel";
import type { QueryCtx, MutationCtx } from "../_generated/server";

/**
 * Every function in this backend derives "who is calling" from ctx.auth
 * rather than trusting any client-supplied user id — this is the row-
 * ownership seam TECH-SPEC §9 requires. In this one-shot, mock-first build
 * the identity comes from `MockAuthProvider`'s token, but the shape
 * (`subject`, optional `email`) matches what a real Auth0 JWT decodes to via
 * convex-swift-auth0, so nothing here changes when a real tenant is wired up
 * (see auth.config.ts).
 */

export class NotAuthenticatedError extends Error {
  constructor() {
    super("Not authenticated");
    this.name = "NotAuthenticatedError";
  }
}

export class NotFoundError extends Error {
  constructor(what: string) {
    super(`${what} not found`);
    this.name = "NotFoundError";
  }
}

export class ForbiddenError extends Error {
  constructor() {
    super("Forbidden: row does not belong to the caller");
    this.name = "ForbiddenError";
  }
}

/** Throws NotAuthenticatedError if no identity is present. */
export async function requireIdentity(auth: Auth) {
  const identity = await auth.getUserIdentity();
  if (identity === null) {
    throw new NotAuthenticatedError();
  }
  return identity;
}

/**
 * Resolves the calling user's `users` row, throwing if unauthenticated or if
 * the user hasn't been created yet (i.e. `users.ensure` hasn't run). Used by
 * every function that needs to enforce row ownership.
 */
export async function requireUser(ctx: QueryCtx | MutationCtx) {
  const identity = await requireIdentity(ctx.auth);
  const user = await ctx.db
    .query("users")
    .withIndex("by_subject", (q) => q.eq("authSubject", identity.subject))
    .unique();
  if (user === null) {
    throw new NotFoundError("User");
  }
  return user;
}

/** Asserts that a row's userId matches the calling user's id; throws otherwise. */
export function assertOwnsRow(userId: Id<"users">, callerId: Id<"users">) {
  if (userId !== callerId) {
    throw new ForbiddenError();
  }
}
