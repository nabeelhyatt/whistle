import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import { defaultTemplate } from "../defaultTemplate";
import schema from "../schema";
import type { Id } from "../_generated/dataModel";

const modules = import.meta.glob("../**/*.ts");

function withMockUser(t: ReturnType<typeof convexTest>, subject: string) {
  return t.withIdentity({ subject });
}

// Regression test for the "stuck queued" production bug: getTemplateInternal
// used `await import("./defaultTemplate")` inside its handler. That dynamic
// import works fine under vitest/Node (this test would have passed even with
// the bug present) but Convex's production runtime does not support dynamic
// module imports at all, so every pipeline.submit for a user without a
// promptTemplates row threw `Uncaught TypeError: dynamic module import
// unsupported` and captures never left "queued". The fix replaces it with a
// static top-of-file import; this test only pins the *behavior* (correct
// template returned for a user with no row) since vitest's own module loader
// can't reproduce the runtime crash the dynamic import caused in production.
describe("getTemplateInternal", () => {
  test("returns the default template body for a user with no promptTemplates row", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-internal-no-template-row");
    const userId = await asUser.mutation(api.users.ensure, {});

    const body = await t.query(internal.pipelineInternal.getTemplateInternal, {
      userId,
    });

    expect(body).toBe(defaultTemplate);

    // Confirms this really is the lazy-seeding path (no row exists), same
    // invariant templates.get relies on.
    const row = await t.run(async (ctx) =>
      ctx.db
        .query("promptTemplates")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .unique(),
    );
    expect(row).toBeNull();
  });

  test("returns the customized body once a promptTemplates row exists", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|pipeline-internal-custom-template");
    const userId = await asUser.mutation(api.users.ensure, {});

    const customBody = "# custom\n{{transcript}}";
    await asUser.mutation(api.templates.update, { body: customBody });

    const body = await t.query(internal.pipelineInternal.getTemplateInternal, {
      userId,
    });

    expect(body).toBe(customBody);
  });
});

// ─── credsForCaptureInternal ────────────────────────────────────────────────
//
// The multi-org fallback chain pipeline.ts's three call sites (runSubmit,
// awaitWorkspaceReady, runWatch) all resolve through. See the doc comment on
// credsForCaptureInternal in pipelineInternal.ts for the four-branch order
// this pins.

describe("credsForCaptureInternal", () => {
  async function insertOrg(
    t: ReturnType<typeof convexTest>,
    userId: Id<"users">,
    opts: {
      label: string;
      conductorApiKey: string;
      conductorEnvironment?: "prod" | "staging";
      organizationName?: string;
      createdAt?: number;
    },
  ) {
    return await t.run(async (ctx) =>
      ctx.db.insert("conductorOrgs", {
        userId,
        label: opts.label,
        conductorApiKey: opts.conductorApiKey,
        conductorEnvironment: opts.conductorEnvironment ?? "prod",
        organizationName: opts.organizationName,
        createdAt: opts.createdAt ?? Date.now(),
      }),
    );
  }

  test("orgId set + owned row -> ok with that row's key + displayName (organizationName ?? label)", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|creds-owned");
    const userId = await asUser.mutation(api.users.ensure, {});
    const orgId = await insertOrg(t, userId, {
      label: "My Org",
      conductorApiKey: "sk-owned-1234",
      organizationName: "Server Name Inc",
    });

    const result = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      orgId,
      projectId: "proj-x",
    });

    expect(result).toEqual({
      ok: true,
      apiKey: "sk-owned-1234",
      environment: "prod",
      orgLabel: "Server Name Inc",
    });
  });

  test("orgId set + row owned by another user -> ok:false auth mentioning Settings, never falls through to a usable sibling", async () => {
    const t = convexTest(schema, modules);
    const asOwner = withMockUser(t, "auth0|creds-foreign-owner");
    const ownerUserId = await asOwner.mutation(api.users.ensure, {});
    const foreignOrgId = await insertOrg(t, ownerUserId, {
      label: "Owner's org",
      conductorApiKey: "sk-foreign-9999",
    });

    const asCaller = withMockUser(t, "auth0|creds-foreign-caller");
    const callerUserId = await asCaller.mutation(api.users.ensure, {});
    // The caller has a perfectly usable org of their own — proves the
    // foreign-row hard-fail does NOT fall through to it.
    await insertOrg(t, callerUserId, {
      label: "Caller's own org",
      conductorApiKey: "sk-caller-1111",
    });

    const result = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId: callerUserId,
      orgId: foreignOrgId,
      projectId: "proj-x",
    });

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(/Settings/);
  });

  test("orgId set + row deleted, falls through to the sibling org whose cache contains the project", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|creds-deleted-fallthrough");
    const userId = await asUser.mutation(api.users.ensure, {});

    const deletedOrgId = await insertOrg(t, userId, {
      label: "Gone",
      conductorApiKey: "sk-gone-0000",
      createdAt: 1,
    });
    await t.run(async (ctx) => ctx.db.delete(deletedOrgId));

    const orgA = await insertOrg(t, userId, {
      label: "A",
      conductorApiKey: "sk-a-1111",
      createdAt: 2,
    });
    const orgB = await insertOrg(t, userId, {
      label: "B",
      conductorApiKey: "sk-b-2222",
      createdAt: 3,
    });
    await t.run(async (ctx) => {
      await ctx.db.insert("projectsCache", {
        userId,
        orgId: orgA,
        projects: [{ id: "proj-a", name: "A", gitRemote: "git@a" }],
        fetchedAt: 1,
      });
      await ctx.db.insert("projectsCache", {
        userId,
        orgId: orgB,
        projects: [{ id: "proj-b", name: "B", gitRemote: "git@b" }],
        fetchedAt: 1,
      });
    });

    const result = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      orgId: deletedOrgId,
      projectId: "proj-b",
    });

    expect(result).toMatchObject({ ok: true, apiKey: "sk-b-2222" });
  });

  test("no orgId + legacy settings key -> legacy creds win over any org rows", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|creds-legacy");
    const userId = await asUser.mutation(api.users.ensure, {});
    await insertOrg(t, userId, { label: "Ignored org", conductorApiKey: "sk-org-ignored" });
    await t.run(async (ctx) => {
      await ctx.db.insert("settings", {
        userId,
        conductorApiKey: "sk-legacy-4444",
        conductorEnvironment: "staging",
        agent: "claude",
        screenshotsEnabled: true,
      });
    });

    const result = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "proj-x",
    });

    expect(result).toMatchObject({
      ok: true,
      apiKey: "sk-legacy-4444",
      environment: "staging",
    });
  });

  test("no orgId + no legacy + single org row -> that row", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|creds-single-org");
    const userId = await asUser.mutation(api.users.ensure, {});
    await insertOrg(t, userId, { label: "Only", conductorApiKey: "sk-only-5555" });

    const result = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "proj-x",
    });

    expect(result).toMatchObject({ ok: true, apiKey: "sk-only-5555" });
  });

  test("no orgId + multiple org rows -> the one whose cache contains the project; no match -> ok:false", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|creds-multi-org");
    const userId = await asUser.mutation(api.users.ensure, {});
    const orgA = await insertOrg(t, userId, { label: "A", conductorApiKey: "sk-a-6666", createdAt: 1 });
    const orgB = await insertOrg(t, userId, { label: "B", conductorApiKey: "sk-b-7777", createdAt: 2 });
    await t.run(async (ctx) => {
      await ctx.db.insert("projectsCache", {
        userId,
        orgId: orgA,
        projects: [{ id: "proj-a", name: "A", gitRemote: "git@a" }],
        fetchedAt: 1,
      });
      await ctx.db.insert("projectsCache", {
        userId,
        orgId: orgB,
        projects: [{ id: "proj-b", name: "B", gitRemote: "git@b" }],
        fetchedAt: 1,
      });
    });

    const matched = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "proj-b",
    });
    expect(matched).toMatchObject({ ok: true, apiKey: "sk-b-7777" });

    const unmatched = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "proj-unknown",
    });
    expect(unmatched.ok).toBe(false);
    if (!unmatched.ok) {
      expect(unmatched.error).toMatch(/removed/);
    }
  });

  test("zero keys anywhere -> ok:false 'No Conductor API key configured.'", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|creds-zero-keys");
    const userId = await asUser.mutation(api.users.ensure, {});

    const result = await t.query(internal.pipelineInternal.credsForCaptureInternal, {
      userId,
      projectId: "proj-x",
    });

    expect(result).toEqual({
      ok: false,
      error: "No Conductor API key configured.",
    });
  });
});
