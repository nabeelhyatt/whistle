import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  users: defineTable({
    authSubject: v.string(), // Auth0 sub
    email: v.optional(v.string()),
    createdAt: v.number(),
    // Canonical-accounts migration (2026-07-18 plan): set on a "merged
    // shell" row once its captures/promptTemplates/projectsCache have been
    // repointed to the surviving user by admin.mergeUserData. Never
    // deleted — the row (and its untouched settings/API key) stays in
    // place as an audit trail; users.ensure's split-detection safeguard
    // skips rows with this set so a merged shell can't re-trigger a warn.
    mergedInto: v.optional(v.id("users")),
  })
    .index("by_subject", ["authSubject"])
    .index("by_email", ["email"]),

  settings: defineTable({
    userId: v.id("users"),
    conductorApiKey: v.optional(v.string()), // sensitive; never returned unmasked (see §9)
    // "prod" | "staging"; absent means prod (legacy rows, zero migration —
    // see credsFromSettings in settings.ts).
    conductorEnvironment: v.optional(v.string()),
    defaultProjectId: v.optional(v.string()),
    agent: v.string(), // "claude" | "codex" | "cursor"; default "claude"
    model: v.optional(v.string()),
    screenshotsEnabled: v.boolean(),
  }).index("by_user", ["userId"]),

  promptTemplates: defineTable({
    userId: v.id("users"),
    body: v.string(), // template with {{variables}}
    isCustomized: v.boolean(),
    updatedAt: v.number(),
  }).index("by_user", ["userId"]),

  captures: defineTable({
    userId: v.id("users"),
    clientId: v.string(), // UUID minted on device — idempotency key for offline retry,
    // Conductor messageId, and workspace-name tag
    transcript: v.string(),
    notes: v.string(),
    screenshotId: v.optional(v.id("_storage")),
    projectId: v.string(), // Conductor project id
    projectName: v.string(),
    agent: v.string(),
    model: v.optional(v.string()),
    capturedAt: v.number(),
    // pipeline
    status: v.union(
      v.literal("queued"),
      v.literal("creating"),
      v.literal("sending"),
      v.literal("agentWorking"),
      v.literal("ready"),
      v.literal("readyUnverified"), // sent OK but agent completion never confirmed (watch deadline)
      v.literal("failed"),
    ),
    errorCode: v.optional(
      v.union(
        v.literal("auth"), // 401/403 — terminal, route user to Settings
        v.literal("workspaceSetup"), // Conductor reported workspace/session error — retryable
        v.literal("network"), // exhausted transient retries — retryable
        v.literal("stalled"), // watchdog fired — retryable
        v.literal("unknown"),
      ),
    ),
    error: v.optional(v.string()), // Conductor StructuredError.userMessage or local description
    attempt: v.number(),
    workspaceId: v.optional(v.string()),
    workspaceName: v.optional(v.string()), // generated server-side, see §6 naming
    sessionId: v.optional(v.string()),
    deepLink: v.optional(v.string()),
    messageSentAt: v.optional(v.number()),
    clarifyingQuestions: v.optional(v.array(v.string())),
    agentSummary: v.optional(v.string()),
    // ready-state lifecycle (drives the PRD north-star metric — see PRD Success metrics)
    openedAt: v.optional(v.number()), // patched when the user opens this capture's deep link from Whistle
    archivedAt: v.optional(v.number()), // patched when the user dismisses/archives the row from History
  })
    .index("by_user_time", ["userId", "capturedAt"])
    .index("by_client", ["userId", "clientId"]),

  projectsCache: defineTable({
    userId: v.id("users"),
    projects: v.array(
      v.object({ id: v.string(), name: v.string(), gitRemote: v.string() }),
    ),
    fetchedAt: v.number(),
  }).index("by_user", ["userId"]),
});
