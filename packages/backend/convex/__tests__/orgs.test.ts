import { convexTest } from "convex-test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { getMe } from "../conductorClient";

const modules = import.meta.glob("../**/*.ts");

afterEach(() => {
  vi.unstubAllGlobals();
});

type MockProject = { id: string; name: string; gitRemote: string };

/**
 * Per-key Conductor mock: each API key gets its own prod-host project list
 * and optional GET /me identity (multi-org keys see disjoint projects).
 * Unknown keys 401; the staging host always 401s; /me 404s unless the key
 * has a `me` entry — the experimental-endpoint degradation path.
 */
function stubConductor(
  keys: Record<
    string,
    {
      projects: MockProject[];
      me?: { organizationId?: string; organizationName?: string };
      failWith?: number;
    }
  >,
) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string, init?: RequestInit) => {
      const json = (status: number, obj: unknown) =>
        new Response(JSON.stringify(obj), {
          status,
          headers: { "content-type": "application/json" },
        });

      const auth = (init?.headers as Record<string, string>)?.Authorization ?? "";
      const key = auth.replace("Bearer ", "");
      const entry = keys[key];

      if (url.startsWith("https://stage-api.conductor.build")) {
        return json(401, { code: "UNAUTHORIZED", userMessage: "Invalid API key" });
      }
      if (entry === undefined) {
        return json(401, { code: "UNAUTHORIZED", userMessage: "Invalid API key" });
      }
      if (entry.failWith !== undefined) {
        return json(entry.failWith, { userMessage: `simulated ${entry.failWith}` });
      }

      const path = url.replace("https://api.conductor.build", "");
      if (path === "/me") {
        if (entry.me === undefined) return json(404, { userMessage: "not found" });
        return json(200, { userId: "u1", authMethod: "api-key", ...entry.me });
      }
      if (path === "/v0/projects" || path.startsWith("/v0/projects?")) {
        const parsed = new URL(url);
        const offset = Number(parsed.searchParams.get("offset") ?? "0");
        const limit = Number(
          parsed.searchParams.get("limit") ?? String(entry.projects.length),
        );
        const data = entry.projects.slice(offset, offset + limit);
        return json(200, {
          data,
          offset,
          hasMore: offset + data.length < entry.projects.length,
        });
      }
      throw new Error(`unhandled ${path}`);
    }),
  );
}

const PROJECTS_A: MockProject[] = [
  { id: "pa1", name: "Alpha", gitRemote: "https://github.com/org/alpha.git" },
  { id: "pa2", name: "Beta", gitRemote: "https://github.com/org/beta.git" },
];
const PROJECTS_B: MockProject[] = [
  { id: "pb1", name: "Gamma", gitRemote: "https://github.com/org/gamma.git" },
];

// ─── Index semantics the multi-org design leans on ────────────────────────
//
// Every projectsCache read pins orgId on by_user_org. The legacy
// pre-migration row has NO orgId — this test verifies empirically that
// `q.eq("orgId", undefined)` addresses exactly that row (Convex indexes an
// absent optional field as undefined), because admin.ts:20-25 documents the
// opposite belief for users.by_email and the two claims had to be settled by
// a test, not an assumption.

describe("projectsCache by_user_org index", () => {
  test("q.eq('orgId', undefined) addresses the legacy no-org row; pinning an orgId addresses only that org's row", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const userId = await ctx.db.insert("users", {
        authSubject: "auth0|index-check",
        createdAt: 0,
      });
      const orgId = await ctx.db.insert("conductorOrgs", {
        userId,
        label: "Work",
        conductorApiKey: "k-org",
        conductorEnvironment: "prod",
        createdAt: 1,
      });
      await ctx.db.insert("projectsCache", {
        userId,
        projects: [],
        fetchedAt: 100, // legacy row, no orgId
      });
      await ctx.db.insert("projectsCache", {
        userId,
        orgId,
        projects: [],
        fetchedAt: 200,
      });

      const legacy = await ctx.db
        .query("projectsCache")
        .withIndex("by_user_org", (q) =>
          q.eq("userId", userId).eq("orgId", undefined),
        )
        .unique();
      expect(legacy?.fetchedAt).toBe(100);

      const orgRow = await ctx.db
        .query("projectsCache")
        .withIndex("by_user_org", (q) => q.eq("userId", userId).eq("orgId", orgId))
        .unique();
      expect(orgRow?.fetchedAt).toBe(200);

      // The failure mode this design guards against: by_user + .unique()
      // throws the moment a user has two cache rows.
      await expect(
        ctx.db
          .query("projectsCache")
          .withIndex("by_user", (q) => q.eq("userId", userId))
          .unique(),
      ).rejects.toThrow();
    });
  });

  test("foreign orgId under the right userId matches nothing (doc ids are unique across users' rows)", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const userA = await ctx.db.insert("users", {
        authSubject: "auth0|a",
        createdAt: 0,
      });
      const userB = await ctx.db.insert("users", {
        authSubject: "auth0|b",
        createdAt: 0,
      });
      const orgB = await ctx.db.insert("conductorOrgs", {
        userId: userB,
        label: "B",
        conductorApiKey: "k-b",
        conductorEnvironment: "prod",
        createdAt: 1,
      });
      await ctx.db.insert("projectsCache", {
        userId: userB,
        orgId: orgB,
        projects: [],
        fetchedAt: 1,
      });

      const crossRead = await ctx.db
        .query("projectsCache")
        .withIndex("by_user_org", (q) => q.eq("userId", userA).eq("orgId", orgB))
        .unique();
      expect(crossRead).toBeNull();
    });
  });
});

// ─── getMe (best-effort identity probe) ────────────────────────────────────

function stubMeResponse(status: number, body: unknown) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () =>
      new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
      }),
    ),
  );
}

describe("getMe", () => {
  const creds = { apiKey: "k1", environment: "prod" as const };

  test("parses organizationId and authMethod from a 200", async () => {
    stubMeResponse(200, {
      userId: "u1",
      organizationId: "org_123",
      authMethod: "api-key",
    });
    expect(await getMe(creds)).toEqual({
      organizationId: "org_123",
      organizationName: undefined,
      authMethod: "api-key",
    });
  });

  test("picks up organizationName when the API starts returning it (the seam), accepting `name` as a fallback spelling", async () => {
    stubMeResponse(200, {
      userId: "u1",
      organizationId: "org_123",
      organizationName: "TTL",
      authMethod: "api-key",
    });
    expect((await getMe(creds))?.organizationName).toBe("TTL");

    stubMeResponse(200, { userId: "u1", organizationId: "org_123", name: "TTL" });
    expect((await getMe(creds))?.organizationName).toBe("TTL");
  });

  test("returns undefined on 404 (deployment doesn't serve /me yet) and on auth errors — never throws", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      stubMeResponse(404, { userMessage: "not found" });
      expect(await getMe(creds)).toBeUndefined();

      stubMeResponse(401, { code: "UNAUTHORIZED", userMessage: "Invalid API key" });
      expect(await getMe(creds)).toBeUndefined();

      vi.stubGlobal(
        "fetch",
        vi.fn(() => Promise.reject(new Error("ENOTFOUND"))),
      );
      expect(await getMe(creds)).toBeUndefined();
    } finally {
      errorSpy.mockRestore();
    }
  });

  test("returns undefined on a non-object body", async () => {
    stubMeResponse(200, "ok");
    expect(await getMe(creds)).toBeUndefined();
  });

  test("F11: returns undefined when organizationId, organizationName, AND authMethod are all absent from a 200 body (matches the doc comment contract)", async () => {
    stubMeResponse(200, { userId: "u1" });
    expect(await getMe(creds)).toBeUndefined();
  });
});

// ─── orgs.addKey / list / rename / remove ──────────────────────────────────

describe("orgs.addKey", () => {
  test("valid key: inserts a labeled org row, seeds its cache, list returns masked metadata only", async () => {
    stubConductor({
      "sk-org-a-secret-1234": { projects: PROJECTS_A, me: { organizationId: "org_a" } },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|addkey-happy" });
    await asUser.mutation(api.users.ensure, {});

    const r = await asUser.action(api.orgs.addKey, {
      label: "TTL",
      apiKey: "sk-org-a-secret-1234",
    });
    expect(r).toMatchObject({ ok: true, environment: "prod", projectsChanged: false });

    const listed = await asUser.query(api.orgs.list, {});
    expect(listed).toHaveLength(1);
    expect(listed[0]).toMatchObject({
      label: "TTL",
      displayName: "TTL",
      lastFour: "1234",
      environment: "prod",
    });
    // Raw key never leaves the backend.
    expect(JSON.stringify(listed)).not.toContain("sk-org-a-secret");

    const projects = await asUser.query(api.projects.list, {});
    expect(projects).toMatchObject(PROJECTS_A);
    expect(projects[0].orgLabel).toBe("TTL");
  });

  test("a second key for the same organizationId is rejected, naming the existing entry", async () => {
    stubConductor({
      "k-a": { projects: PROJECTS_A, me: { organizationId: "org_a" } },
      "k-a2": { projects: PROJECTS_A, me: { organizationId: "org_a" } },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|addkey-dupe" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.orgs.addKey, { label: "TTL", apiKey: "k-a" });
    const r = await asUser.action(api.orgs.addKey, { label: "TTL again", apiKey: "k-a2" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toContain('"TTL"');
    expect(await asUser.query(api.orgs.list, {})).toHaveLength(1);
  });

  test("/me unavailable: key still saves with identity fields absent (dedupe disabled)", async () => {
    stubConductor({ "k-a": { projects: PROJECTS_A } });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|addkey-no-me" });
    await asUser.mutation(api.users.ensure, {});

    const r = await asUser.action(api.orgs.addKey, { label: "Work", apiKey: "k-a" });
    expect(r).toMatchObject({ ok: true });
    const listed = await asUser.query(api.orgs.list, {});
    expect(listed[0].organizationName).toBeUndefined();
  });

  test("invalid key (both hosts 401): nothing stored", async () => {
    stubConductor({});
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|addkey-invalid" });
    await asUser.mutation(api.users.ensure, {});

    const r = await asUser.action(api.orgs.addKey, { label: "Nope", apiKey: "k-bad" });
    expect(r.ok).toBe(false);
    expect(await asUser.query(api.orgs.list, {})).toHaveLength(0);
  });

  test("blank label defaults to Default", async () => {
    stubConductor({ "k-a": { projects: PROJECTS_A } });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|addkey-blank-label" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.orgs.addKey, { label: "   ", apiKey: "k-a" });
    const listed = await asUser.query(api.orgs.list, {});
    expect(listed[0].label).toBe("Default");
  });
});

describe("orgs.rename / displayName", () => {
  test("rename patches label only; a server organizationName wins the display name", async () => {
    stubConductor({
      "k-a": {
        projects: PROJECTS_A,
        me: { organizationId: "org_a", organizationName: "TTL Org" },
      },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|rename" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.action(api.orgs.addKey, { label: "My label", apiKey: "k-a" });

    const [before] = await asUser.query(api.orgs.list, {});
    expect(before.displayName).toBe("TTL Org"); // server name ?? label

    await asUser.mutation(api.orgs.rename, { orgId: before.orgId, label: "Renamed" });
    const [after] = await asUser.query(api.orgs.list, {});
    expect(after.label).toBe("Renamed");
    expect(after.organizationName).toBe("TTL Org");
    expect(after.displayName).toBe("TTL Org");
  });
});

describe("orgs.remove", () => {
  test("removes the row and its cache; removing the last key is allowed (zero-key state)", async () => {
    stubConductor({ "k-a": { projects: PROJECTS_A, me: { organizationId: "org_a" } } });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|remove-last" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.action(api.orgs.addKey, { label: "Only", apiKey: "k-a" });

    const [row] = await asUser.query(api.orgs.list, {});
    await asUser.mutation(api.orgs.remove, { orgId: row.orgId });

    expect(await asUser.query(api.orgs.list, {})).toHaveLength(0);
    expect(await asUser.query(api.projects.list, {})).toHaveLength(0);
    const settings = await asUser.query(api.settings.get, {});
    expect(settings.hasKey).toBe(false);
  });

  test("captures pointing at the removed row are repointed to a same-organizationId sibling", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|remove-sibling" });
    await asUser.mutation(api.users.ensure, {});

    // Two rows for one org can only exist when /me dedupe was unavailable —
    // seed them directly.
    const { orgA, orgB, captureId } = await t.run(async (ctx) => {
      const user = await ctx.db
        .query("users")
        .withIndex("by_subject", (q) => q.eq("authSubject", "auth0|remove-sibling"))
        .unique();
      const userId = user!._id;
      const orgA = await ctx.db.insert("conductorOrgs", {
        userId, label: "A", conductorApiKey: "k-a",
        conductorEnvironment: "prod", organizationId: "org_x", createdAt: 1,
      });
      const orgB = await ctx.db.insert("conductorOrgs", {
        userId, label: "B", conductorApiKey: "k-b",
        conductorEnvironment: "prod", organizationId: "org_x", createdAt: 2,
      });
      const captureId = await ctx.db.insert("captures", {
        userId, clientId: "c1", transcript: "t", notes: "", projectId: "pa1",
        projectName: "Alpha", agent: "claude", capturedAt: 1,
        status: "queued", attempt: 0, orgId: orgA,
      });
      return { orgA, orgB, captureId };
    });

    await asUser.mutation(api.orgs.remove, { orgId: orgA });

    await t.run(async (ctx) => {
      const capture = await ctx.db.get(captureId);
      expect(capture?.orgId).toBe(orgB);
      expect(await ctx.db.get(orgA)).toBeNull();
    });
  });
});

// ─── Lazy migration (users.ensure) + settings.get fallback ────────────────

describe("legacy key migration", () => {
  async function seedLegacyUser(t: ReturnType<typeof convexTest>, subject: string) {
    const asUser = t.withIdentity({ subject });
    await asUser.mutation(api.users.ensure, {});
    await t.run(async (ctx) => {
      const user = await ctx.db
        .query("users")
        .withIndex("by_subject", (q) => q.eq("authSubject", subject))
        .unique();
      await ctx.db.insert("settings", {
        userId: user!._id,
        conductorApiKey: "legacy-key-9999",
        conductorEnvironment: "staging",
        agent: "claude",
        screenshotsEnabled: true,
      });
      await ctx.db.insert("projectsCache", {
        userId: user!._id,
        projects: PROJECTS_A,
        fetchedAt: 1,
      });
    });
    return asUser;
  }

  test("next users.ensure moves the legacy key to a Default org row, repoints the cache, unsets settings — and settings.get synthesizes the full masked triple", async () => {
    stubConductor({});
    const t = convexTest(schema, modules);
    const asUser = await seedLegacyUser(t, "auth0|migrate");

    await asUser.mutation(api.users.ensure, {});

    const orgs = await asUser.query(api.orgs.list, {});
    expect(orgs).toHaveLength(1);
    expect(orgs[0]).toMatchObject({
      label: "Default",
      environment: "staging",
      lastFour: "9999",
    });

    // Old-client masked triple survives the move: hasKey AND lastFour AND
    // environment (drives masked display + the staging dashboard link).
    const settings = await asUser.query(api.settings.get, {});
    expect(settings.hasKey).toBe(true);
    expect(settings.lastFour).toBe("9999");
    expect(settings.environment).toBe("staging");

    // Cache followed the key; merged list now labels it.
    const projects = await asUser.query(api.projects.list, {});
    expect(projects).toMatchObject(PROJECTS_A);
    expect(projects[0].orgLabel).toBe("Default");

    // Legacy fields actually unset (single transaction with the insert).
    await t.run(async (ctx) => {
      const user = await ctx.db
        .query("users")
        .withIndex("by_subject", (q) => q.eq("authSubject", "auth0|migrate"))
        .unique();
      const row = await ctx.db
        .query("settings")
        .withIndex("by_user", (q) => q.eq("userId", user!._id))
        .unique();
      expect(row?.conductorApiKey).toBeUndefined();
      expect(row?.conductorEnvironment).toBeUndefined();
    });
  });

  test("F2: migration pins the new org row onto the caller's own non-terminal orgId-less captures, excludes terminal ones, and is bounded to the 50 most recent", async () => {
    stubConductor({});
    const t = convexTest(schema, modules);
    const asUser = await seedLegacyUser(t, "auth0|migrate-pin");
    const userId = await t.run(async (ctx) => {
      const user = await ctx.db
        .query("users")
        .withIndex("by_subject", (q) => q.eq("authSubject", "auth0|migrate-pin"))
        .unique();
      return user!._id;
    });

    const insertCapture = (opts: {
      clientId: string;
      status: "queued" | "creating" | "sending" | "agentWorking" | "readyUnverified" | "ready" | "failed";
      capturedAt: number;
    }) =>
      t.run(async (ctx) =>
        ctx.db.insert("captures", {
          userId,
          clientId: opts.clientId,
          transcript: "t",
          notes: "",
          projectId: "proj-1",
          projectName: "P",
          agent: "claude",
          capturedAt: opts.capturedAt,
          status: opts.status,
          attempt: 0,
        }),
      );

    // Recent non-terminal, orgId-less captures across every non-terminal
    // status — should all get pinned.
    const nonTerminalIds = await Promise.all(
      (["queued", "creating", "sending", "agentWorking", "readyUnverified"] as const).map(
        (status, i) =>
          insertCapture({ clientId: `nonterm-${status}`, status, capturedAt: 1000 + i }),
      ),
    );

    // A terminal capture (ready) — must be excluded even though it's recent
    // and orgId-less.
    const terminalReadyId = await insertCapture({
      clientId: "terminal-ready",
      status: "ready",
      capturedAt: 2000,
    });
    // A terminal capture (failed) — same.
    const terminalFailedId = await insertCapture({
      clientId: "terminal-failed",
      status: "failed",
      capturedAt: 2001,
    });

    // 60 older queued captures, older than the ones above, to prove the
    // `.take(50)` bound: the oldest of these should NOT be pinned even
    // though they're non-terminal and orgId-less, because they fall
    // outside the 50-most-recent window once the captures above are
    // included.
    const olderIds: Awaited<ReturnType<typeof insertCapture>>[] = [];
    for (let i = 0; i < 60; i++) {
      olderIds.push(
        await insertCapture({ clientId: `older-${i}`, status: "queued", capturedAt: i }),
      );
    }

    await asUser.mutation(api.users.ensure, {});

    const orgs = await asUser.query(api.orgs.list, {});
    expect(orgs).toHaveLength(1);
    const orgId = orgs[0].orgId;

    for (const id of nonTerminalIds) {
      const capture = await t.run(async (ctx) => ctx.db.get(id));
      expect(capture?.orgId).toBe(orgId);
    }

    const readyCapture = await t.run(async (ctx) => ctx.db.get(terminalReadyId));
    expect(readyCapture?.orgId).toBeUndefined();
    const failedCapture = await t.run(async (ctx) => ctx.db.get(terminalFailedId));
    expect(failedCapture?.orgId).toBeUndefined();

    // Only the 50 most recent captures (by capturedAt desc) were scanned at
    // all: the 7 captures above plus the 43 newest of the 60 "older" ones
    // fill that window, so the oldest "older" captures fall outside it and
    // stay orgId-less no matter their status.
    const oldestUnpinned = await t.run(async (ctx) => ctx.db.get(olderIds[0]));
    expect(oldestUnpinned?.orgId).toBeUndefined();
    const withinWindow = await t.run(async (ctx) => ctx.db.get(olderIds[59]));
    expect(withinWindow?.orgId).toBe(orgId);
  });

  test("migration is idempotent and never runs once org rows exist", async () => {
    stubConductor({});
    const t = convexTest(schema, modules);
    const asUser = await seedLegacyUser(t, "auth0|migrate-idem");

    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.users.ensure, {});
    expect(await asUser.query(api.orgs.list, {})).toHaveLength(1);
  });

  test("F1a: coexistence state — org rows already exist AND the legacy key is still set — clears the legacy fields (never inserts a second org row), with a distinct log marker", async () => {
    stubConductor({});
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|migrate-coexist" });
    const userId = await asUser.mutation(api.users.ensure, {});

    // Simulate the reachable-but-buggy-before-F1 state: an admin merge (or
    // an old-client setAndValidateKey racing first-launch ensure) left an
    // org row in place while the legacy settings key is still set too.
    const existingOrgId = await t.run(async (ctx) =>
      ctx.db.insert("conductorOrgs", {
        userId,
        label: "Already migrated",
        conductorApiKey: "sk-existing-org-1111",
        conductorEnvironment: "prod",
        createdAt: 1,
      }),
    );
    await t.run(async (ctx) =>
      ctx.db.insert("settings", {
        userId,
        conductorApiKey: "sk-stranded-legacy-2222",
        conductorEnvironment: "staging",
        agent: "claude",
        screenshotsEnabled: true,
      }),
    );

    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    let loggedCalls: unknown[][];
    try {
      await asUser.mutation(api.users.ensure, {});
      // Read calls before mockRestore(), which resets recorded calls (it's
      // mockReset() + restoring the original implementation).
      loggedCalls = logSpy.mock.calls;
    } finally {
      logSpy.mockRestore();
    }

    expect(
      loggedCalls.some(([msg]) =>
        String(msg).includes(`legacy-key-cleared-coexistence userId=${userId}`),
      ),
    ).toBe(true);
    expect(
      loggedCalls.some(([msg]) => String(msg).includes("legacy-key-migrated")),
    ).toBe(false);

    // Still exactly the one pre-existing org row — never a second insert.
    const orgs = await asUser.query(api.orgs.list, {});
    expect(orgs).toHaveLength(1);
    expect(orgs[0].orgId).toBe(existingOrgId);

    // Legacy fields actually cleared.
    const row = await t.run(async (ctx) =>
      ctx.db
        .query("settings")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .unique(),
    );
    expect(row?.conductorApiKey).toBeUndefined();
    expect(row?.conductorEnvironment).toBeUndefined();

    // And credsForCaptureInternal no longer resolves the stale legacy key —
    // the existing org row wins (F1b).
    const creds = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "proj-x",
    });
    expect(creds).toMatchObject({ ok: true, apiKey: "sk-existing-org-1111" });
  });

  test("no legacy key: ensure is a no-op for migration", async () => {
    stubConductor({});
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|migrate-nokey" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.mutation(api.users.ensure, {});
    expect(await asUser.query(api.orgs.list, {})).toHaveLength(0);
  });
});

// ─── Old-client shim row resolution (setAndValidateKey) ───────────────────

describe("projects.setAndValidateKey shim row resolution", () => {
  test("a GET /me organizationId match replaces that row in place (even when another row is labeled Default)", async () => {
    stubConductor({
      "k-a": { projects: PROJECTS_A, me: { organizationId: "org_a" } },
      "k-b": { projects: PROJECTS_B, me: { organizationId: "org_b" } },
      "k-b2": { projects: PROJECTS_B, me: { organizationId: "org_b" } },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|shim-me-match" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.action(api.orgs.addKey, { label: "Default", apiKey: "k-a" });
    await asUser.action(api.orgs.addKey, { label: "B org", apiKey: "k-b" });

    const r = await asUser.action(api.projects.setAndValidateKey, { apiKey: "k-b2" });
    expect(r).toMatchObject({ ok: true });

    const listed = await asUser.query(api.orgs.list, {});
    expect(listed).toHaveLength(2); // replaced, not inserted
    const bRow = listed.find((o) => o.label === "B org");
    expect(bRow?.lastFour).toBe("k-b2".slice(-4));
  });

  test("single org row is replaced even if renamed away from Default", async () => {
    stubConductor({
      "k-a": { projects: PROJECTS_A },
      "k-new": { projects: PROJECTS_A },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|shim-renamed" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.action(api.orgs.addKey, { label: "Default", apiKey: "k-a" });
    const [row] = await asUser.query(api.orgs.list, {});
    await asUser.mutation(api.orgs.rename, { orgId: row.orgId, label: "My personal org" });

    await asUser.action(api.projects.setAndValidateKey, { apiKey: "k-new" });
    const listed = await asUser.query(api.orgs.list, {});
    expect(listed).toHaveLength(1);
    expect(listed[0].label).toBe("My personal org");
    expect(listed[0].lastFour).toBe("k-new".slice(-4));
  });

  test("fresh user on an old client: inserts a Default row", async () => {
    stubConductor({ "k-a": { projects: PROJECTS_A } });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|shim-fresh" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.projects.setAndValidateKey, { apiKey: "k-a" });
    const listed = await asUser.query(api.orgs.list, {});
    expect(listed).toHaveLength(1);
    expect(listed[0].label).toBe("Default");
  });

  test("F6: 2+ orgs with no 'Default'-labeled row -> setAndValidateKey INSERTS a new Default row, never replaces the oldest row's key in place", async () => {
    stubConductor({
      "k-alpha": { projects: PROJECTS_A },
      "k-beta": { projects: PROJECTS_B },
      "k-new": { projects: PROJECTS_A },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|shim-no-default" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.action(api.orgs.addKey, { label: "Alpha", apiKey: "k-alpha" });
    await asUser.action(api.orgs.addKey, { label: "Beta", apiKey: "k-beta" });

    const before = await asUser.query(api.orgs.list, {});
    expect(before.map((o) => o.label).sort()).toEqual(["Alpha", "Beta"]);
    const alphaBefore = before.find((o) => o.label === "Alpha")!;

    const r = await asUser.action(api.projects.setAndValidateKey, { apiKey: "k-new" });
    expect(r).toMatchObject({ ok: true });

    const after = await asUser.query(api.orgs.list, {});
    expect(after).toHaveLength(3); // inserted, not replaced
    const alphaAfter = after.find((o) => o.orgId === alphaBefore.orgId)!;
    expect(alphaAfter.lastFour).toBe(alphaBefore.lastFour); // untouched

    const newDefault = after.find((o) => o.label === "Default");
    expect(newDefault).toBeDefined();
    expect(newDefault?.lastFour).toBe("k-new".slice(-4));
  });
});

// ─── F4/F15: commitValidatedOrgKeyInternal's discriminated result ─────────

describe("orgs.commitValidatedOrgKeyInternal (direct mutation-level tests)", () => {
  test("F4: insert branch re-checks organizationId uniqueness inside the mutation's own transaction, rejecting a duplicate even when called directly (not just via addKey's action-level pre-check)", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|commit-dup" });
    const userId = await asUser.mutation(api.users.ensure, {});

    const first = await t.mutation(internal.orgs.commitValidatedOrgKeyInternal, {
      userId,
      label: "First",
      conductorApiKey: "sk-first-1111",
      conductorEnvironment: "prod",
      organizationId: "org_dup",
      projects: [],
    });
    expect(first.ok).toBe(true);

    const second = await t.mutation(internal.orgs.commitValidatedOrgKeyInternal, {
      userId,
      label: "Second",
      conductorApiKey: "sk-second-2222",
      conductorEnvironment: "prod",
      organizationId: "org_dup",
      projects: [],
    });
    expect(second).toMatchObject({ ok: false, reason: "duplicateOrg", duplicateOfLabel: "First" });

    // Nothing extra was written.
    const rows = await t.run(async (ctx) =>
      ctx.db.query("conductorOrgs").withIndex("by_user", (q) => q.eq("userId", userId)).collect(),
    );
    expect(rows).toHaveLength(1);
  });

  test("F15: replace path (orgId provided) whose target row was deleted between read and commit returns ok:false reason 'rowRemoved', never throws", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|commit-row-removed" });
    const userId = await asUser.mutation(api.users.ensure, {});

    const orgId = await t.run(async (ctx) =>
      ctx.db.insert("conductorOrgs", {
        userId,
        label: "Soon gone",
        conductorApiKey: "sk-gone-3333",
        conductorEnvironment: "prod",
        createdAt: 1,
      }),
    );
    await t.run(async (ctx) => ctx.db.delete(orgId));

    const result = await t.mutation(internal.orgs.commitValidatedOrgKeyInternal, {
      userId,
      orgId,
      label: "Soon gone",
      conductorApiKey: "sk-replacement-4444",
      conductorEnvironment: "prod",
      projects: [],
    });
    expect(result).toEqual({ ok: false, reason: "rowRemoved" });
  });

});

// ─── F9: duplicate display names get disambiguated ────────────────────────

describe("F9: duplicate org display names", () => {
  test("orgs.list appends ··lastFour to every org sharing a display name; non-colliding names are untouched", async () => {
    stubConductor({
      "k-dup-1111": { projects: PROJECTS_A },
      "k-dup-2222": { projects: PROJECTS_B },
      "k-unique-3333": { projects: PROJECTS_A },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|dup-names" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.action(api.orgs.addKey, { label: "Acme", apiKey: "k-dup-1111" });
    await asUser.action(api.orgs.addKey, { label: "Acme", apiKey: "k-dup-2222" });
    await asUser.action(api.orgs.addKey, { label: "Solo", apiKey: "k-unique-3333" });

    const listed = await asUser.query(api.orgs.list, {});
    const acmeRows = listed.filter((o) => o.label === "Acme");
    expect(acmeRows).toHaveLength(2);
    expect(acmeRows.map((o) => o.displayName).sort()).toEqual(
      ["Acme··1111", "Acme··2222"].sort(),
    );
    const soloRow = listed.find((o) => o.label === "Solo")!;
    expect(soloRow.displayName).toBe("Solo");
  });

  test("projects.list's orgLabel uses the same disambiguated display names", async () => {
    stubConductor({
      "k-dup-1111": { projects: PROJECTS_A },
      "k-dup-2222": { projects: PROJECTS_B },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|dup-names-projects" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.action(api.orgs.addKey, { label: "Acme", apiKey: "k-dup-1111" });
    await asUser.action(api.orgs.addKey, { label: "Acme", apiKey: "k-dup-2222" });

    const projects = await asUser.query(api.projects.list, {});
    const labels = new Set(projects.map((p) => p.orgLabel));
    expect(labels).toEqual(new Set(["Acme··1111", "Acme··2222"]));
  });
});

// ─── refreshProjects: per-org isolation + identity backfill ───────────────

describe("projects.refreshProjects (multi-org)", () => {
  test("one bad key doesn't block the others; failures are reported; getMe backfills organizationName", async () => {
    stubConductor({
      "k-a": {
        projects: PROJECTS_A,
        me: { organizationId: "org_a", organizationName: "A Org" },
      },
      "k-b": { projects: PROJECTS_B, me: { organizationId: "org_b" } },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|refresh-multi" });
    await asUser.mutation(api.users.ensure, {});
    // Seed rows directly so org A starts without organizationName (backfill target).
    await t.run(async (ctx) => {
      const user = await ctx.db
        .query("users")
        .withIndex("by_subject", (q) => q.eq("authSubject", "auth0|refresh-multi"))
        .unique();
      await ctx.db.insert("conductorOrgs", {
        userId: user!._id, label: "A", conductorApiKey: "k-a",
        conductorEnvironment: "prod", createdAt: 1,
      });
      await ctx.db.insert("conductorOrgs", {
        userId: user!._id, label: "B", conductorApiKey: "k-dead",
        conductorEnvironment: "prod", createdAt: 2,
      });
    });

    const r = await asUser.action(api.projects.refreshProjects, {});
    expect(r.ok).toBe(true);
    expect(r.failures).toHaveLength(1);
    expect(r.failures?.[0].label).toBe("B");

    // A's cache landed and its identity was backfilled (the org-name seam).
    const projects = await asUser.query(api.projects.list, {});
    expect(projects).toMatchObject(PROJECTS_A);
    const listed = await asUser.query(api.orgs.list, {});
    const aRow = listed.find((o) => o.label === "A");
    expect(aRow?.organizationName).toBe("A Org");
    expect(aRow?.displayName).toBe("A Org");
  });

  test("all keys failing returns ok:false with the old error shape", async () => {
    stubConductor({});
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|refresh-allfail" });
    await asUser.mutation(api.users.ensure, {});
    await t.run(async (ctx) => {
      const user = await ctx.db
        .query("users")
        .withIndex("by_subject", (q) => q.eq("authSubject", "auth0|refresh-allfail"))
        .unique();
      await ctx.db.insert("conductorOrgs", {
        userId: user!._id, label: "A", conductorApiKey: "k-dead",
        conductorEnvironment: "prod", createdAt: 1,
      });
    });

    const r = await asUser.action(api.projects.refreshProjects, {});
    expect(r.ok).toBe(false);
    expect(r.error).toBeDefined();
  });
});

// ─── The two-org sweep: nothing throws at 2+ rows ──────────────────────────
//
// The `.unique()`-on-by_user class of bug only appears with a second org row,
// so a one-org suite proves nothing. Seed two orgs, then call every
// query/action a running app hits and assert none throw.

describe("two-org sweep", () => {
  test("settings.get, projects.list, orgs.list, validateKey, refreshProjects, captures.create all survive two org rows", async () => {
    stubConductor({
      "k-a": { projects: PROJECTS_A, me: { organizationId: "org_a" } },
      "k-b": { projects: PROJECTS_B, me: { organizationId: "org_b" } },
    });
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|sweep" });
    await asUser.mutation(api.users.ensure, {});
    await asUser.action(api.orgs.addKey, { label: "A", apiKey: "k-a" });
    await asUser.action(api.orgs.addKey, { label: "B", apiKey: "k-b" });

    const settings = await asUser.query(api.settings.get, {});
    expect(settings.hasKey).toBe(true);

    const projects = await asUser.query(api.projects.list, {});
    expect(projects).toHaveLength(PROJECTS_A.length + PROJECTS_B.length);
    expect(projects.map((p) => p.orgLabel)).toEqual(["A", "A", "B"]);

    expect(await asUser.query(api.orgs.list, {})).toHaveLength(2);

    const vk = await asUser.action(api.projects.validateKey, {});
    expect(vk.ok).toBe(true);

    const rp = await asUser.action(api.projects.refreshProjects, {});
    expect(rp.ok).toBe(true);
    expect(rp.failures).toBeUndefined();

    const captureId = await asUser.mutation(api.captures.create, {
      clientId: "sweep-c1",
      transcript: "hello",
      notes: "",
      projectId: "pb1",
      projectName: "Gamma",
      agent: "claude",
      capturedAt: 1,
    });
    expect(captureId).toBeDefined();

    // credsForCaptureInternal and accountReport are the other two places
    // that read every org row for a user — the `.unique()`-on-by_user class
    // of bug wouldn't show with a single org row, so they belong in this
    // sweep too.
    const userId = await t.run(async (ctx) => {
      const user = await ctx.db
        .query("users")
        .withIndex("by_subject", (q) => q.eq("authSubject", "auth0|sweep"))
        .unique();
      return user!._id;
    });

    const credsForA = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "pa1",
    });
    expect(credsForA.ok).toBe(true);
    const credsForB = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "pb1",
    });
    expect(credsForB.ok).toBe(true);
    const credsForUnknown = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "does-not-exist",
    });
    expect(credsForUnknown.ok).toBe(false);

    const report = await t.query(internal.admin.accountReport, { email: "" });
    expect(Array.isArray(report)).toBe(true);
  });
});
