import { mutation } from "./_generated/server";
import { requireUser } from "./lib/auth";

/**
 * Generates a short-lived upload URL for the calling user to POST a
 * screenshot file to Convex file storage. The returned `storageId` (after
 * upload) is later passed to `captures.create` as `screenshotId`.
 *
 * Requires auth (any authenticated user may request an upload URL — the
 * resulting file isn't associated with anything until `captures.create`
 * references its storageId on a row owned by that same user).
 */
export const generateUploadUrl = mutation({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});
