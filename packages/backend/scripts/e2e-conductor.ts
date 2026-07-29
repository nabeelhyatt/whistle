#!/usr/bin/env npx tsx
/**
 * Phase-0 proof: Conductor e2e (U4).
 *
 * Empirically resolves the six "known unknowns" in docs/CONDUCTOR-API.md against
 * the REAL Conductor API, using the shared scratch project ("ttl",
 * CONDUCTOR_SCRATCH_PROJECT_ID). This is not a mocked test — it performs live
 * network calls, creates real (but disposable) workspaces, and archives every
 * workspace it creates before exiting.
 *
 * HARD RULES (see plan U4 / TECH-SPEC §2a):
 *  - Every workspace created here MUST be named `whistle-e2e-*`.
 *  - Every workspace created here MUST be archived via
 *    POST /v0/workspaces/{id}/archive before this script exits, even on error
 *    paths (try/finally).
 *  - At most 2-3 workspaces total across the whole run.
 *  - Never touch a workspace this script did not create.
 *
 * Run with: npx tsx packages/backend/scripts/e2e-conductor.ts
 *
 * Reads CONDUCTOR_API_KEY and CONDUCTOR_SCRATCH_PROJECT_ID from a `.env.local`
 * file at the repo root (simple KEY=VALUE lines; trailing `  # comment` after
 * whitespace is stripped; lines starting with `#` are ignored).
 */

import { existsSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";

import {
  CONDUCTOR_API_BASES,
  resolveConductorEnvironment,
} from "../convex/conductorClient";

// ─── .env.local parsing ──────────────────────────────────────────────────

function findRepoRoot(startDir: string): string {
  let dir = startDir;
  for (let i = 0; i < 10; i++) {
    if (existsSync(resolve(dir, ".git"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  // Fallback: assume script lives at packages/backend/scripts/*.ts
  return resolve(startDir, "..", "..", "..");
}

function parseEnvLocal(path: string): Record<string, string> {
  const env: Record<string, string> = {};
  if (!existsSync(path)) return env;
  const raw = readFileSync(path, "utf8");
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let val = trimmed.slice(eq + 1);
    // Strip a trailing comment: whitespace followed by #
    const hashIdx = val.search(/\s+#/);
    if (hashIdx !== -1) val = val.slice(0, hashIdx);
    env[key] = val.trim();
  }
  return env;
}

const REPO_ROOT = findRepoRoot(dirname(new URL(import.meta.url).pathname));
const ENV_LOCAL_PATH = resolve(REPO_ROOT, ".env.local");
const envLocal = parseEnvLocal(ENV_LOCAL_PATH);

const CONDUCTOR_API_KEY = envLocal.CONDUCTOR_API_KEY;
const CONDUCTOR_SCRATCH_PROJECT_ID = envLocal.CONDUCTOR_SCRATCH_PROJECT_ID;

/** Resolved by probing both Conductor deployments at startup (see main),
 * so this script works with a prod or a staging key alike. */
let API_BASE = CONDUCTOR_API_BASES.prod;

// ─── logging ─────────────────────────────────────────────────────────────

function log(msg: string) {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${msg}`);
}

function section(title: string) {
  console.log("\n" + "=".repeat(70));
  console.log(title);
  console.log("=".repeat(70));
}

// ─── minimal fetch helper ────────────────────────────────────────────────

interface ConductorResponse<T> {
  status: number;
  ok: boolean;
  headers: Record<string, string>;
  body: T | undefined;
  rawText: string;
}

async function conductorFetch<T = any>(
  method: string,
  path: string,
  body?: unknown
): Promise<ConductorResponse<T>> {
  const url = `${API_BASE}${path}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${CONDUCTOR_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const rawText = await res.text();
  let parsed: T | undefined;
  try {
    parsed = rawText ? JSON.parse(rawText) : undefined;
  } catch {
    parsed = undefined;
  }
  const headers: Record<string, string> = {};
  res.headers.forEach((v, k) => {
    headers[k] = v;
  });
  return { status: res.status, ok: res.ok, headers, body: parsed, rawText };
}

async function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// ─── results accumulator ─────────────────────────────────────────────────

const results: Record<string, unknown> = {};
const createdWorkspaceIds: string[] = [];

// ─── main ────────────────────────────────────────────────────────────────

async function main() {
  section("Whistle U4 — Conductor e2e proof");
  log(`Repo root: ${REPO_ROOT}`);
  log(`.env.local: ${ENV_LOCAL_PATH} (${existsSync(ENV_LOCAL_PATH) ? "found" : "MISSING"})`);

  if (!CONDUCTOR_API_KEY || !CONDUCTOR_SCRATCH_PROJECT_ID) {
    log(
      "CONDUCTOR_API_KEY or CONDUCTOR_SCRATCH_PROJECT_ID missing from .env.local."
    );
    log(
      "Per plan U4: recording all six unknowns as 'unresolved — pipeline safe under either answer per TECH-SPEC §6 guards' and exiting 0 (non-blocking)."
    );
    printUnresolvedSummary();
    return;
  }

  log("Resolving Conductor environment (probing prod, then staging)...");
  const resolved = await resolveConductorEnvironment(CONDUCTOR_API_KEY);
  if (!resolved.ok) {
    throw new Error(
      `Could not resolve Conductor environment (${resolved.reason}): ${resolved.message}`
    );
  }
  API_BASE = CONDUCTOR_API_BASES[resolved.environment];
  log(`  -> environment: ${resolved.environment} (${API_BASE})`);

  log(`Using scratch project: ${CONDUCTOR_SCRATCH_PROJECT_ID}`);
  log("Sanity check: GET /v0/projects");
  const projectsResp = await conductorFetch("GET", "/v0/projects?limit=50");
  log(`  -> status ${projectsResp.status}`);
  if (!projectsResp.ok) {
    throw new Error(
      `GET /v0/projects failed unexpectedly (status ${projectsResp.status}): ${projectsResp.rawText}`
    );
  }
  const projectMatch = (projectsResp.body as any)?.data?.find(
    (p: any) => p.id === CONDUCTOR_SCRATCH_PROJECT_ID
  );
  if (!projectMatch) {
    log(
      "WARNING: scratch project id not found in /v0/projects response — proceeding anyway, but this is unexpected."
    );
  } else {
    log(`  -> confirmed project "${projectMatch.name}" (${projectMatch.id})`);
  }

  // ── Workspace #1: unknowns #1, #6, #5 (pass 1), #4 ──────────────────────
  let workspace1: { workspaceId: string; sessionId: string; deepLink: string } | null =
    null;
  try {
    section("Workspace #1 — create + unknown #1 (send during initializing)");
    const name1 = `whistle-e2e-${Date.now()}`;
    log(`Creating workspace "${name1}" ...`);
    const createResp = await conductorFetch("POST", "/v0/workspaces", {
      projectId: CONDUCTOR_SCRATCH_PROJECT_ID,
      name: name1,
      agent: "claude",
    });
    log(`  -> status ${createResp.status}`);
    log(`  -> body: ${JSON.stringify(createResp.body)}`);
    results.createWorkspaceResponseShape = createResp.body;
    if (!createResp.ok || !createResp.body) {
      throw new Error(
        `POST /v0/workspaces failed (status ${createResp.status}): ${createResp.rawText}`
      );
    }
    workspace1 = createResp.body as any;
    createdWorkspaceIds.push(workspace1!.workspaceId);
    log(`  -> workspaceId=${workspace1!.workspaceId} sessionId=${workspace1!.sessionId}`);

    // Immediately check workspace status (expect initializing).
    const statusImmediately = await conductorFetch(
      "GET",
      `/v0/workspaces/${workspace1!.workspaceId}/status`
    );
    log(
      `Immediate status check -> ${statusImmediately.status} body=${JSON.stringify(
        statusImmediately.body
      )}`
    );

    // Unknown #1: send a message immediately, before polling for ready.
    const messageId1 = `e2e-msg1-${Date.now()}`;
    const promptText1 =
      "This is an automated Phase-0 e2e proof from the Whistle build (unit U4). " +
      "Please do exactly two things and then stop:\n" +
      "1. Run `curl -sI https://example.com` and report the HTTP status code you got " +
      "back, to prove you have outbound network access.\n" +
      "2. Reply briefly with a short numbered list containing at least one clarifying " +
      "question, for example:\n1. What is this test verifying?\n" +
      "Keep the whole reply under 10 lines.";

    log(`Sending message immediately (messageId=${messageId1}) while workspace is likely still initializing ...`);
    const sendResp1 = await conductorFetch(
      "POST",
      `/v0/sessions/${workspace1!.sessionId}/messages`,
      { message: promptText1, messageId: messageId1 }
    );
    log(`  -> status ${sendResp1.status} body=${JSON.stringify(sendResp1.body)}`);
    results.unknown1_sendDuringInitializing = {
      workspaceStatusAtSendTime: statusImmediately.body,
      sendResponseStatus: sendResp1.status,
      sendResponseBody: sendResp1.body,
      succeeded: sendResp1.ok,
    };

    // Unknown #6: send the SAME messageId again immediately.
    section("Unknown #6 — duplicate messageId send");
    log(`Re-sending SAME messageId (${messageId1}) to test dedupe ...`);
    const sendResp1Dup = await conductorFetch(
      "POST",
      `/v0/sessions/${workspace1!.sessionId}/messages`,
      { message: promptText1, messageId: messageId1 }
    );
    log(`  -> status ${sendResp1Dup.status} body=${JSON.stringify(sendResp1Dup.body)}`);
    results.unknown6_firstSendResponse = sendResp1.body;
    results.unknown6_duplicateSendResponse = sendResp1Dup.body;

    // If the first send failed because the workspace wasn't ready, poll for
    // ready and retry once, so the rest of the phases have something to
    // observe. (This also matches the pipeline design: not-ready 4xx -> poll
    // -> resend.)
    if (!sendResp1.ok) {
      log("First send did not succeed outright — polling workspace status until ready, then retrying send ...");
      const ready = await pollWorkspaceUntilReady(workspace1!.workspaceId, 15 * 60_000);
      results.unknown1_polledUntilReady = ready;
      if (ready) {
        const retrySend = await conductorFetch(
          "POST",
          `/v0/sessions/${workspace1!.sessionId}/messages`,
          { message: promptText1, messageId: messageId1 }
        );
        log(`  -> retry send status ${retrySend.status} body=${JSON.stringify(retrySend.body)}`);
        results.unknown1_retrySendAfterReady = retrySend.body;
      }
    }

    // Unknown #2/#3: capture any rate-limit-ish headers observed so far.
    results.unknown2_observedHeaders = {
      createWorkspace: pickRateLimitHeaders(createResp.headers),
      sendMessage1: pickRateLimitHeaders(sendResp1.headers),
      sendMessage1Dup: pickRateLimitHeaders(sendResp1Dup.headers),
    };

    // ── Unknown #4 + #5 pass 1: poll session status until idle, capture a
    // real agent-message fixture, and check for evidence of outbound fetch. ──
    section("Poll session status until idle (agent first pass) — unknown #4 + #5 pass 1");
    const watchResult = await pollSessionUntilIdleWithReply(
      workspace1!.sessionId,
      messageId1,
      15 * 60_000,
      workspace1!.workspaceId
    );
    results.unknown4_and_5_pollOutcome = watchResult.outcome;

    if (watchResult.agentMessage) {
      log("Captured a real agent-typed message. Saving fixture ...");
      const fixturePath = resolve(
        REPO_ROOT,
        "packages/backend/convex/__tests__/fixtures/agent-message.json"
      );
      mkdirSync(dirname(fixturePath), { recursive: true });
      writeFileSync(
        fixturePath,
        JSON.stringify(watchResult.agentMessage, null, 2) + "\n"
      );
      log(`  -> fixture written to ${fixturePath}`);
      results.fixturePath = fixturePath;
      results.fixtureMessage = watchResult.agentMessage;

      const contentStr = JSON.stringify(watchResult.agentMessage.content ?? "");
      const mentionsExampleDomain = /example\.com|Example Domain/i.test(contentStr);
      const httpStatusMatch = contentStr.match(/HTTP\/[12](?:\.[01])?\s+(\d{3})|status(?:\s*code)?[:\s]+(\d{3})/i);
      const reportedStatus = httpStatusMatch ? (httpStatusMatch[1] ?? httpStatusMatch[2]) : null;
      results.unknown5_pass1_outboundFetchEvidence = {
        mentionsExampleDomainOrItsTitle: mentionsExampleDomain,
        reportedHttpStatus: reportedStatus,
        curlSucceeded: reportedStatus === "200",
        note:
          reportedStatus === "200"
            ? "Agent reported HTTP 200 from curl -sI https://example.com — outbound network access confirmed (pass 1)."
            : reportedStatus
            ? `Agent reported HTTP status ${reportedStatus} — outbound network access confirmed but non-200 status.`
            : mentionsExampleDomain
            ? "Agent reply appears to reference example.com content — consistent with successful outbound fetch, but no explicit status code parsed."
            : "Agent reply does not clearly report a status code or reference example.com — inconclusive from text alone; see raw content captured in fixture/results.",
      };
    } else {
      log("No agent-typed message captured within the poll window — unknown #4/#5 pass 1 inconclusive.");
      results.unknown5_pass1_outboundFetchEvidence = {
        note: "inconclusive — no agent reply observed within poll window",
      };
    }
  } finally {
    if (workspace1) {
      await archiveWorkspace(workspace1.workspaceId, "workspace #1");
    }
  }

  // ── Final verification pass ─────────────────────────────────────────────
  section("Final verification — list scratch project workspaces");
  const finalList = await conductorFetch(
    "GET",
    `/v0/projects/${CONDUCTOR_SCRATCH_PROJECT_ID}/workspaces`
  );
  log(`GET /v0/projects/{id}/workspaces -> status ${finalList.status}`);
  const allWorkspaces: any[] = (finalList.body as any)?.data ?? [];

  // Check 1: no live whistle-e2e-* workspaces remain in the project listing.
  // (Archived/deleted workspaces appear to be excluded from this list, so any
  // whistle-e2e-* entry here that isn't archived/deleted is a leak.)
  const liveE2e = allWorkspaces.filter(
    (w) =>
      typeof w.name === "string" &&
      w.name.startsWith("whistle-e2e-") &&
      w.status !== "archived" &&
      w.status !== "deleted"
  );
  for (const w of liveE2e) {
    log(`  -> LEAK: ${w.id ?? w.workspaceId} name=${w.name} status=${w.status}`);
  }

  // Check 2: per-workspace terminal-status verification via the status
  // endpoint (the project list can't be trusted alone — a vacuous filter over
  // it once produced a false "all archived").
  const perWorkspace: Array<{ id: string; status: string | undefined }> = [];
  for (const id of createdWorkspaceIds) {
    const st = await conductorFetch("GET", `/v0/workspaces/${id}/status`);
    const status = (st.body as any)?.status;
    perWorkspace.push({ id, status });
    log(`  -> created workspace ${id}: status=${status}`);
  }
  const allArchived =
    liveE2e.length === 0 &&
    perWorkspace.every(
      (w) => w.status === "archived" || w.status === "deleted"
    );
  results.finalArchivalCheck = {
    createdWorkspaceIds,
    perWorkspaceStatus: perWorkspace,
    liveE2eWorkspacesInProjectList: liveE2e.map((w) => ({
      id: w.id ?? w.workspaceId,
      name: w.name,
      status: w.status,
    })),
    allArchived,
  };
  log(`All created workspaces archived/deleted AND zero live whistle-e2e-* in project: ${allArchived}`);

  section("RESULTS SUMMARY (raw)");
  console.log(JSON.stringify(results, null, 2));
}

// ─── helpers ─────────────────────────────────────────────────────────────

function pickRateLimitHeaders(headers: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(headers)) {
    if (/rate|limit|retry|quota/i.test(k)) out[k] = v;
  }
  return out;
}

async function pollWorkspaceUntilReady(
  workspaceId: string,
  capMs: number
): Promise<{ reachedReady: boolean; finalStatus?: string; pollLog: string[] }> {
  const start = Date.now();
  const pollLog: string[] = [];
  let intervalMs = 15_000;
  while (Date.now() - start < capMs) {
    const resp = await conductorFetch(
      "GET",
      `/v0/workspaces/${workspaceId}/status`
    );
    const status = (resp.body as any)?.status;
    pollLog.push(`${new Date().toISOString()}: ${status} (http ${resp.status})`);
    log(`  poll workspace status -> ${status}`);
    if (status === "ready") {
      return { reachedReady: true, finalStatus: status, pollLog };
    }
    if (status === "archived" || status === "deleted") {
      return { reachedReady: false, finalStatus: status, pollLog };
    }
    await sleep(intervalMs);
    intervalMs = Math.min(intervalMs + 5_000, 30_000);
  }
  return { reachedReady: false, finalStatus: "timeout", pollLog };
}

async function pollSessionUntilIdleWithReply(
  sessionId: string,
  ourMessageId: string,
  capMs: number,
  workspaceId?: string
): Promise<{
  outcome: Record<string, unknown>;
  agentMessage: any | null;
}> {
  const start = Date.now();
  const pollLog: string[] = [];
  let intervalMs = 20_000;
  while (Date.now() - start < capMs) {
    // Cross-check workspace health: a session can sit `idle` forever while the
    // workspace itself failed to initialize (observed live: git-auth failure →
    // workspace auto-transitions to `deleted` with errorMessage, message never
    // delivered). Bail early instead of burning the whole poll window.
    if (workspaceId) {
      const wsResp = await conductorFetch(
        "GET",
        `/v0/workspaces/${workspaceId}/status`
      );
      const wsStatus = (wsResp.body as any)?.status;
      const wsError = (wsResp.body as any)?.errorMessage;
      if (wsStatus === "deleted" || wsStatus === "archived" || wsError) {
        pollLog.push(
          `${new Date().toISOString()}: workspace status=${wsStatus} errorMessage=${wsError ?? "none"} — bailing`
        );
        log(`  workspace status=${wsStatus} error=${wsError ?? "none"} — workspace init failed, bailing out of session poll.`);
        return {
          outcome: {
            reachedIdleWithReply: false,
            workspaceInitFailed: true,
            workspaceStatus: wsStatus,
            workspaceErrorMessage: wsError,
            pollLog,
          },
          agentMessage: null,
        };
      }
    }

    const statusResp = await conductorFetch(
      "GET",
      `/v0/sessions/${sessionId}/status`
    );
    const status = (statusResp.body as any)?.status;
    pollLog.push(`${new Date().toISOString()}: session status=${status} (http ${statusResp.status})`);
    log(`  poll session status -> ${status}`);

    if (status === "idle") {
      const messagesResp = await conductorFetch(
        "GET",
        `/v0/sessions/${sessionId}/messages`
      );
      const messages: any[] = (messagesResp.body as any)?.data ?? [];
      log(`  session idle -> fetched ${messages.length} messages`);

      // Find our message's sessionIndex.
      const ourMsg = messages.find(
        (m) => m.id === ourMessageId || m.messageId === ourMessageId
      );
      const ourIndex = ourMsg?.sessionIndex;

      // Find an agent-typed message after ours (or any agent message if we
      // can't determine ordering by index).
      const agentMessages = messages.filter(
        (m) => m.type && m.type !== "user" && m.type !== "human"
      );
      const agentAfterOurs =
        ourIndex !== undefined
          ? agentMessages.find((m) => (m.sessionIndex ?? -1) > ourIndex)
          : agentMessages[agentMessages.length - 1];

      if (agentAfterOurs) {
        return {
          outcome: {
            reachedIdleWithReply: true,
            pollLog,
            allMessageTypes: messages.map((m) => m.type),
          },
          agentMessage: agentAfterOurs,
        };
      }
      log("  idle but no agent-typed message after ours yet — treating as still-working, will keep polling.");
    } else if (status === "error") {
      return {
        outcome: {
          reachedIdleWithReply: false,
          erroredOut: true,
          errorMessage: (statusResp.body as any)?.errorMessage,
          pollLog,
        },
        agentMessage: null,
      };
    }

    await sleep(intervalMs);
    intervalMs = Math.min(intervalMs + 10_000, 120_000);
  }
  return {
    outcome: { reachedIdleWithReply: false, timedOut: true, pollLog },
    agentMessage: null,
  };
}

async function archiveWorkspace(workspaceId: string, label: string): Promise<void> {
  log(`Archiving ${label} (${workspaceId}) ...`);
  try {
    // NOTE: the archive endpoint 400s (FST_ERR_CTP_EMPTY_JSON_BODY) if you set
    // Content-Type: application/json with an empty body — send `{}` explicitly.
    const resp = await conductorFetch(
      "POST",
      `/v0/workspaces/${workspaceId}/archive`,
      {}
    );
    log(`  -> archive status ${resp.status} body=${JSON.stringify(resp.body)}`);
    if (!resp.ok) {
      // A workspace whose initialization failed transitions to `deleted` on its
      // own; archiving it then 404s. Verify via the status endpoint before
      // declaring a leak.
      const check = await conductorFetch(
        "GET",
        `/v0/workspaces/${workspaceId}/status`
      );
      const status = (check.body as any)?.status;
      if (status === "archived" || status === "deleted") {
        log(`  -> workspace is already terminal (status=${status}) — no cleanup needed.`);
      } else {
        log(`  -> WARNING: archive failed and workspace status=${status}. MANUAL CLEANUP REQUIRED for ${workspaceId}.`);
      }
    }
  } catch (err) {
    log(`  -> ERROR archiving ${workspaceId}: ${(err as Error).message}. Manual cleanup may be required.`);
  }
}

function printUnresolvedSummary() {
  const unresolvedMsg =
    "unresolved — pipeline safe under either answer per TECH-SPEC §6 guards";
  for (let i = 1; i <= 6; i++) {
    console.log(`Unknown #${i}: ${unresolvedMsg}`);
  }
}

main()
  .then(() => {
    log("Done.");
    process.exit(0);
  })
  .catch(async (err) => {
    log(`FATAL: ${err?.stack ?? err}`);
    // Best-effort cleanup of anything we created, in case main()'s own
    // try/finally didn't cover this failure mode (e.g. error thrown before
    // entering the try block).
    for (const id of createdWorkspaceIds) {
      await archiveWorkspace(id, `cleanup for ${id}`);
    }
    process.exit(1);
  });
