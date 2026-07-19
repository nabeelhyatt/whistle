import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import { defaultTemplate } from "../defaultTemplate";
import schema from "../schema";

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
