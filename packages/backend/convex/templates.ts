import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireUser } from "./lib/auth";
import { defaultTemplate } from "./defaultTemplate";

/**
 * Returns the calling user's prompt template, seeding the default template
 * on first call (lazily — no template row exists until the user's first
 * `templates.get`).
 */
export const get = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const existing = await ctx.db
      .query("promptTemplates")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .unique();

    if (existing !== null) {
      return existing;
    }

    // Seeded virtually (not persisted) until the user actually saves —
    // `templates.get` is a query and cannot write. `templates.update`/
    // `templates.reset` persist the row.
    return {
      _id: undefined,
      userId: user._id,
      body: defaultTemplate,
      isCustomized: false,
      updatedAt: 0,
    };
  },
});

/** Updates (or creates) the calling user's prompt template with custom content. */
export const update = mutation({
  args: { body: v.string() },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const existing = await ctx.db
      .query("promptTemplates")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .unique();

    if (existing === null) {
      return await ctx.db.insert("promptTemplates", {
        userId: user._id,
        body: args.body,
        isCustomized: true,
        updatedAt: Date.now(),
      });
    }

    await ctx.db.patch(existing._id, {
      body: args.body,
      isCustomized: true,
      updatedAt: Date.now(),
    });
    return existing._id;
  },
});

/** Restores the calling user's prompt template to the default. */
export const reset = mutation({
  args: {},
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const existing = await ctx.db
      .query("promptTemplates")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .unique();

    if (existing === null) {
      return await ctx.db.insert("promptTemplates", {
        userId: user._id,
        body: defaultTemplate,
        isCustomized: false,
        updatedAt: Date.now(),
      });
    }

    await ctx.db.patch(existing._id, {
      body: defaultTemplate,
      isCustomized: false,
      updatedAt: Date.now(),
    });
    return existing._id;
  },
});
