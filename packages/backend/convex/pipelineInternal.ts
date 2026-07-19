// Internal queries/mutations used only by pipeline.ts's actions. Actions
// cannot touch ctx.db directly, so every DB read/write the pipeline needs
// is exposed here as an internalQuery/internalMutation. None of these are
// part of the client-facing surface (TECH-SPEC §7) — captures.ts and
// projects.ts own the public mutations/queries that call into the pipeline.

import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { defaultTemplate } from "./defaultTemplate";

export const getCaptureInternal = internalQuery({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.captureId);
  },
});

export const getSettingsInternal = internalQuery({
  args: { userId: v.id("users") },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("settings")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .unique();
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
