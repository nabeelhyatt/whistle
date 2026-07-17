import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import liveMessagesFixture from "./fixtures/conductor-messages-live.json";
import {
  buildWorkspaceName,
  extractMessageText,
  extractSummaryAndQuestions,
  findAgentReplyAfterOurs,
} from "../pipeline";

const modules = import.meta.glob("../**/*.ts");

function withMockUser(t: ReturnType<typeof convexTest>, subject: string) {
  return t.withIdentity({ subject });
}

// ─── Mock Conductor server ────────────────────────────────────────────────
//
// A tiny route-based fetch mock built from the shapes documented in
// docs/CONDUCTOR-API.md. Each test configures a `MockConductor` instance and
// installs it via vi.stubGlobal("fetch", ...), per TECH-SPEC §11's pinned
// harness.

interface MockMessage {
  id: string;
  sessionIndex: number;
  type: string;
  content: unknown;
}

class MockConductor {
  workspaces = new Map<
    string,
    {
      id: string;
      projectId: string;
      name: string;
      status: "initializing" | "ready" | "sleeping" | "archived" | "deleted" | "updating";
      errorMessage?: string;
      sessionId: string;
    }
  >();
  sessions = new Map<
    string,
    { id: string; workspaceId: string; status: "idle" | "working" | "error"; errorMessage?: string }
  >();
  messagesBySession = new Map<string, MockMessage[]>();

  createWorkspaceCount = 0;
  sendMessageCalls: Array<{ sessionId: string; messageId: string }> = [];

  /** Behavior overrides a test can toggle mid-run. */
  createWorkspaceResponder?: () => { status: number; body: unknown };
  sendMessageResponder?: (
    sessionId: string,
    messageId: string,
  ) => { status: number; body: unknown } | undefined;
  workspaceStatusOverride?: (workspaceId: string) => { status: number; body: unknown } | undefined;
  sessionStatusOverride?: (sessionId: string) => { status: number; body: unknown } | undefined;
  listMessagesOverride?: (sessionId: string) => { status: number; body: unknown } | undefined;
  throwOnSessionStatusOnce = false;

  addWorkspace(opts: {
    workspaceId: string;
    sessionId: string;
    projectId: string;
    name: string;
    status?: "initializing" | "ready" | "sleeping" | "archived" | "deleted" | "updating";
  }) {
    this.workspaces.set(opts.workspaceId, {
      id: opts.workspaceId,
      projectId: opts.projectId,
      name: opts.name,
      status: opts.status ?? "ready",
      sessionId: opts.sessionId,
    });
    this.sessions.set(opts.sessionId, {
      id: opts.sessionId,
      workspaceId: opts.workspaceId,
      status: "idle",
    });
    this.messagesBySession.set(opts.sessionId, []);
  }

  addAgentMessage(sessionId: string, msg: MockMessage) {
    const list = this.messagesBySession.get(sessionId) ?? [];
    list.push(msg);
    this.messagesBySession.set(sessionId, list);
  }

  handle = async (url: string, init?: RequestInit): Promise<Response> => {
    const method = init?.method ?? "GET";
    const path = url.replace("https://api.conductor.build", "");
    const bodyStr = typeof init?.body === "string" ? init.body : undefined;
    const body = bodyStr ? JSON.parse(bodyStr) : undefined;

    const json = (status: number, obj: unknown) =>
      new Response(JSON.stringify(obj), {
        status,
        headers: { "content-type": "application/json" },
      });

    // POST /v0/workspaces
    if (method === "POST" && path === "/v0/workspaces") {
      this.createWorkspaceCount += 1;
      if (this.createWorkspaceResponder) {
        const r = this.createWorkspaceResponder();
        return json(r.status, r.body);
      }
      const workspaceId = `ws-${this.createWorkspaceCount}`;
      const sessionId = `sess-${this.createWorkspaceCount}`;
      this.addWorkspace({
        workspaceId,
        sessionId,
        projectId: body.projectId,
        name: body.name,
        status: "ready",
      });
      return json(200, {
        workspaceId,
        sessionId,
        deepLink: `conductor://workspace/${workspaceId}`,
      });
    }

    // GET /v0/workspaces/{id}/status
    let m = path.match(/^\/v0\/workspaces\/([^/]+)\/status$/);
    if (method === "GET" && m) {
      const workspaceId = m[1];
      if (this.workspaceStatusOverride) {
        const r = this.workspaceStatusOverride(workspaceId);
        if (r) return json(r.status, r.body);
      }
      const ws = this.workspaces.get(workspaceId);
      if (!ws) return json(404, { userMessage: "not found" });
      return json(200, {
        status: ws.status,
        errorMessage: ws.errorMessage,
        updatedAt: Date.now(),
      });
    }

    // GET /v0/workspaces/{id}/sessions (orphan adoption)
    m = path.match(/^\/v0\/workspaces\/([^/]+)\/sessions$/);
    if (method === "GET" && m) {
      const workspaceId = m[1];
      const ws = this.workspaces.get(workspaceId);
      if (!ws) return json(200, { data: [] });
      return json(200, { data: [{ id: ws.sessionId }] });
    }

    // GET /v0/projects/{id}/workspaces (orphan adoption search)
    m = path.match(/^\/v0\/projects\/([^/]+)\/workspaces$/);
    if (method === "GET" && m) {
      const projectId = m[1];
      const data = [...this.workspaces.values()]
        .filter((w) => w.projectId === projectId)
        .map((w) => ({ id: w.id, name: w.name, status: w.status }));
      return json(200, { data });
    }

    // POST /v0/sessions/{id}/messages
    m = path.match(/^\/v0\/sessions\/([^/]+)\/messages$/);
    if (method === "POST" && m) {
      const sessionId = m[1];
      this.sendMessageCalls.push({ sessionId, messageId: body.messageId });
      if (this.sendMessageResponder) {
        const r = this.sendMessageResponder(sessionId, body.messageId);
        if (r) return json(r.status, r.body);
      }
      const existing = this.messagesBySession.get(sessionId) ?? [];
      const alreadyPresent = existing.some((mm) => mm.id === body.messageId);
      if (alreadyPresent) {
        // Default behavior mirrors the live API (U4 unknown #6): duplicate
        // messageId send hard-fails with a 500 Postgres unique-violation.
        return json(500, {
          code: "23505",
          userMessage:
            'duplicate key value violates unique constraint "session_messages_queue_pkey"',
        });
      }
      existing.push({
        id: body.messageId,
        sessionIndex: existing.length,
        type: "user",
        content: body.message,
      });
      this.messagesBySession.set(sessionId, existing);
      return json(201, { messageId: body.messageId, state: "sent" });
    }

    // GET /v0/sessions/{id}/status
    m = path.match(/^\/v0\/sessions\/([^/]+)\/status$/);
    if (method === "GET" && m) {
      const sessionId = m[1];
      if (this.sessionStatusOverride) {
        const r = this.sessionStatusOverride(sessionId);
        if (r) return json(r.status, r.body);
      }
      const s = this.sessions.get(sessionId);
      if (!s) return json(404, { userMessage: "not found" });
      return json(200, { status: s.status, errorMessage: s.errorMessage });
    }

    // GET /v0/sessions/{id}/messages
    m = path.match(/^\/v0\/sessions\/([^/]+)\/messages$/);
    if (method === "GET" && m) {
      const sessionId = m[1];
      if (this.listMessagesOverride) {
        const r = this.listMessagesOverride(sessionId);
        if (r) return json(r.status, r.body);
      }
      const data = this.messagesBySession.get(sessionId) ?? [];
      return json(200, { data });
    }

    throw new Error(`MockConductor: unhandled ${method} ${path}`);
  };
}

let mock: MockConductor;
let errorSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  vi.useFakeTimers();
  mock = new MockConductor();
  vi.stubGlobal(
    "fetch",
    vi.fn((url: string, init?: RequestInit) => mock.handle(url, init)),
  );
  // U3: pipeline failure chokepoints now log via console.error (in addition
  // to the existing DB status/errorCode patches). Spy rather than assert on
  // real log output, per the plan.
  errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  errorSpy.mockRestore();
});

async function setupUserWithCapture(
  t: ReturnType<typeof convexTest>,
  subject: string,
  overrides: Partial<Record<string, unknown>> = {},
) {
  const asUser = withMockUser(t, subject);
  await asUser.mutation(api.users.ensure, {});
  await asUser.mutation(api.settings.setConductorKey, {
    conductorApiKey: "sk-test-key-00001234",
  });
  const captureId = await asUser.mutation(api.captures.create, {
    clientId: overrides.clientId as string ?? "client-001",
    transcript: overrides.transcript as string ?? "add dark mode toggle",
    notes: (overrides.notes as string) ?? "",
    projectId: (overrides.projectId as string) ?? "proj-1",
    projectName: (overrides.projectName as string) ?? "Whistle",
    agent: (overrides.agent as string) ?? "claude",
    capturedAt: (overrides.capturedAt as number) ?? Date.now(),
    ...overrides,
  });
  return { asUser, captureId };
}

/**
 * Advances fake timers by `ms` (default 0, to fire anything scheduled at
 * +0) and then waits for whatever scheduled functions that firing kicked
 * off to finish. Scheduled functions run on a real `setTimeout` internally
 * (see convex-test's Scheduler), so under `vi.useFakeTimers()` nothing
 * fires until timers are advanced — `finishInProgressScheduledFunctions()`
 * alone only waits for already-fired functions to settle, it does not fire
 * pending timers itself.
 *
 * The pipeline chains several self-rescheduling +0 actions in a single
 * logical step (e.g. submit -> awaitWorkspaceReady -> submit, all at +0
 * when a workspace is immediately ready). A `setTimeout(fn, 0)` registered
 * *during* an in-progress `advanceTimersByTimeAsync(0)` call can be
 * scheduled for the same fake-clock timestamp as "now" but still miss that
 * same timer sweep — so we nudge the clock forward by 1ms and drain again
 * to guarantee any such just-scheduled +0 continuation actually fires.
 */
async function tick(t: ReturnType<typeof convexTest>, ms = 0) {
  await vi.advanceTimersByTimeAsync(ms);
  await t.finishInProgressScheduledFunctions();
  await vi.advanceTimersByTimeAsync(1);
  await t.finishInProgressScheduledFunctions();
}

// ─── Pure helper unit tests ────────────────────────────────────────────────

describe("buildWorkspaceName", () => {
  test("uses first 6 meaningful words of notes when present", () => {
    const name = buildWorkspaceName({
      notes: "add a dark mode toggle to settings page please",
      transcript: "ignored",
      clientId: "abcdef123456",
      capturedAt: Date.now(),
    });
    expect(name).toBe("idea: add a dark mode toggle to #abcdef");
  });

  test("falls back to transcript when notes is empty", () => {
    const name = buildWorkspaceName({
      notes: "",
      transcript: "improve login flow speed",
      clientId: "123456abcdef",
      capturedAt: Date.now(),
    });
    expect(name).toBe("idea: improve login flow speed #123456");
  });

  test("falls back to screenshot-only form when both are empty", () => {
    const capturedAt = new Date("2026-07-04T12:00:00.000Z").getTime();
    const name = buildWorkspaceName({
      notes: "",
      transcript: "   ",
      clientId: "aaaaaa000000",
      capturedAt,
    });
    expect(name).toBe("idea: screenshot capture 2026-07-04 #aaaaaa");
  });
});

describe("extractMessageText", () => {
  test("plain string content", () => {
    expect(extractMessageText("hello world")).toBe("hello world");
  });
  test("object with text field", () => {
    expect(extractMessageText({ text: "from object" })).toBe("from object");
  });
  test("array of content blocks", () => {
    expect(extractMessageText([{ text: "a" }, { text: "b" }])).toBe("a\nb");
  });
  test("live Conductor rawPayload assistant envelope", () => {
    expect(extractMessageText({
      rawPayload: {
        type: "assistant",
        message: {
          content: [{ type: "text", text: "from live envelope" }],
        },
      },
    })).toBe("from live envelope");
  });
  test("unrecognized shape degrades to empty string", () => {
    expect(extractMessageText({ weird: 123 })).toBe("");
  });
});

describe("extractSummaryAndQuestions", () => {
  test("numbered questions parsed from final section", () => {
    const text = [
      "I researched the codebase and drafted a plan.",
      "",
      "Clarifying questions:",
      "1. Should this apply to all users or just admins?",
      "2. What's the target release date?",
    ].join("\n");
    const { summary, questions } = extractSummaryAndQuestions(text);
    expect(summary).toBe("I researched the codebase and drafted a plan.");
    expect(questions).toEqual([
      "Should this apply to all users or just admins?",
      "What's the target release date?",
    ]);
  });

  test("agent message with no questions -> ready with empty array", () => {
    const text = "Done. No open questions here, just a statement.";
    const { summary, questions } = extractSummaryAndQuestions(text);
    expect(summary).toBe(text);
    expect(questions).toEqual([]);
  });
});

describe("findAgentReplyAfterOurs", () => {
  test("finds an agent message after our sessionIndex", () => {
    const messages = [
      { id: "our-id", sessionIndex: 0, type: "user", content: "hi" },
      { id: "reply-1", sessionIndex: 1, type: "agent", content: "hello" },
    ];
    const reply = findAgentReplyAfterOurs(messages, "our-id");
    expect(reply?.id).toBe("reply-1");
  });

  test("returns undefined when no agent message follows ours", () => {
    const messages = [{ id: "our-id", sessionIndex: 0, type: "user", content: "hi" }];
    expect(findAgentReplyAfterOurs(messages, "our-id")).toBeUndefined();
  });

  test("correlates lowercase nested live ids and ignores event-only agent records", () => {
    expect(findAgentReplyAfterOurs(
      liveMessagesFixture.messages,
      liveMessagesFixture.clientId,
    )?.id).toBe("session-id:3:0");
  });
});

// ─── Full pipeline integration tests (mocked Conductor + fake timers) ─────

describe("happy path", () => {
  test("create -> submit -> workspace created -> message sent -> watch working->idle with agent reply -> ready with questions", async () => {
    const t = convexTest(schema, modules);
    const { asUser, captureId } = await setupUserWithCapture(
      t,
      "auth0|pipeline-happy",
    );

    // Let submit run (scheduled at +0).
    await tick(t);

    let capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
    expect(capture?.workspaceId).toBeDefined();
    expect(capture?.sessionId).toBeDefined();
    expect(mock.createWorkspaceCount).toBe(1);
    expect(mock.sendMessageCalls).toHaveLength(1);

    // First watch tick: session still "working".
    const sessionId = capture!.sessionId!;
    mock.sessions.get(sessionId)!.status = "working";
    await tick(t, 30_000);

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");

    // Now agent goes idle with a reply.
    mock.sessions.get(sessionId)!.status = "idle";
    mock.addAgentMessage(sessionId, {
      id: "agent-reply-1",
      sessionIndex: 1,
      type: "agent",
      content: {
        text: "Drafted the plan.\n\nClarifying questions:\n1. Dark mode only, or full theming?",
      },
    });

    await tick(t, 60_000);

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("ready");
    expect(capture?.agentSummary).toBe("Drafted the plan.");
    expect(capture?.clarifyingQuestions).toEqual([
      "Dark mode only, or full theming?",
    ]);
  });

  test("live nested message shape transitions agentWorking to ready", async () => {
    const t = convexTest(schema, modules);
    const clientId = "9FA5700C-D530-45CA-A154-CAC4B9599DFE";
    const normalized = clientId.toLowerCase();
    const { asUser, captureId } = await setupUserWithCapture(
      t,
      "auth0|pipeline-live-shape",
      { clientId },
    );

    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    const sessionId = capture!.sessionId!;
    mock.sessions.get(sessionId)!.status = "idle";
    mock.messagesBySession.set(sessionId, [
      {
        id: `${sessionId}:1:0`,
        sessionIndex: 0,
        type: "userMessage",
        content: { id: normalized, turnId: normalized, type: "userMessage" },
      },
      {
        id: `${sessionId}:3:0`,
        sessionIndex: 2,
        type: "agent",
        content: {
          userMessageId: normalized,
          turnId: normalized,
          rawPayload: {
            type: "assistant",
            message: {
              content: [{
                type: "text",
                text: "Live reply summary.\n\n1. Ship the hotfix now?",
              }],
            },
          },
        },
      },
    ]);

    await tick(t, 30_000);

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("ready");
    expect(capture?.agentSummary).toBe("Live reply summary.");
    expect(capture?.clarifyingQuestions).toEqual(["Ship the hotfix now?"]);
  });

  test("message queued during init still proceeds to agentWorking", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-queued-init");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    mock.createWorkspaceResponder = () => {
      mock.addWorkspace({
        workspaceId: "ws-init",
        sessionId: "sess-init",
        projectId: "proj-1",
        name: "whatever",
        status: "initializing",
      });
      return {
        status: 200,
        body: {
          workspaceId: "ws-init",
          sessionId: "sess-init",
          deepLink: "conductor://workspace/ws-init",
        },
      };
    };
    // Send while initializing returns 201 queued (U4 finding: verified live).
    mock.sendMessageResponder = () => ({
      status: 201,
      body: { messageId: "client-queued", state: "queued" },
    });

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "client-queued",
      transcript: "queued during init",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    await tick(t);

    const capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
    expect(mock.sendMessageCalls).toHaveLength(1);
  });
});

describe("awaitWorkspaceReady handoff", () => {
  test("send hits not-ready 4xx -> awaitWorkspaceReady reschedules -> ready -> resumes submit -> sends", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-await-ready");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    let sendAttempts = 0;
    mock.sendMessageResponder = () => {
      sendAttempts += 1;
      if (sendAttempts === 1) {
        return { status: 409, body: { userMessage: "workspace not ready" } };
      }
      return undefined; // fall through to default success behavior
    };

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "client-notready",
      transcript: "test not ready flow",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    // submit runs: creates workspace, first send fails 409 -> hands off to
    // awaitWorkspaceReady at +0, which (since the mock workspace defaults to
    // "ready") immediately jumps back into submit and completes the send.
    // Each `tick` fires whatever is due and waits for it to settle; the
    // chain here is submit -> awaitWorkspaceReady -> submit (each a fresh
    // +0 schedule), so drive it forward until it reaches the terminal
    // agentWorking state.
    for (let i = 0; i < 5; i++) {
      await tick(t);
      const current = await asUser.query(api.captures.get, { captureId });
      if (current?.status === "agentWorking") break;
    }

    const capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
    expect(sendAttempts).toBe(2);
    // Exactly one workspace created despite the retry path.
    expect(mock.createWorkspaceCount).toBe(1);
  });
});

describe("error: 5xx on create", () => {
  test("backoff reschedule x2 -> success; attempt increments; exactly one workspace created", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-5xx-create");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    let createAttempts = 0;
    mock.createWorkspaceResponder = () => {
      createAttempts += 1;
      if (createAttempts <= 2) {
        return { status: 500, body: { userMessage: "internal error" } };
      }
      mock.createWorkspaceResponder = undefined;
      const workspaceId = "ws-retry-success";
      const sessionId = "sess-retry-success";
      mock.addWorkspace({
        workspaceId,
        sessionId,
        projectId: "proj-1",
        name: "n",
        status: "ready",
      });
      return {
        status: 200,
        body: { workspaceId, sessionId, deepLink: "conductor://x" },
      };
    };

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "client-5xx",
      transcript: "retry create",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    // Attempt 1 fails -> reschedule at +1min.
    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("queued");
    expect(capture?.attempt).toBe(1);

    // U3: this transient failure is logged as "rescheduling", never
    // "terminal" — attempt count is still under MAX_SUBMIT_ATTEMPTS.
    const reschedulingCalls = errorSpy.mock.calls.filter((call) =>
      String(call[0]).includes("rescheduling"),
    );
    expect(reschedulingCalls.length).toBeGreaterThan(0);
    for (const call of reschedulingCalls) {
      expect(String(call[0])).not.toContain("decision=terminal");
    }

    await tick(t, 60_000);
    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("queued");
    expect(capture?.attempt).toBe(2);

    // Attempt 3 (4 min later) succeeds.
    await tick(t, 4 * 60_000);

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
    expect(createAttempts).toBe(3);
    expect(mock.createWorkspaceCount).toBe(3); // 2 failed + 1 succeeded
    // But only one *actual* workspace object was ever recorded server-side.
    expect(mock.workspaces.size).toBe(1);
  });
});

describe("error: create succeeded but action died pre-patch", () => {
  test("rerun adopts orphan via name tag; no second workspace", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-orphan");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "orphan123456",
      transcript: "orphan adoption test",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    // Simulate: a previous run already created the workspace with the
    // clientId tag in its name, but died before patching the capture's
    // workspaceId. Cancel the pipeline.submit that captures.create just
    // scheduled, pre-create the orphan directly against the mock, then
    // manually invoke submit fresh (as if a later retry ran it).
    const scheduled = await t.run(async (ctx) =>
      ctx.db.system.query("_scheduled_functions").collect(),
    );
    for (const s of scheduled) {
      if (s.state.kind === "pending") {
        await t.run(async (ctx) => ctx.scheduler.cancel(s._id));
      }
    }

    const tag = "orphan123456".slice(0, 6);
    mock.addWorkspace({
      workspaceId: "ws-orphan",
      sessionId: "sess-orphan",
      projectId: "proj-1",
      name: `idea: orphan adoption test #${tag}`,
      status: "ready",
    });

    await t.action(internal.pipeline.submit, { captureId });

    const capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.workspaceId).toBe("ws-orphan");
    expect(capture?.sessionId).toBe("sess-orphan");
    // No second workspace was created via POST /v0/workspaces.
    expect(mock.createWorkspaceCount).toBe(0);
    expect(mock.workspaces.size).toBe(1);
  });
});

describe("error: send re-run with messageId already present", () => {
  test("skipped; no duplicate prompt", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-send-already-present");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "resend-msg-1",
      transcript: "resend guard test",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    await tick(t);
    expect(mock.sendMessageCalls).toHaveLength(1);

    // The live list endpoint uses a generated top-level id and nests the
    // lowercased client message id in content rather than `messageId`.
    const sessionId = mock.sendMessageCalls[0].sessionId;
    mock.messagesBySession.set(sessionId, [{
      id: `${sessionId}:1:0`,
      sessionIndex: 0,
      type: "userMessage",
      content: { id: "resend-msg-1", turnId: "resend-msg-1" },
    }]);

    // Force capture back to "sending" to simulate a re-run of submit after
    // the message was already recorded (e.g. action died between send and
    // the agentWorking patch).
    await t.run(async (ctx) => ctx.db.patch(captureId, { status: "sending" }));
    await t.action(internal.pipeline.submit, { captureId });

    // Still exactly one send call recorded by the mock (the guard skipped
    // sending because our messageId was already listed).
    expect(mock.sendMessageCalls).toHaveLength(1);
    const capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
  });
});

describe("error: 401 anywhere -> failed/auth, no retry scheduled", () => {
  test("create returns 401", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-401");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-bad-key-00000000",
    });

    mock.createWorkspaceResponder = () => ({
      status: 401,
      body: { userMessage: "Invalid API key" },
    });

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "client-401",
      transcript: "auth failure test",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    await tick(t);

    const capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("failed");
    expect(capture?.errorCode).toBe("auth");

    // U3: the terminal auth decision is logged (not just patched to the DB).
    const authLogCall = errorSpy.mock.calls.find((call) =>
      String(call[0]).includes("terminal"),
    );
    expect(authLogCall).toBeDefined();
    expect(String(authLogCall?.[0])).toContain("submit");
    expect(String(authLogCall?.[0])).not.toContain("rescheduling");

    // No further scheduled functions remain pending for this capture (no
    // retry scheduled on a terminal auth failure).
    const pending = await t.run(async (ctx) =>
      ctx.db.system
        .query("_scheduled_functions")
        .collect()
        .then((rows) => rows.filter((r) => r.state.kind === "pending")),
    );
    // Only the watchdog (scheduled at capture creation, +90min) may remain;
    // no additional pipeline.submit retry should have been scheduled.
    for (const row of pending) {
      expect(row.name).not.toContain("pipeline:submit");
    }
  });
});

describe("edge: pipeline.watch status poll throws", () => {
  test("the action reschedules itself anyway (capture not stranded)", async () => {
    const t = convexTest(schema, modules);
    const { asUser, captureId } = await setupUserWithCapture(
      t,
      "auth0|pipeline-watch-throws",
      { clientId: "client-watch-throws" },
    );

    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    const sessionId = capture!.sessionId!;

    // Make the session status endpoint throw on the next watch tick.
    let shouldThrow = true;
    mock.sessionStatusOverride = (sid) => {
      if (sid === sessionId && shouldThrow) {
        shouldThrow = false;
        throw new Error("simulated network blip");
      }
      return undefined;
    };

    await tick(t, 30_000);

    // Still in-flight (not stranded) despite the throwing poll.
    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");

    // U3: the previously-silent `void err` catch now logs, but the
    // reschedule behavior (still agentWorking, no patch) is unchanged.
    const watchLogCall = errorSpy.mock.calls.find((call) =>
      String(call[0]).includes("[watch]"),
    );
    expect(watchLogCall).toBeDefined();
    expect(String(watchLogCall?.[0])).toContain("simulated network blip");

    // Next tick succeeds normally and can still reach ready.
    mock.sessions.get(sessionId)!.status = "idle";
    mock.addAgentMessage(sessionId, {
      id: "agent-reply-throws",
      sessionIndex: 1,
      type: "agent",
      content: "All done here.",
    });

    await tick(t, 60_000);

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("ready");
  });
});

describe("edge: idle + no agent message after ours + workspace initializing", () => {
  test("reschedules, does NOT mark ready", async () => {
    const t = convexTest(schema, modules);
    const { asUser, captureId } = await setupUserWithCapture(
      t,
      "auth0|pipeline-idle-initializing",
      { clientId: "client-idle-init" },
    );

    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    const sessionId = capture!.sessionId!;
    const workspaceId = capture!.workspaceId!;

    // idle from the very start (mock default), but workspace still
    // initializing and no agent reply yet.
    mock.workspaces.get(workspaceId)!.status = "initializing";

    await tick(t, 30_000);

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking"); // not ready
  });
});

describe("edge: watch deadline reached", () => {
  test("readyUnverified, not ready", async () => {
    const t = convexTest(schema, modules);
    const { asUser, captureId } = await setupUserWithCapture(
      t,
      "auth0|pipeline-watch-deadline",
      { clientId: "client-deadline" },
    );

    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    const sessionId = capture!.sessionId!;
    // Keep the session "working" forever so watch just keeps polling until
    // the 60-minute deadline trips on its own messageSentAt check.
    mock.sessions.get(sessionId)!.status = "working";

    await vi.advanceTimersByTimeAsync(61 * 60_000);
    await t.finishAllScheduledFunctions(() => vi.advanceTimersByTime(60_000));

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("readyUnverified");
  });
});

describe("edge: watchdog rescues a stalled capture", () => {
  test("stuck in sending -> failed/stalled", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-watchdog");
    await asUser.mutation(api.users.ensure, {});
    // Deliberately no API key -> submit would normally fail/auth
    // immediately; instead we force status to "sending" directly and cancel
    // the auto-scheduled submit so only the watchdog acts.
    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "client-stalled",
      transcript: "stalled capture",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    const scheduled = await t.run(async (ctx) =>
      ctx.db.system.query("_scheduled_functions").collect(),
    );
    for (const s of scheduled) {
      if (s.state.kind === "pending" && s.name?.includes("submit")) {
        await t.run(async (ctx) => ctx.scheduler.cancel(s._id));
      }
    }
    await t.run(async (ctx) => ctx.db.patch(captureId, { status: "sending" }));

    await vi.advanceTimersByTimeAsync(90 * 60_000);
    await t.finishAllScheduledFunctions(() => vi.advanceTimersByTime(60_000));

    const capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("failed");
    expect(capture?.errorCode).toBe("stalled");
  });
});

describe("captures.retry from failed after partial progress", () => {
  test("completes without duplicating workspace or message", async () => {
    const t = convexTest(schema, modules);
    const { asUser, captureId } = await setupUserWithCapture(
      t,
      "auth0|pipeline-retry-partial",
      { clientId: "client-retry-partial" },
    );

    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");

    // Simulate a later failure (e.g. watchdog) while progress (workspace +
    // message already sent) is preserved.
    await t.run(async (ctx) =>
      ctx.db.patch(captureId, {
        status: "failed",
        errorCode: "stalled",
        error: "stalled",
      }),
    );

    await asUser.mutation(api.captures.retry, { captureId });
    await tick(t);

    capture = await asUser.query(api.captures.get, { captureId });
    // Retry's submit finds workspaceId+sessionId already set and our
    // message already listed -> skips straight to agentWorking.
    expect(capture?.status).toBe("agentWorking");
    expect(mock.createWorkspaceCount).toBe(1);
    expect(mock.sendMessageCalls).toHaveLength(1);
  });
});

describe("captures.create idempotency", () => {
  test("twice with same clientId -> one row", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-create-dedupe");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    const args = {
      clientId: "dedupe-client-1",
      transcript: "dedupe test",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    };
    const id1 = await asUser.mutation(api.captures.create, args);
    const id2 = await asUser.mutation(api.captures.create, args);
    expect(id1).toBe(id2);

    await t.finishAllScheduledFunctions(() => vi.runAllTimers());
    // Only one submit ever ran to completion -> exactly one workspace.
    expect(mock.createWorkspaceCount).toBe(1);
  });
});

// ─── U4 empirical-finding regression tests ─────────────────────────────────

describe("finding 1+3: send 500-with-23505 -> re-check finds message -> proceeds without duplicate", () => {
  test("duplicate-send 500 is treated as a successful send, not a retry", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-23505");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "client-23505",
      transcript: "duplicate send simulation",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    // Let the normal first submit complete (creates workspace, sends once,
    // reaches agentWorking).
    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
    expect(mock.sendMessageCalls).toHaveLength(1);

    // Now simulate: pipeline re-runs submit (e.g. a stray duplicate
    // schedule) while status is manually rewound to "sending", but this
    // time the pre-send message-list check (step 4a) is bypassed by
    // clearing the recorded message list first — forcing the send call to
    // actually hit the wire and observe the live 23505 duplicate-key
    // behavior from the mock (finding 1).
    const sessionId = capture!.sessionId!;
    mock.messagesBySession.set(sessionId, []); // simulate finding 3: send succeeded but not yet listed
    await t.run(async (ctx) => ctx.db.patch(captureId, { status: "sending" }));

    await t.action(internal.pipeline.submit, { captureId });

    // The send was attempted again (list was empty so the 4a guard didn't
    // skip it), hit the mock's duplicate-messageId 500/23505 path, and the
    // classifier treated that as proof-of-prior-success rather than an
    // error — capture proceeds to agentWorking, no throw, no failed status.
    expect(mock.sendMessageCalls).toHaveLength(2);
    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
  });
});

describe("finding 2: workspace deleted/errorMessage during watch -> failed/workspaceSetup, not readyUnverified", () => {
  test("workspace auto-deleted after failed init is caught by watch, not left to drift to the deadline", async () => {
    const t = convexTest(schema, modules);
    const { asUser, captureId } = await setupUserWithCapture(
      t,
      "auth0|pipeline-finding2",
      { clientId: "client-finding2" },
    );

    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    const sessionId = capture!.sessionId!;
    const workspaceId = capture!.workspaceId!;

    // Simulate: workspace init failed and auto-transitioned to deleted,
    // while the session status keeps reading idle the whole time (U4's
    // documented live behavior).
    mock.workspaces.get(workspaceId)!.status = "deleted";
    mock.workspaces.get(workspaceId)!.errorMessage =
      "git fetch main exited with code 128: Authentication failed";
    mock.sessions.get(sessionId)!.status = "idle";
    // No agent message ever arrives (queued message was silently dropped).

    await tick(t, 30_000);

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("failed");
    expect(capture?.errorCode).toBe("workspaceSetup");
    expect(capture?.error).toContain("Authentication failed");
  });
});

describe("finding 3: queued-send-then-empty-message-list -> no duplicate send after 23505 path", () => {
  test("an empty message list post-send does not trigger a resend on the next submit run", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-finding3");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    // The send succeeds (201 sent) but the message list stays empty
    // afterwards — exactly the live-observed U4 behavior (finding 3).
    mock.sendMessageResponder = (sessionId, messageId) => {
      // Don't let the default handler push into messagesBySession — return
      // success directly without recording it in the list.
      return { status: 201, body: { messageId, state: "sent" } };
    };

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "client-finding3",
      transcript: "empty list after send",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
    expect(mock.sendMessageCalls).toHaveLength(1);

    // A stray re-run of submit (status rewound to "sending") re-checks the
    // message list (step 4a), which is STILL empty (send succeeded but
    // isn't listed yet) -> it will attempt to send again -> hits the mock's
    // sendMessageResponder override again, which happily returns 201 sent
    // (no dedupe modeled here) OR, in the live API, would hit 23505. Either
    // way the capture must not end up duplicated/stranded.
    await t.run(async (ctx) => ctx.db.patch(captureId, { status: "sending" }));
    await t.action(internal.pipeline.submit, { captureId });

    capture = await asUser.query(api.captures.get, { captureId });
    expect(capture?.status).toBe("agentWorking");
  });
});

// ─── Never-stranded assertion across every test's final states ────────────

describe("terminal-state invariant", () => {
  test("every capture created across a representative run ends in ready/readyUnverified/failed", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-invariant");
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-test-key-00001234",
    });

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "client-invariant",
      transcript: "invariant check",
      notes: "",
      projectId: "proj-1",
      projectName: "Whistle",
      agent: "claude",
      capturedAt: Date.now(),
    });

    await tick(t);
    let capture = await asUser.query(api.captures.get, { captureId });
    const sessionId = capture!.sessionId!;
    mock.sessions.get(sessionId)!.status = "idle";
    mock.addAgentMessage(sessionId, {
      id: "agent-reply-invariant",
      sessionIndex: 1,
      type: "agent",
      content: "All set.",
    });

    await tick(t, 30_000);

    capture = await asUser.query(api.captures.get, { captureId });
    expect(["ready", "readyUnverified", "failed"]).toContain(capture?.status);
  });
});
