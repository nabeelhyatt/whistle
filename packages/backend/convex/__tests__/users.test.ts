import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";

const modules = import.meta.glob("../**/*.ts");

function withMockUser(t: ReturnType<typeof convexTest>, subject = "auth0|mock-user-1") {
  return t.withIdentity({ subject });
}

describe("users.ensure", () => {
  test("first call inserts a new user row", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t);

    const userId = await asUser.mutation(api.users.ensure, {});

    const user = await t.run(async (ctx) => ctx.db.get(userId));
    expect(user).not.toBeNull();
    expect(user?.authSubject).toBe("auth0|mock-user-1");
  });

  test("second call is a no-op returning the same id", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t);

    const firstId = await asUser.mutation(api.users.ensure, {});
    const secondId = await asUser.mutation(api.users.ensure, {});

    expect(secondId).toBe(firstId);

    const allUsers = await t.run(async (ctx) => ctx.db.query("users").collect());
    expect(allUsers).toHaveLength(1);
  });

  test("different subjects create different users", async () => {
    const t = convexTest(schema, modules);

    const idA = await withMockUser(t, "auth0|user-a").mutation(api.users.ensure, {});
    const idB = await withMockUser(t, "auth0|user-b").mutation(api.users.ensure, {});

    expect(idA).not.toBe(idB);
  });

  test("throws when called with no identity", async () => {
    const t = convexTest(schema, modules);
    await expect(t.mutation(api.users.ensure, {})).rejects.toThrow();
  });
});
