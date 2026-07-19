import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
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

describe("users.ensure — canonical-accounts split safeguard (§3)", () => {
  let warnSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
  });

  afterEach(() => {
    warnSpy.mockRestore();
  });

  test("warns on a duplicate email with a different subject", async () => {
    const t = convexTest(schema, modules);

    await t
      .withIdentity({ subject: "auth0|july9", email: "nabeel@sparkcapital.com" })
      .mutation(api.users.ensure, {});

    warnSpy.mockClear();

    await t
      .withIdentity({
        subject: "github|july17",
        email: "nabeel@sparkcapital.com",
        emailVerified: false,
      })
      .mutation(api.users.ensure, {});

    expect(warnSpy).toHaveBeenCalledTimes(1);
    const line = warnSpy.mock.calls[0]?.[0] as string;
    expect(line).toContain("account-split-detected");
    expect(line).toContain("email=nabeel@sparkcapital.com");
    expect(line).toContain("newSubject=github|july17");
    expect(line).toContain("existingSubject=auth0|july9");
    expect(line).toContain("emailVerified=false");
  });

  test("does not warn when the same subject logs in again with the same email", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      subject: "auth0|repeat",
      email: "nabeel@sparkcapital.com",
    });

    await asUser.mutation(api.users.ensure, {});
    warnSpy.mockClear();
    await asUser.mutation(api.users.ensure, {});

    expect(warnSpy).not.toHaveBeenCalled();
  });

  test("does not warn when the identity carries no email", async () => {
    const t = convexTest(schema, modules);

    await t.withIdentity({ subject: "auth0|no-email-a" }).mutation(api.users.ensure, {});
    warnSpy.mockClear();
    await t.withIdentity({ subject: "auth0|no-email-b" }).mutation(api.users.ensure, {});

    expect(warnSpy).not.toHaveBeenCalled();
  });

  test("does not warn when the matching row is already a merged shell", async () => {
    const t = convexTest(schema, modules);

    const originalId = await t
      .withIdentity({ subject: "auth0|primary", email: "nabeel@sparkcapital.com" })
      .mutation(api.users.ensure, {});
    const shellId = await t
      .withIdentity({ subject: "github|shell", email: "nabeel@sparkcapital.com" })
      .mutation(api.users.ensure, {});

    // Simulate a completed migration: mark the shell as merged into the
    // primary, mirroring what admin.mergeUserData does.
    await t.run(async (ctx) => {
      await ctx.db.patch(shellId, { mergedInto: originalId });
    });

    warnSpy.mockClear();

    // A third subject shows up claiming the same email — the shell must be
    // skipped when looking for a still-active duplicate.
    await t
      .withIdentity({ subject: "google-oauth2|third", email: "nabeel@sparkcapital.com" })
      .mutation(api.users.ensure, {});

    expect(warnSpy).toHaveBeenCalledTimes(1);
    const line = warnSpy.mock.calls[0]?.[0] as string;
    expect(line).toContain("existingSubject=auth0|primary");
  });

  test("backfills email onto an existing subject-matched row that lacks one", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|backfill-me" });

    const userId = await asUser.mutation(api.users.ensure, {});
    const before = await t.run(async (ctx) => ctx.db.get(userId));
    expect(before?.email).toBeUndefined();

    await t
      .withIdentity({ subject: "auth0|backfill-me", email: "nabeel@sparkcapital.com" })
      .mutation(api.users.ensure, {});

    const after = await t.run(async (ctx) => ctx.db.get(userId));
    expect(after?.email).toBe("nabeel@sparkcapital.com");
  });

  test("does not overwrite an existing email on the subject-matched row", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|has-email", email: "first@example.com" });

    const userId = await asUser.mutation(api.users.ensure, {});
    await t
      .withIdentity({ subject: "auth0|has-email", email: "second@example.com" })
      .mutation(api.users.ensure, {});

    const row = await t.run(async (ctx) => ctx.db.get(userId));
    expect(row?.email).toBe("first@example.com");
  });
});

describe("users.me", () => {
  test("returns the caller's email and authSubject", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|me-user", email: "nabeel@sparkcapital.com" });
    await asUser.mutation(api.users.ensure, {});

    const me = await asUser.query(api.users.me, {});
    expect(me).toEqual({ email: "nabeel@sparkcapital.com", authSubject: "auth0|me-user" });
  });

  test("email is undefined when the identity never carried one", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "github|no-email" });
    await asUser.mutation(api.users.ensure, {});

    const me = await asUser.query(api.users.me, {});
    expect(me).toEqual({ email: undefined, authSubject: "github|no-email" });
  });

  test("throws when the user hasn't been ensure()d yet", async () => {
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({ subject: "auth0|never-ensured" });
    await expect(asUser.query(api.users.me, {})).rejects.toThrow();
  });
});
