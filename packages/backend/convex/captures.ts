// Client-facing capture functions — TECH-SPEC §7.

import { v } from "convex/values";
import { internal } from "./_generated/api";
import { mutation, query } from "./_generated/server";
import { requireUser } from "./lib/auth";
import { WATCHDOG_DELAY } from "./pipeline";

/**
 * Creates a capture. Dedupes on (userId, clientId) — a safe no-op for
 * offline re-sync (the app may re-submit the same clientId after
 * reconnecting): returns the existing row's id without scheduling a second
 * pipeline run. Schedules pipeline.submit at +0 and pipeline.watchdog at
 * +90 min (TECH-SPEC §6) for a genuinely new capture.
 */
export const create = mutation({
  args: {
    clientId: v.string(),
    transcript: v.string(),
    notes: v.string(),
    screenshotId: v.optional(v.id("_storage")),
    projectId: v.string(),
    projectName: v.string(),
    // Which org key to use for this capture. Optional: old clients omit it
    // and the pipeline's credsForCapture fallback chain resolves them.
    orgId: v.optional(v.id("conductorOrgs")),
    agent: v.string(),
    model: v.optional(v.string()),
    capturedAt: v.number(),
  },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);

    if (args.orgId !== undefined) {
      // F14: fail fast at create time instead of an alarming cross-account
      // pipeline error minutes later — old clients never send orgId, so
      // this only affects new clients.
      const org = await ctx.db.get(args.orgId);
      if (org === null || org.userId !== user._id) {
        throw new Error("Unknown organization key — refresh and try again.");
      }
    }

    const existing = await ctx.db
      .query("captures")
      .withIndex("by_client", (q) =>
        q.eq("userId", user._id).eq("clientId", args.clientId),
      )
      .unique();

    if (existing !== null) {
      return existing._id;
    }

    const captureId = await ctx.db.insert("captures", {
      userId: user._id,
      clientId: args.clientId,
      transcript: args.transcript,
      notes: args.notes,
      screenshotId: args.screenshotId,
      projectId: args.projectId,
      projectName: args.projectName,
      orgId: args.orgId,
      agent: args.agent,
      model: args.model,
      capturedAt: args.capturedAt,
      status: "queued",
      attempt: 0,
    });

    await ctx.scheduler.runAfter(0, internal.pipeline.submit, { captureId });
    await ctx.scheduler.runAfter(WATCHDOG_DELAY, internal.pipeline.watchdog, {
      captureId,
    });

    return captureId;
  },
});

/**
 * Recent captures for the calling user, most recent first. Excludes
 * archived captures from the default view (TECH-SPEC §7) — drives History
 * recents + notification transitions.
 */
export const listRecent = query({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const limit = args.limit ?? 20;

    const rows = await ctx.db
      .query("captures")
      .withIndex("by_user_time", (q) => q.eq("userId", user._id))
      .order("desc")
      .collect();

    return rows.filter((r) => r.archivedAt === undefined).slice(0, limit);
  },
});

/** Full history, most recent first, excluding archived captures. */
export const list = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const rows = await ctx.db
      .query("captures")
      .withIndex("by_user_time", (q) => q.eq("userId", user._id))
      .order("desc")
      .collect();
    return rows.filter((r) => r.archivedAt === undefined);
  },
});

/** A single capture by id — returns archived captures too (not filtered). */
export const get = query({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const row = await ctx.db.get(args.captureId);
    if (row === null || row.userId !== user._id) return null;
    return row;
  },
});

/**
 * Retries a capture from `failed` or `readyUnverified`. Resets `attempt`
 * and `errorCode`, patches back to `queued`, and schedules a fresh submit +
 * watchdog. All of pipeline.ts's idempotency guards make this safe at any
 * prior progress point (existing workspaceId/sessionId are preserved, so a
 * retry never duplicates a workspace or a message).
 */
export const retry = mutation({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const capture = await ctx.db.get(args.captureId);
    if (capture === null || capture.userId !== user._id) {
      throw new Error("Capture not found");
    }
    if (capture.status !== "failed" && capture.status !== "readyUnverified") {
      throw new Error(
        `Cannot retry a capture in status "${capture.status}"`,
      );
    }

    await ctx.db.patch(args.captureId, {
      status: "queued",
      attempt: 0,
      errorCode: undefined,
      error: undefined,
    });

    await ctx.scheduler.runAfter(0, internal.pipeline.submit, {
      captureId: args.captureId,
    });
    await ctx.scheduler.runAfter(WATCHDOG_DELAY, internal.pipeline.watchdog, {
      captureId: args.captureId,
    });
  },
});

/** Deletes the capture's screenshot file and clears the field. */
export const deleteScreenshot = mutation({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const capture = await ctx.db.get(args.captureId);
    if (capture === null || capture.userId !== user._id) {
      throw new Error("Capture not found");
    }
    if (capture.screenshotId !== undefined) {
      await ctx.storage.delete(capture.screenshotId);
      await ctx.db.patch(args.captureId, { screenshotId: undefined });
    }
  },
});

/**
 * Patches `openedAt` if unset (idempotent — first open wins). Called when
 * the user opens a capture's deep link from History or a notification;
 * drives the ready-indicator badge and the PRD north-star metric.
 */
export const markOpened = mutation({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const capture = await ctx.db.get(args.captureId);
    if (capture === null || capture.userId !== user._id) {
      throw new Error("Capture not found");
    }
    if (capture.openedAt === undefined) {
      await ctx.db.patch(args.captureId, { openedAt: Date.now() });
    }
  },
});

/**
 * Patches `archivedAt`. Archived captures are excluded from
 * `listRecent`/`list`'s default view but remain queryable via `get`.
 */
export const archive = mutation({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const capture = await ctx.db.get(args.captureId);
    if (capture === null || capture.userId !== user._id) {
      throw new Error("Capture not found");
    }
    if (capture.archivedAt === undefined) {
      await ctx.db.patch(args.captureId, { archivedAt: Date.now() });
    }
  },
});
