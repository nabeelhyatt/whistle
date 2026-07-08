import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import { defaultTemplate } from "../defaultTemplate";
import schema from "../schema";

const modules = import.meta.glob("../**/*.ts");

function withMockUser(t: ReturnType<typeof convexTest>, subject: string) {
  return t.withIdentity({ subject });
}

describe("templates.get", () => {
  test("seeds the default template on first call without persisting a row", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|templates-seed");
    const userId = await asUser.mutation(api.users.ensure, {});

    const template = await asUser.query(api.templates.get, {});

    expect(template.body).toBe(defaultTemplate);
    expect(template.isCustomized).toBe(false);

    // Seeding via `get` (a query) must not write — no row persisted yet.
    const row = await t.run(async (ctx) =>
      ctx.db
        .query("promptTemplates")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .unique(),
    );
    expect(row).toBeNull();
  });
});

describe("templates.update / templates.reset", () => {
  test("update persists custom content; reset restores the default", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|templates-reset");
    await asUser.mutation(api.users.ensure, {});

    const customBody = "# My custom template\n{{transcript}}";
    await asUser.mutation(api.templates.update, { body: customBody });

    let template = await asUser.query(api.templates.get, {});
    expect(template.body).toBe(customBody);
    expect(template.isCustomized).toBe(true);

    await asUser.mutation(api.templates.reset, {});

    template = await asUser.query(api.templates.get, {});
    expect(template.body).toBe(defaultTemplate);
    expect(template.isCustomized).toBe(false);
  });

  test("reset before any customization creates a non-customized default row", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|templates-reset-fresh");
    const userId = await asUser.mutation(api.users.ensure, {});

    await asUser.mutation(api.templates.reset, {});

    const row = await t.run(async (ctx) =>
      ctx.db
        .query("promptTemplates")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .unique(),
    );
    expect(row).not.toBeNull();
    expect(row?.body).toBe(defaultTemplate);
    expect(row?.isCustomized).toBe(false);
  });
});

describe("cross-user denial", () => {
  test("each user gets their own independent template", async () => {
    const t = convexTest(schema, modules);
    const userA = withMockUser(t, "auth0|templates-cross-a");
    const userB = withMockUser(t, "auth0|templates-cross-b");

    await userA.mutation(api.users.ensure, {});
    await userB.mutation(api.users.ensure, {});

    await userA.mutation(api.templates.update, {
      body: "user A's private template",
    });

    const templateB = await userB.query(api.templates.get, {});
    // userB never customized, so they still see the default — userA's
    // customization must not leak across the user boundary.
    expect(templateB.body).toBe(defaultTemplate);
    expect(templateB.isCustomized).toBe(false);
  });

  test("functions reject calls with no authenticated identity", async () => {
    const t = convexTest(schema, modules);
    await expect(t.query(api.templates.get, {})).rejects.toThrow();
    await expect(
      t.mutation(api.templates.update, { body: "x" }),
    ).rejects.toThrow();
    await expect(t.mutation(api.templates.reset, {})).rejects.toThrow();
  });
});
