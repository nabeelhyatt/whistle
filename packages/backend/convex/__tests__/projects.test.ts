import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";

const modules = import.meta.glob("../**/*.ts");

// A minimal GET /v0/projects mock — the only Conductor endpoint validateKey
// touches. Tests mutate `projects` between calls to simulate a key that sees a
// different set of Conductor projects (i.e. a different account).
let projects: Array<{ id: string; name: string; gitRemote: string }>;

beforeEach(() => {
  projects = [
    { id: "p1", name: "Alpha", gitRemote: "https://github.com/org/alpha.git" },
    { id: "p2", name: "Beta", gitRemote: "https://github.com/org/beta.git" },
  ];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string) => {
      const path = url.replace("https://api.conductor.build", "");
      if (path === "/v0/projects" || path.startsWith("/v0/projects?")) {
        return new Response(
          JSON.stringify({ data: projects, offset: 0, hasMore: false }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      throw new Error(`unhandled ${path}`);
    }),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("projects.validateKey — changedFromPrevious (canonical-accounts)", () => {
  test("first key (no prior cache) reports no change", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-first" });
    await asUser.mutation(api.users.ensure, {});

    const r = await asUser.action(api.projects.validateKey, { apiKey: "k1" });
    expect(r.ok).toBe(true);
    expect(r.changedFromPrevious).toBe(false);
  });

  test("same project set on re-validate reports no change (order-independent)", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-same" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.projects.validateKey, { apiKey: "k1" });
    // Same ids, different order — must still be "no change".
    projects = [projects[1], projects[0]];
    const r = await asUser.action(api.projects.validateKey, { apiKey: "k1" });
    expect(r.ok).toBe(true);
    expect(r.changedFromPrevious).toBe(false);
  });

  test("a key that sees a different project set reports a change", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|vk-diff" });
    await asUser.mutation(api.users.ensure, {});

    await asUser.action(api.projects.validateKey, { apiKey: "k1" });
    // Different account: entirely different visible projects.
    projects = [{ id: "p9", name: "Zeta", gitRemote: "https://github.com/org/zeta.git" }];
    const r = await asUser.action(api.projects.validateKey, { apiKey: "k2" });
    expect(r.ok).toBe(true);
    expect(r.changedFromPrevious).toBe(true);
  });
});
