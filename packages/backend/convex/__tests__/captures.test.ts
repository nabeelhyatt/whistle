import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";

const modules = import.meta.glob("../**/*.ts");

function withMockUser(t: ReturnType<typeof convexTest>, subject: string) {
  return t.withIdentity({ subject });
}

/**
 * A minimal always-fails fetch stub so that any scheduled pipeline action
 * (captures.create schedules pipeline.submit + pipeline.watchdog at t=0/+90m)
 * doesn't hang the test on a real network call. These tests exercise
 * captures.ts's own logic (dedupe, list filtering, retry gating, idempotent
 * markOpened/archive) — the pipeline's own behavior is covered exhaustively
 * in pipeline.test.ts. We never advance fake timers here, so the scheduled
 * pipeline.submit/watchdog never actually run during these tests.
 */
beforeEach(() => {
  vi.useFakeTimers();
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      throw new Error("network calls are not expected in captures.test.ts");
    }),
  );
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function baseCaptureArgs(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    clientId: "client-abc123",
    transcript: "add dark mode",
    notes: "",
    projectId: "proj-1",
    projectName: "Whistle",
    agent: "claude",
    capturedAt: Date.now(),
    ...overrides,
  };
}

describe("captures.create", () => {
  test("twice with the same clientId → one row (dedupe on userId+clientId)", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-dedupe");
    await asUser.mutation(api.users.ensure, {});

    const id1 = await asUser.mutation(api.captures.create, baseCaptureArgs());
    const id2 = await asUser.mutation(api.captures.create, baseCaptureArgs());

    expect(id2).toBe(id1);

    const all = await t.run(async (ctx) => ctx.db.query("captures").collect());
    expect(all).toHaveLength(1);
  });

  test("creates with status queued and attempt 0", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-create-fresh");
    await asUser.mutation(api.users.ensure, {});

    const id = await asUser.mutation(api.captures.create, baseCaptureArgs());
    const row = await t.run(async (ctx) => ctx.db.get(id));

    expect(row?.status).toBe("queued");
    expect(row?.attempt).toBe(0);
  });
});

describe("captures.listRecent / captures.list", () => {
  test("exclude archived captures from the default view", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-archive-filter");
    await asUser.mutation(api.users.ensure, {});

    const keptId = await asUser.mutation(
      api.captures.create,
      baseCaptureArgs({ clientId: "kept-1" }),
    );
    const archivedId = await asUser.mutation(
      api.captures.create,
      baseCaptureArgs({ clientId: "archived-1" }),
    );
    await asUser.mutation(api.captures.archive, { captureId: archivedId });

    const recent = await asUser.query(api.captures.listRecent, {});
    const all = await asUser.query(api.captures.list, {});

    expect(recent.map((c) => c._id)).toEqual([keptId]);
    expect(all.map((c) => c._id)).toEqual([keptId]);
  });

  test("captures.get still returns an archived capture", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-get-archived");
    await asUser.mutation(api.users.ensure, {});

    const id = await asUser.mutation(api.captures.create, baseCaptureArgs());
    await asUser.mutation(api.captures.archive, { captureId: id });

    const got = await asUser.query(api.captures.get, { captureId: id });
    expect(got?._id).toBe(id);
    expect(got?.archivedAt).toBeDefined();
  });
});

describe("captures.markOpened", () => {
  test("patches openedAt on first call; second call is a no-op (idempotent)", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-mark-opened");
    await asUser.mutation(api.users.ensure, {});
    const id = await asUser.mutation(api.captures.create, baseCaptureArgs());

    await asUser.mutation(api.captures.markOpened, { captureId: id });
    const afterFirst = await t.run(async (ctx) => ctx.db.get(id));
    const firstOpenedAt = afterFirst?.openedAt;
    expect(firstOpenedAt).toBeDefined();

    vi.advanceTimersByTime(5000);
    await asUser.mutation(api.captures.markOpened, { captureId: id });
    const afterSecond = await t.run(async (ctx) => ctx.db.get(id));

    expect(afterSecond?.openedAt).toBe(firstOpenedAt);
  });
});

describe("captures.archive", () => {
  test("patches archivedAt; row disappears from listRecent/list", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-archive");
    await asUser.mutation(api.users.ensure, {});
    const id = await asUser.mutation(api.captures.create, baseCaptureArgs());

    await asUser.mutation(api.captures.archive, { captureId: id });

    const row = await t.run(async (ctx) => ctx.db.get(id));
    expect(row?.archivedAt).toBeDefined();

    const recent = await asUser.query(api.captures.listRecent, {});
    expect(recent.map((c) => c._id)).not.toContain(id);
  });
});

describe("captures.retry", () => {
  test("allowed from failed", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-retry-failed");
    await asUser.mutation(api.users.ensure, {});
    const id = await asUser.mutation(api.captures.create, baseCaptureArgs());
    await t.run(async (ctx) =>
      ctx.db.patch(id, {
        status: "failed",
        errorCode: "network",
        error: "boom",
        attempt: 3,
      }),
    );

    await asUser.mutation(api.captures.retry, { captureId: id });

    const row = await t.run(async (ctx) => ctx.db.get(id));
    expect(row?.status).toBe("queued");
    expect(row?.attempt).toBe(0);
    expect(row?.errorCode).toBeUndefined();
  });

  test("allowed from readyUnverified", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-retry-unverified");
    await asUser.mutation(api.users.ensure, {});
    const id = await asUser.mutation(api.captures.create, baseCaptureArgs());
    await t.run(async (ctx) => ctx.db.patch(id, { status: "readyUnverified" }));

    await asUser.mutation(api.captures.retry, { captureId: id });

    const row = await t.run(async (ctx) => ctx.db.get(id));
    expect(row?.status).toBe("queued");
  });

  test("rejected from ready (not a retryable state)", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-retry-ready");
    await asUser.mutation(api.users.ensure, {});
    const id = await asUser.mutation(api.captures.create, baseCaptureArgs());
    await t.run(async (ctx) => ctx.db.patch(id, { status: "ready" }));

    await expect(
      asUser.mutation(api.captures.retry, { captureId: id }),
    ).rejects.toThrow();
  });

  test("retry preserves existing workspaceId/sessionId (no duplication on partial progress)", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|captures-retry-partial");
    await asUser.mutation(api.users.ensure, {});
    const id = await asUser.mutation(api.captures.create, baseCaptureArgs());
    await t.run(async (ctx) =>
      ctx.db.patch(id, {
        status: "failed",
        errorCode: "network",
        workspaceId: "ws-existing",
        sessionId: "sess-existing",
      }),
    );

    await asUser.mutation(api.captures.retry, { captureId: id });

    const row = await t.run(async (ctx) => ctx.db.get(id));
    expect(row?.workspaceId).toBe("ws-existing");
    expect(row?.sessionId).toBe("sess-existing");
    expect(row?.status).toBe("queued");
  });
});

describe("cross-user denial", () => {
  test("a user cannot retry/archive/markOpened another user's capture", async () => {
    const t = convexTest(schema, modules);
    const userA = withMockUser(t, "auth0|captures-cross-a");
    const userB = withMockUser(t, "auth0|captures-cross-b");
    await userA.mutation(api.users.ensure, {});
    await userB.mutation(api.users.ensure, {});

    const id = await userA.mutation(api.captures.create, baseCaptureArgs());
    await t.run(async (ctx) => ctx.db.patch(id, { status: "failed" }));

    await expect(
      userB.mutation(api.captures.retry, { captureId: id }),
    ).rejects.toThrow();
    await expect(
      userB.mutation(api.captures.archive, { captureId: id }),
    ).rejects.toThrow();
    await expect(
      userB.mutation(api.captures.markOpened, { captureId: id }),
    ).rejects.toThrow();
    await expect(
      userB.query(api.captures.get, { captureId: id }),
    ).resolves.toBeNull();
  });
});
