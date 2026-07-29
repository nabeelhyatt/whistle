import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { resolveConductorEnvironment, listProjects } from "../conductorClient";

const modules = import.meta.glob("../**/*.ts");

// A per-host GET /v0/projects mock — the only Conductor endpoint validateKey/
// setAndValidateKey/resolveConductorEnvironment touch. `prodProjects` /
// `stagingProjects` being `undefined` means "this host 401s the key" (the
// live, verified behavior for a wrong-environment key — KTD1/KTD4).
// `prodStatus`/`stagingStatus` let a test force a specific status (e.g. 500)
// on a host regardless of its project list.
let prodProjects: Array<{ id: string; name: string; gitRemote: string }> | undefined;
let stagingProjects: Array<{ id: string; name: string; gitRemote: string }> | undefined;
let prodStatus: number | undefined;
let stagingStatus: number | undefined;
let requestedHosts: Set<"prod" | "staging">;

beforeEach(() => {
  prodProjects = [
    { id: "p1", name: "Alpha", gitRemote: "https://github.com/org/alpha.git" },
    { id: "p2", name: "Beta", gitRemote: "https://github.com/org/beta.git" },
  ];
  stagingProjects = undefined;
  prodStatus = undefined;
  stagingStatus = undefined;
  requestedHosts = new Set();

  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string) => {
      const isStaging = url.startsWith("https://stage-api.conductor.build");
      const host: "prod" | "staging" = isStaging ? "staging" : "prod";
      requestedHosts.add(host);
      const path = url
        .replace("https://stage-api.conductor.build", "")
        .replace("https://api.conductor.build", "");

      const json = (status: number, obj: unknown) =>
        new Response(JSON.stringify(obj), {
          status,
          headers: { "content-type": "application/json" },
        });

      if (path === "/v0/projects" || path.startsWith("/v0/projects?")) {
        const statusOverride = host === "staging" ? stagingStatus : prodStatus;
        if (statusOverride !== undefined) {
          return json(statusOverride, { userMessage: `simulated ${statusOverride}` });
        }
        const projects = host === "staging" ? stagingProjects : prodProjects;
        if (projects === undefined) {
          return json(401, { code: "UNAUTHORIZED", userMessage: "Invalid API key" });
        }
        const parsed = new URL(url);
        const offset = Number(parsed.searchParams.get("offset") ?? "0");
        const limit = Number(parsed.searchParams.get("limit") ?? String(projects.length));
        const data = projects.slice(offset, offset + limit);
        return json(200, {
          data,
          offset,
          hasMore: offset + data.length < projects.length,
        });
      }
      throw new Error(`unhandled ${host} ${path}`);
    }),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

// ─── U1: resolveConductorEnvironment (probe, don't parse — KTD1/KTD4) ─────

describe("resolveConductorEnvironment", () => {
  test("key accepted on prod -> ok, environment prod, staging never called", async () => {
    const result = await resolveConductorEnvironment("k1");
    expect(result).toMatchObject({ ok: true, environment: "prod" });
    expect(requestedHosts.has("staging")).toBe(false);
  });

  test("key accepted only on staging (prod 401) -> ok, environment staging", async () => {
    prodProjects = undefined;
    stagingProjects = [
      { id: "s1", name: "Staging Alpha", gitRemote: "https://github.com/org/s-alpha.git" },
    ];
    const result = await resolveConductorEnvironment("k1");
    expect(result).toMatchObject({ ok: true, environment: "staging" });
  });

  test("both hosts 401 -> ok:false, reason invalid", async () => {
    prodProjects = undefined;
    stagingProjects = undefined;
    const result = await resolveConductorEnvironment("bad-key");
    expect(result).toEqual({
      ok: false,
      reason: "invalid",
      message: expect.any(String),
    });
  });

  test("prod 500, staging 401 -> ok:false, reason network (never invalid when a host was unreachable)", async () => {
    prodProjects = undefined;
    prodStatus = 500;
    stagingProjects = undefined;
    const result = await resolveConductorEnvironment("k1");
    expect(result.ok).toBe(false);
    expect((result as { reason: string }).reason).toBe("network");
  });

  test("a wrapper called with staging creds issues its request against the stage-api host", async () => {
    stagingProjects = [
      { id: "s1", name: "Staging Alpha", gitRemote: "https://github.com/org/s-alpha.git" },
    ];
    await listProjects({ apiKey: "k1", environment: "staging" });
    expect(requestedHosts.has("staging")).toBe(true);
    expect(requestedHosts.has("prod")).toBe(false);
  });
});

// ─── U3: projects.setAndValidateKey (one atomic action — KTD3) ────────────

describe("projects.setAndValidateKey", () => {
  test("valid staging key: row stores key+staging, cache seeded from the probe, returns environment staging", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|savk-staging" });
    await asUser.mutation(api.users.ensure, {});

    prodProjects = undefined;
    stagingProjects = [
      { id: "s1", name: "Staging Alpha", gitRemote: "https://github.com/org/s-alpha.git" },
    ];

    const r = await asUser.action(api.projects.setAndValidateKey, { apiKey: "sk-stage-1" });
    expect(r).toMatchObject({ ok: true, environment: "staging", projectsChanged: false });

    const settings = await asUser.query(api.settings.get, {});
    expect(settings.hasKey).toBe(true);
    expect(settings.environment).toBe("staging");

    const cached = await asUser.query(api.projects.list, {});
    expect(cached).toEqual(stagingProjects);
  });

  test("invalid key with a previously stored working key: ok:false, stored key/env/cache unchanged", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|savk-invalid-after-valid" });
    await asUser.mutation(api.users.ensure, {});

    // First, a valid prod key.
    await asUser.action(api.projects.setAndValidateKey, { apiKey: "sk-good" });
    const before = await asUser.query(api.settings.get, {});
    const cachedBefore = await asUser.query(api.projects.list, {});

    // Now both hosts reject a replacement key.
    prodProjects = undefined;
    stagingProjects = undefined;
    const r = await asUser.action(api.projects.setAndValidateKey, { apiKey: "sk-bad" });
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.error).toMatch(/didn't accept that key/i);
    }

    const after = await asUser.query(api.settings.get, {});
    expect(after.lastFour).toBe(before.lastFour);
    expect(after.environment).toBe(before.environment);
    const cachedAfter = await asUser.query(api.projects.list, {});
    expect(cachedAfter).toEqual(cachedBefore);
  });

  test("network failure probe: ok:false with the couldn't-reach copy, nothing stored", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|savk-network" });
    await asUser.mutation(api.users.ensure, {});

    prodProjects = undefined;
    prodStatus = 500;
    stagingProjects = undefined;

    const r = await asUser.action(api.projects.setAndValidateKey, { apiKey: "sk-whatever" });
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.error).toMatch(/couldn't reach conductor/i);
    }

    const settings = await asUser.query(api.settings.get, {});
    expect(settings.hasKey).toBe(false);
  });

  test("replacing a key with one that sees a different project set returns projectsChanged: true", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|savk-changed" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.projects.setAndValidateKey, { apiKey: "sk-first" });

    prodProjects = [{ id: "p9", name: "Zeta", gitRemote: "https://github.com/org/zeta.git" }];
    const r = await asUser.action(api.projects.setAndValidateKey, { apiKey: "sk-second" });
    expect(r).toMatchObject({ ok: true, projectsChanged: true });
  });
});

// ─── U3: validateKey (re-check the stored key; no apiKey arg — KTD6) ──────

describe("projects.validateKey — changedFromPrevious (canonical-accounts)", () => {
  test("first key (no prior cache) reports no change", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-first" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.projects.setAndValidateKey, { apiKey: "k1" });
    const r = await asUser.action(api.projects.validateKey, {});
    expect(r.ok).toBe(true);
    expect(r.changedFromPrevious).toBe(false);
  });

  test("same project set on re-validate reports no change (order-independent)", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-same" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.projects.setAndValidateKey, { apiKey: "k1" });
    // Same ids, different order — must still be "no change".
    prodProjects = [prodProjects![1], prodProjects![0]];
    const r = await asUser.action(api.projects.validateKey, {});
    expect(r.ok).toBe(true);
    expect(r.changedFromPrevious).toBe(false);
  });

  test("a key that sees a different project set reports a change", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-diff" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.projects.setAndValidateKey, { apiKey: "k1" });
    // Different account: entirely different visible projects.
    prodProjects = [{ id: "p9", name: "Zeta", gitRemote: "https://github.com/org/zeta.git" }];
    const r = await asUser.action(api.projects.validateKey, {});
    expect(r.ok).toBe(true);
    expect(r.changedFromPrevious).toBe(true);
  });

  test("previously empty project set reports a change when the next validate sees projects", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-empty-to-projects" });
    await asUser.mutation(api.users.ensure, {});

    prodProjects = [];
    await asUser.action(api.projects.setAndValidateKey, { apiKey: "k1" });

    prodProjects = [{ id: "p9", name: "Zeta", gitRemote: "https://github.com/org/zeta.git" }];
    const r = await asUser.action(api.projects.validateKey, {});
    expect(r.ok).toBe(true);
    expect(r.changedFromPrevious).toBe(true);
  });

  test("validation caches projects from every response page", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-pages" });
    await asUser.mutation(api.users.ensure, {});

    prodProjects = Array.from({ length: 51 }, (_, i) => ({
      id: `p${i + 1}`,
      name: `Project ${i + 1}`,
      gitRemote: `https://github.com/org/project-${i + 1}.git`,
    }));

    const r = await asUser.action(api.projects.setAndValidateKey, { apiKey: "k1" });
    expect(r.ok).toBe(true);
    await expect(asUser.query(api.projects.list, {})).resolves.toHaveLength(51);
  });

  test("re-checks the stored staging key against the staging host", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-staging-recheck" });
    await asUser.mutation(api.users.ensure, {});

    prodProjects = undefined;
    stagingProjects = [
      { id: "s1", name: "Staging Alpha", gitRemote: "https://github.com/org/s-alpha.git" },
    ];
    await asUser.action(api.projects.setAndValidateKey, { apiKey: "sk-stage" });
    requestedHosts.clear();

    const r = await asUser.action(api.projects.validateKey, {});
    expect(r.ok).toBe(true);
    expect(requestedHosts.has("staging")).toBe(true);
    expect(requestedHosts.has("prod")).toBe(false);
  });
});
