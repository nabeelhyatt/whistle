// Server-side Conductor submission pipeline — TECH-SPEC §6, implemented
// verbatim. Design rules (apply to every action below):
//
//   - Idempotent by construction: every step checks recorded state before
//     acting; re-running any action is always safe.
//   - Never die silently: every scheduled action wraps its body in
//     try/catch; a caught error either transitions the capture or
//     reschedules the same action — it never simply stops.
//   - Watchdog backstop: captures.create schedules pipeline.watchdog at
//     +90 min; if still in-flight when it fires, patches failed/stalled.
//   - Error classification lives in conductorClient.ts's conductorFetch.
//
// Empirical findings from U4's live run (docs/CONDUCTOR-API.md "Known
// unknowns") are load-bearing here — see the finding-tagged comments below.

import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction, type ActionCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import {
  ConductorApiError,
  createWorkspace,
  getSessionStatus,
  getWorkspaceStatus,
  listAllProjects,
  listMessages,
  listProjectWorkspaces,
  listWorkspaceSessions,
  sendMessage,
  type ConductorCreds,
  type ConductorMessage,
} from "./conductorClient";
import { credsFromSettings } from "./settings";
import { renderTemplate } from "./promptRenderer";

// ─── Tunables (TECH-SPEC §6) ────────────────────────────────────────────

const MAX_SUBMIT_ATTEMPTS = 5;
const SUBMIT_BACKOFF_MS = [60_000, 4 * 60_000, 10 * 60_000, 20 * 60_000]; // 1,4,10,20 min

const AWAIT_READY_INITIAL_MS = 20_000;
const AWAIT_READY_MAX_MS = 60_000;
const AWAIT_READY_DEADLINE_MS = 15 * 60_000;

const WATCH_INITIAL_MS = 30_000;
const WATCH_MAX_MS = 2 * 60_000;
const WATCH_DEADLINE_MS = 60 * 60_000;

const WATCHDOG_DELAY_MS = 90 * 60_000;

const IN_FLIGHT_STATUSES = [
  "queued",
  "creating",
  "sending",
  "agentWorking",
] as const;

// ─── Workspace naming (TECH-SPEC §6) ────────────────────────────────────

/**
 * `workspaceName = "idea: " + firstMeaningfulWords(notes || transcript, 6) +
 * " #" + clientId.slice(0, 6)`; falls back to a screenshot-only form when
 * neither notes nor transcript has any words. Naming happens server-side
 * (here, not the app) so iOS inherits it unchanged (TECH-SPEC §6/§12).
 */
export function buildWorkspaceName(args: {
  notes: string;
  transcript: string;
  clientId: string;
  capturedAt: number;
}): string {
  const source = args.notes.trim().length > 0 ? args.notes : args.transcript;
  const words = source
    .trim()
    .split(/\s+/)
    .filter((w) => w.length > 0)
    .slice(0, 6);
  const tag = args.clientId.slice(0, 6);

  if (words.length === 0) {
    const date = new Date(args.capturedAt).toISOString().slice(0, 10);
    return `idea: screenshot capture ${date} #${tag}`;
  }

  return `idea: ${words.join(" ")} #${tag}`;
}

/** Returns the `#<clientId prefix>` tag used for orphan-workspace adoption. */
function orphanTag(clientId: string): string {
  return `#${clientId.slice(0, 6)}`;
}

async function projectVisibleToKey(creds: ConductorCreds, projectId: string): Promise<boolean> {
  const visibleProjects = await listAllProjects(creds, { limit: 50 });
  return visibleProjects.some((p) => p.id === projectId);
}

// ─── Clarifying-questions / summary extraction (dumb, safe heuristics) ──

/**
 * Extracts a best-effort plaintext string from a Conductor message's
 * untyped `content` field (docs/CONDUCTOR-API.md: "content is untyped ({}
 * in spec) — parse defensively"). Handles the shapes we can reasonably
 * expect from an agent's outbound message: a plain string, or an object
 * with a `text`/`content`/`message` string field, or an array of such
 * objects/strings (a common "content blocks" shape). The live Conductor
 * event envelope nests assistant output under
 * `content.rawPayload.message.content[].text`, so `rawPayload` is traversed
 * explicitly as well.
 */
export function extractMessageText(content: unknown): string {
  if (typeof content === "string") return content;

  if (Array.isArray(content)) {
    return content.map(extractMessageText).filter(Boolean).join("\n");
  }

  if (content !== null && typeof content === "object") {
    const obj = content as Record<string, unknown>;
    for (const key of ["text", "content", "message", "body", "rawPayload"]) {
      const val = obj[key];
      if (typeof val === "string") return val;
      if (val !== undefined) {
        const nested = extractMessageText(val);
        if (nested) return nested;
      }
    }
  }

  return "";
}

function normalizedIdentifier(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0
    ? value.toLowerCase()
    : undefined;
}

function messageContent(message: ConductorMessage): Record<string, unknown> | undefined {
  return message.content !== null && typeof message.content === "object" && !Array.isArray(message.content)
    ? (message.content as Record<string, unknown>)
    : undefined;
}

/** All fields the live and legacy message-list shapes use for correlation. */
function messageIdentifiers(message: ConductorMessage): string[] {
  const content = messageContent(message);
  return [
    message.id,
    message.messageId,
    content?.id,
    content?.messageId,
    content?.turnId,
    content?.userMessageId,
  ]
    .map(normalizedIdentifier)
    .filter((value): value is string => value !== undefined);
}

function messageMatchesClient(message: ConductorMessage, clientId: string): boolean {
  return messageIdentifiers(message).includes(clientId.toLowerCase());
}

/** A message is "ours" iff it isn't agent-typed and it's correlated to our clientId. */
function isOurMessage(message: ConductorMessage, clientId: string): boolean {
  return !isAgentMessage(message) && messageMatchesClient(message, clientId);
}

function isAgentMessage(message: ConductorMessage): boolean {
  const type = message.type?.toLowerCase();
  return type !== undefined && type !== "user" && type !== "human" && type !== "usermessage";
}

/**
 * Non-reply `rawPayload.type` shapes we know about (Settings only ever
 * offers Claude/codex/cursor, but every agent shares Conductor's envelope
 * for lifecycle/system events). Denylist rather than allowlist: allowlisting
 * only "assistant" (the shape observed in Claude's live fixture) would
 * silently drift every codex/cursor capture to readyUnverified the moment
 * their rawPayload.type differs even slightly. Correlation (messageMatchesClient)
 * and non-empty extracted text remain the real gates below, so accepting an
 * unrecognized type here is safe.
 */
const NON_REPLY_RAW_TYPES = new Set(["system", "result", "user"]);

function isAssistantReply(message: ConductorMessage): boolean {
  if (!isAgentMessage(message)) return false;
  const rawPayload = messageContent(message)?.rawPayload;
  if (rawPayload === null || typeof rawPayload !== "object" || Array.isArray(rawPayload)) {
    return true;
  }
  const rawType = (rawPayload as Record<string, unknown>).type;
  if (typeof rawType !== "string") return true;
  const normalized = rawType.toLowerCase();
  if (NON_REPLY_RAW_TYPES.has(normalized)) return false;
  if (normalized !== "assistant") {
    // A new/unrecognized agent shape — accept it (correlation + text
    // extraction are the real gates) but warn so it's visible in the Convex
    // dashboard logs instead of silently stranding the capture.
    console.warn(
      `isAssistantReply: accepting unrecognized rawPayload.type "${rawType}"`,
    );
  }
  return true;
}

/**
 * Finds the last agent-typed message whose `sessionIndex` is after our own
 * message's index. Live Conductor events lowercase the UUID and place it in
 * nested content fields (`id`, `turnId`, and `userMessageId`) rather than
 * top-level `id`/`messageId`, so comparisons are case-insensitive and accept
 * both shapes. Event-only agent records are ignored: only an event from
 * which assistant text can actually be extracted counts as a reply.
 */
export function findAgentReplyAfterOurs(
  messages: ConductorMessage[],
  clientId: string,
): ConductorMessage | undefined {
  const ourMessage = messages.find((message) => isOurMessage(message, clientId));
  const ourIndex = ourMessage?.sessionIndex;
  let latestReply: ConductorMessage | undefined;

  for (const message of messages) {
    if (!isAssistantReply(message) || !messageMatchesClient(message, clientId)) continue;
    // ourIndex undefined (our own message hasn't been listed yet — e.g.
    // eventual-consistency delay, or it scrolled out of the page) does NOT
    // gate here by design: a correlated reply's linked id is authoritative
    // on its own. Unlinked text is never accepted regardless.
    if (ourIndex !== undefined && (message.sessionIndex ?? -1) <= ourIndex) continue;
    if (extractMessageText(message.content).trim().length === 0) continue;
    if ((message.sessionIndex ?? 0) < (latestReply?.sessionIndex ?? 0)) continue;
    latestReply = message;
  }

  return latestReply;
}

/** Checks whether our own messageId already appears in the session's messages. */
function ourMessageAlreadySent(
  messages: ConductorMessage[],
  clientId: string,
): boolean {
  return messages.some((message) => isOurMessage(message, clientId));
}

/**
 * Extraction heuristics (TECH-SPEC §6 watch step): summary = first non-empty
 * line; clarifying questions = numbered lines (`^\d+[\.\)]`) or
 * `?`-terminated bullets in the final section. Dumb and safe — degrades to
 * an empty questions array rather than throwing (F4.1 copy degrades
 * gracefully per the plan's test matrix).
 */
export function extractSummaryAndQuestions(agentText: string): {
  summary: string | undefined;
  questions: string[];
} {
  const lines = agentText.split("\n").map((l) => l.trim());
  const summary = lines.find((l) => l.length > 0);

  const questions: string[] = [];
  const numberedRe = /^\d+[.)]\s*(.+)$/;
  const bulletQuestionRe = /^[-*]?\s*(.+\?)$/;

  for (const line of lines) {
    if (line.length === 0) continue;
    const numbered = line.match(numberedRe);
    if (numbered) {
      questions.push(numbered[1].trim());
      continue;
    }
    if (line.endsWith("?")) {
      const bullet = line.match(bulletQuestionRe);
      if (bullet) {
        questions.push(bullet[1].trim());
      }
    }
  }

  return { summary, questions };
}

// ─── captures.status transition helper (shared by every internal action) ─

/**
 * Structured `console.error` for pipeline failure chokepoints (U3 — makes
 * Conductor/pipeline failures visible in the Convex dashboard's live
 * function logs; DB fields like status/errorCode alone are invisible
 * there). Never log the API key or a rendered prompt — only the
 * classification/message already captured on `err`/`extra`.
 */
function logPipelineError(
  stage: string,
  captureId: Id<"captures">,
  err: unknown,
  extra?: Record<string, unknown>,
): void {
  const errorCode =
    err instanceof ConductorApiError ? err.errorClass : undefined;
  const message =
    err instanceof Error ? err.message : String(err);
  const extraStr =
    extra !== undefined
      ? " " +
        Object.entries(extra)
          .map(([k, v]) => `${k}=${String(v)}`)
          .join(" ")
      : "";
  console.error(
    `Pipeline error [${stage}] captureId=${captureId}` +
      (errorCode !== undefined ? ` errorCode=${errorCode}` : "") +
      ` message=${message}${extraStr}`,
  );
}

async function patchCapture(
  ctx: ActionCtx,
  captureId: Id<"captures">,
  patch: Record<string, unknown>,
): Promise<void> {
  await ctx.runMutation(internal.pipelineInternal.patchCaptureInternal, {
    captureId,
    patch,
  });
}

// ─── pipeline.submit ─────────────────────────────────────────────────────

export const submit = internalAction({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    try {
      await runSubmit(ctx, args.captureId);
    } catch (err) {
      // Never die silently: any error not already handled inside runSubmit
      // (e.g. a bug, or an error thrown before we could classify it) still
      // results in a state transition or a reschedule — never a silent stop.
      await handleTransientOrTerminal(ctx, args.captureId, err, "submit");
    }
  },
});

async function runSubmit(
  ctx: ActionCtx,
  captureId: Id<"captures">,
): Promise<void> {
  const capture = await ctx.runQuery(
    internal.pipelineInternal.getCaptureInternal,
    { captureId },
  );
  if (capture === null) return; // deleted mid-flight; nothing to do.

  // Idempotency: if we've already moved past sending (or terminal), do
  // nothing — a stray re-schedule must not redo work.
  if (
    capture.status !== "queued" &&
    capture.status !== "creating" &&
    capture.status !== "sending"
  ) {
    return;
  }

  const settings = await ctx.runQuery(
    internal.pipelineInternal.getSettingsInternal,
    { userId: capture.userId },
  );
  const creds = credsFromSettings(settings ?? undefined);
  if (creds === undefined) {
    await patchCapture(ctx, captureId, {
      status: "failed",
      errorCode: "auth",
      error: "No Conductor API key configured.",
    });
    return;
  }

  const template = await ctx.runQuery(
    internal.pipelineInternal.getTemplateInternal,
    { userId: capture.userId },
  );

  const screenshotUrl =
    capture.screenshotId !== undefined
      ? await ctx.runQuery(internal.pipelineInternal.getScreenshotUrlInternal, {
          storageId: capture.screenshotId,
        })
      : null;

  const workspaceName =
    capture.workspaceName ??
    buildWorkspaceName({
      notes: capture.notes,
      transcript: capture.transcript,
      clientId: capture.clientId,
      capturedAt: capture.capturedAt,
    });

  const renderedPrompt = renderTemplate(template, {
    transcript: capture.transcript,
    notes: capture.notes,
    screenshot_url: screenshotUrl ?? "",
    captured_at_iso: new Date(capture.capturedAt).toISOString(),
    project_name: capture.projectName,
    workspace_name: workspaceName,
  });

  // ── Step 3: ensure workspace (only if capture.workspaceId == null) ────
  let workspaceId = capture.workspaceId;
  let sessionId = capture.sessionId;
  let deepLink = capture.deepLink;

  if (workspaceId === undefined || sessionId === undefined) {
    // 3·0. Project-visibility guard (canonical-accounts). The stored key must
    // be able to see this capture's project. A key that belongs to a
    // *different* Conductor account than the one the user picked the project
    // under lists a different project set (or none) — orphan-adoption's
    // listProjectWorkspaces and createWorkspace would then fail with an opaque
    // 4xx that burns all five retries and strands the capture in "Agent
    // working" pointing at a workspace the user can't open. Fail fast with a
    // Settings-routing message instead. Runs only on a fresh submit (no
    // workspaceId yet); adopted/created captures skip it on later passes.
    if (!(await projectVisibleToKey(creds, capture.projectId))) {
      await patchCapture(ctx, captureId, {
        status: "failed",
        errorCode: "auth",
        error:
          "This capture's Conductor project isn't visible to your saved API key — the key may belong to a different Conductor account. Update it in Settings.",
      });
      return;
    }

    // 3a. Orphan adoption: search for a workspace already tagged with our
    // clientId (a previous run created it but died before patching ids).
    const tag = orphanTag(capture.clientId);
    const existingWorkspaces = await listProjectWorkspaces(
      creds,
      capture.projectId,
    );
    const orphan = existingWorkspaces.data.find(
      (w) => typeof w.name === "string" && w.name.includes(tag),
    );

    if (orphan !== undefined) {
      const orphanId = orphan.id ?? orphan.workspaceId;
      if (orphanId === undefined) {
        throw new Error("Orphan workspace entry missing id");
      }
      const sessions = await listWorkspaceSessions(creds, orphanId);
      const firstSession = sessions.data[0];
      const adoptedSessionId = firstSession?.id ?? firstSession?.sessionId;
      if (adoptedSessionId === undefined) {
        throw new Error("Orphan workspace has no recoverable session");
      }
      workspaceId = orphanId;
      sessionId = adoptedSessionId;
      deepLink = capture.deepLink; // unknown for an adopted orphan; leave as-is.
    } else {
      // 3b. No orphan found — create fresh.
      const created = await createWorkspace(creds, {
        projectId: capture.projectId,
        name: workspaceName,
        agent: capture.agent,
        model: capture.model,
      });
      workspaceId = created.workspaceId;
      sessionId = created.sessionId;
      deepLink = created.deepLink;
    }

    // 3c. Patch ids + status immediately, before anything else can fail —
    // this is what makes step 3 idempotent across a died-mid-action retry.
    await patchCapture(ctx, captureId, {
      workspaceId,
      sessionId,
      deepLink,
      workspaceName,
      status: "creating",
    });
  }

  // ── Step 4: send the prompt ────────────────────────────────────────────
  await patchCapture(ctx, captureId, { status: "sending" });

  // 4a. Dedupe guard before any (re)send: check whether our messageId is
  // already present. We cannot assume Conductor dedupes on messageId
  // (confirmed false by U4 unknown #6) — this check, plus the 23505
  // duplicate-send classification below, are what make resends safe.
  //
  // Finding 3 (U4 unknown #4): a successfully queued send may NOT yet
  // appear in this list — the workspace hasn't processed it. Seeing an
  // empty list here is NOT proof no send happened; it only tells us
  // whether we need to attempt a send. If a send already truly happened,
  // the attempt below will hard-fail with the 23505 duplicate error
  // (finding 1), which we treat as success, not failure.
  const existingMessages = await listMessages(creds, sessionId!);
  const alreadySent = ourMessageAlreadySent(
    existingMessages.data,
    capture.clientId,
  );

  if (!alreadySent) {
    try {
      await sendMessage(creds, sessionId!, {
        message: renderedPrompt,
        messageId: capture.clientId,
      });
    } catch (err) {
      if (err instanceof ConductorApiError) {
        if (err.errorClass === "duplicateMessage") {
          // Finding 1: a send-shaped 500 with Postgres 23505 means our
          // earlier send already succeeded (Conductor does not dedupe
          // messageId — it hard-fails instead). Re-check the message list
          // to confirm, then proceed WITHOUT resending. Never blind-retry
          // this class of error.
          const recheck = await listMessages(creds, sessionId!);
          const nowPresent = ourMessageAlreadySent(
            recheck.data,
            capture.clientId,
          );
          if (!nowPresent) {
            // Extremely defensive: the DB says our messageId exists (that's
            // what 23505 means) but the list endpoint doesn't show it yet
            // (finding 3's "queued but not listed" window). Proceed anyway
            // — the constraint violation is authoritative proof of a prior
            // send; do not resend and do not fail this attempt.
          }
          // Fall through to agentWorking below — the send is considered
          // successful.
        } else if (err.errorClass === "workspaceSetup") {
          // Not-ready-shaped 4xx: hand off to awaitWorkspaceReady rather
          // than looping in-action (TECH-SPEC §6 step 4c).
          await ctx.scheduler.runAfter(
            0,
            internal.pipeline.awaitWorkspaceReady,
            { captureId, pollCount: 0 },
          );
          return;
        } else {
          throw err;
        }
      } else {
        throw err;
      }
    }
  }

  // ── Step 5 ──────────────────────────────────────────────────────────────
  await patchCapture(ctx, captureId, {
    status: "agentWorking",
    messageSentAt: Date.now(),
  });
  await ctx.scheduler.runAfter(WATCH_INITIAL_MS, internal.pipeline.watch, {
    captureId,
    backoffMs: WATCH_INITIAL_MS,
  });
}

/**
 * Shared transient/terminal handling for pipeline.submit's outer catch.
 * Mirrors TECH-SPEC §6: "Transient failure anywhere in 3-4: if attempt < 5,
 * patch attempt+1 and reschedule submit with backoff; else failed/network."
 * Auth errors are always terminal with no retry, regardless of attempt count.
 */
async function handleTransientOrTerminal(
  ctx: ActionCtx,
  captureId: Id<"captures">,
  err: unknown,
  origin: "submit",
): Promise<void> {
  const capture = await ctx.runQuery(
    internal.pipelineInternal.getCaptureInternal,
    { captureId },
  );
  if (capture === null) return;

  if (err instanceof ConductorApiError && err.errorClass === "auth") {
    logPipelineError(origin, captureId, err, { decision: "terminal" });
    await patchCapture(ctx, captureId, {
      status: "failed",
      errorCode: "auth",
      error: err.userMessage,
    });
    return;
  }

  const attempt = capture.attempt ?? 0;
  if (attempt < MAX_SUBMIT_ATTEMPTS) {
    const backoff =
      SUBMIT_BACKOFF_MS[Math.min(attempt, SUBMIT_BACKOFF_MS.length - 1)];
    logPipelineError(origin, captureId, err, {
      decision: "rescheduling",
      nextAttempt: attempt + 1,
      backoffMs: backoff,
    });
    await patchCapture(ctx, captureId, { attempt: attempt + 1 });
    await ctx.scheduler.runAfter(backoff, internal.pipeline.submit, {
      captureId,
    });
    return;
  }

  const errorCode =
    err instanceof ConductorApiError && err.errorClass === "workspaceSetup"
      ? "workspaceSetup"
      : "network";
  const errorMessage =
    err instanceof ConductorApiError
      ? err.userMessage
      : err instanceof Error
        ? err.message
        : String(err);

  logPipelineError(origin, captureId, err, { decision: "terminal" });
  await patchCapture(ctx, captureId, {
    status: "failed",
    errorCode,
    error: errorMessage,
  });
}

// ─── pipeline.awaitWorkspaceReady ────────────────────────────────────────

export const awaitWorkspaceReady = internalAction({
  args: { captureId: v.id("captures"), pollCount: v.number() },
  handler: async (ctx, args) => {
    try {
      const capture = await ctx.runQuery(
        internal.pipelineInternal.getCaptureInternal,
        { captureId: args.captureId },
      );
      if (capture === null) return;
      if (
        capture.status !== "queued" &&
        capture.status !== "creating" &&
        capture.status !== "sending"
      ) {
        return; // already progressed past this point — idempotent no-op.
      }
      if (capture.workspaceId === undefined) {
        // Nothing to poll yet — hand back to submit.
        await ctx.scheduler.runAfter(0, internal.pipeline.submit, {
          captureId: args.captureId,
        });
        return;
      }

      const settings = await ctx.runQuery(
        internal.pipelineInternal.getSettingsInternal,
        { userId: capture.userId },
      );
      const creds = credsFromSettings(settings ?? undefined);
      if (creds === undefined) {
        await patchCapture(ctx, args.captureId, {
          status: "failed",
          errorCode: "auth",
          error: "No Conductor API key configured.",
        });
        return;
      }

      const elapsedMs = args.pollCount * AWAIT_READY_INITIAL_MS;
      const status = await getWorkspaceStatus(creds, capture.workspaceId);

      if (elapsedMs >= AWAIT_READY_DEADLINE_MS) {
        await patchCapture(ctx, args.captureId, {
          status: "failed",
          errorCode: "workspaceSetup",
          error:
            status.errorMessage ??
            "Workspace did not become ready within the poll deadline.",
        });
        return;
      }

      if (status.status === "ready") {
        // Jump back into submit — its guards (workspaceId already set,
        // message-list dedupe check) skip straight to the send step.
        await ctx.scheduler.runAfter(0, internal.pipeline.submit, {
          captureId: args.captureId,
        });
        return;
      }

      if (status.status === "deleted" || status.status === "archived") {
        // Finding 2: a workspace can auto-transition to deleted when init
        // fails. Any queued message was silently dropped. Fail loudly
        // rather than polling forever or drifting to readyUnverified.
        await patchCapture(ctx, args.captureId, {
          status: "failed",
          errorCode: "workspaceSetup",
          error:
            status.errorMessage ??
            `Workspace ${status.status} during initialization.`,
        });
        return;
      }

      // initializing / updating — reschedule with backoff.
      const nextDelay = Math.min(
        AWAIT_READY_INITIAL_MS + args.pollCount * 10_000,
        AWAIT_READY_MAX_MS,
      );
      await ctx.scheduler.runAfter(
        nextDelay,
        internal.pipeline.awaitWorkspaceReady,
        { captureId: args.captureId, pollCount: args.pollCount + 1 },
      );
    } catch (err) {
      // Never die silently — always reschedule until the deadline logic
      // above naturally terminates it.
      logPipelineError("awaitWorkspaceReady", args.captureId, err, {
        decision: "rescheduling",
        pollCount: args.pollCount + 1,
      });
      await ctx.scheduler.runAfter(
        AWAIT_READY_INITIAL_MS,
        internal.pipeline.awaitWorkspaceReady,
        { captureId: args.captureId, pollCount: args.pollCount + 1 },
      );
    }
  },
});

// ─── pipeline.watch ──────────────────────────────────────────────────────

export const watch = internalAction({
  args: { captureId: v.id("captures"), backoffMs: v.number() },
  handler: async (ctx, args) => {
    try {
      await runWatch(ctx, args.captureId, args.backoffMs);
    } catch (err) {
      // Entire body is in try/catch: a thrown error reschedules the watch —
      // it never strands the capture. Deadline is enforced by runWatch's own
      // messageSentAt check on the next tick, not by this catch block.
      const delay = Math.min(args.backoffMs, WATCH_MAX_MS);
      logPipelineError("watch", args.captureId, err, {
        decision: "rescheduling",
        backoffMs: delay,
      });
      await ctx.scheduler.runAfter(
        delay,
        internal.pipeline.watch,
        { captureId: args.captureId, backoffMs: Math.min(args.backoffMs * 2, WATCH_MAX_MS) },
      );
    }
  },
});

async function runWatch(
  ctx: ActionCtx,
  captureId: Id<"captures">,
  backoffMs: number,
): Promise<void> {
  const capture = await ctx.runQuery(
    internal.pipelineInternal.getCaptureInternal,
    { captureId },
  );
  if (capture === null) return;
  if (capture.status !== "agentWorking") {
    return; // already terminal or moved on — idempotent no-op.
  }

  const messageSentAt = capture.messageSentAt ?? Date.now();
  if (Date.now() - messageSentAt >= WATCH_DEADLINE_MS) {
    // Deadline reached without confirmation. Deliberately NOT `ready` — only
    // a verified agent reply earns that (F4.1's success notification only
    // fires for verified ready).
    await patchCapture(ctx, captureId, { status: "readyUnverified" });
    return;
  }

  const settings = await ctx.runQuery(
    internal.pipelineInternal.getSettingsInternal,
    { userId: capture.userId },
  );
  const creds = credsFromSettings(settings ?? undefined);
  if (creds === undefined) {
    await patchCapture(ctx, captureId, {
      status: "failed",
      errorCode: "auth",
      error: "No Conductor API key configured.",
    });
    return;
  }

  const sessionStatus = await getSessionStatus(creds, capture.sessionId!);

  if (sessionStatus.status === "working") {
    const nextBackoff = Math.min(backoffMs * 2, WATCH_MAX_MS);
    await ctx.scheduler.runAfter(nextBackoff, internal.pipeline.watch, {
      captureId,
      backoffMs: nextBackoff,
    });
    return;
  }

  if (sessionStatus.status === "error") {
    await patchCapture(ctx, captureId, {
      status: "failed",
      errorCode: "workspaceSetup",
      error: sessionStatus.errorMessage ?? "Conductor session reported an error.",
    });
    return;
  }

  // status === "idle" — verify the agent actually ran before declaring
  // ready (finding 2 + docs/CONDUCTOR-API.md unknown #1's caveat: a session
  // reads idle the ENTIRE time its workspace is initializing, and keeps
  // reading idle after the workspace init fails and auto-deletes — idle
  // alone proves nothing).
  //
  // Cross-check workspace status first: a `deleted` (or errorMessage-
  // carrying) workspace means our queued message was silently dropped —
  // this must fail/workspaceSetup, never drift to readyUnverified at the
  // deadline (finding 2).
  const workspaceStatus = capture.workspaceId
    ? await getWorkspaceStatus(creds, capture.workspaceId)
    : null;

  if (
    workspaceStatus !== null &&
    (workspaceStatus.status === "deleted" || workspaceStatus.errorMessage)
  ) {
    await patchCapture(ctx, captureId, {
      status: "failed",
      errorCode: "workspaceSetup",
      error:
        workspaceStatus.errorMessage ??
        "Workspace was deleted during agent processing.",
    });
    return;
  }

  if (workspaceStatus !== null && workspaceStatus.status === "initializing") {
    // Queued message hasn't started yet — still working, keep polling.
    const nextBackoff = Math.min(backoffMs * 2, WATCH_MAX_MS);
    await ctx.scheduler.runAfter(nextBackoff, internal.pipeline.watch, {
      captureId,
      backoffMs: nextBackoff,
    });
    return;
  }

  const messagesResp = await listMessages(creds, capture.sessionId!);
  const agentReply = findAgentReplyAfterOurs(
    messagesResp.data,
    capture.clientId,
  );

  if (agentReply === undefined) {
    // idle with no agent message after ours — reschedule, do NOT mark ready.
    const nextBackoff = Math.min(backoffMs * 2, WATCH_MAX_MS);
    await ctx.scheduler.runAfter(nextBackoff, internal.pipeline.watch, {
      captureId,
      backoffMs: nextBackoff,
    });
    return;
  }

  const agentText = extractMessageText(agentReply.content);
  const { summary, questions } = extractSummaryAndQuestions(agentText);

  await patchCapture(ctx, captureId, {
    status: "ready",
    agentSummary: summary,
    clarifyingQuestions: questions,
  });
}

// ─── pipeline.watchdog ───────────────────────────────────────────────────

export const watchdog = internalAction({
  args: { captureId: v.id("captures") },
  handler: async (ctx, args) => {
    try {
      const capture = await ctx.runQuery(
        internal.pipelineInternal.getCaptureInternal,
        { captureId: args.captureId },
      );
      if (capture === null) return;

      if (
        (IN_FLIGHT_STATUSES as readonly string[]).includes(capture.status)
      ) {
        await patchCapture(ctx, args.captureId, {
          status: "failed",
          errorCode: "stalled",
          error: "Capture was stuck in flight past the watchdog deadline.",
        });
      }
    } catch (err) {
      // Never die silently — retry the watchdog check shortly rather than
      // leaving a possibly-stalled capture completely unchecked.
      logPipelineError("watchdog", args.captureId, err, {
        decision: "rescheduling",
      });
      await ctx.scheduler.runAfter(60_000, internal.pipeline.watchdog, {
        captureId: args.captureId,
      });
    }
  },
});

export const WATCHDOG_DELAY = WATCHDOG_DELAY_MS;
