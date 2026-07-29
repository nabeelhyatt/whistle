import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { credsFromSettings } from "../settings";

const modules = import.meta.glob("../**/*.ts");

function withMockUser(t: ReturnType<typeof convexTest>, subject: string) {
  return t.withIdentity({ subject });
}

describe("settings.get", () => {
  test("returns defaults when no settings row exists yet", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-defaults");
    await asUser.mutation(api.users.ensure, {});

    const settings = await asUser.query(api.settings.get, {});

    expect(settings.agent).toBe("claude");
    expect(settings.screenshotsEnabled).toBe(true);
    expect(settings.hasKey).toBe(false);
    expect(settings.lastFour).toBeUndefined();
  });

  test("never includes the raw key, even right after setConductorKey", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-mask");
    await asUser.mutation(api.users.ensure, {});

    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-super-secret-key-12345678",
      conductorEnvironment: "prod",
    });

    const settings = await asUser.query(api.settings.get, {});

    expect(settings.hasKey).toBe(true);
    expect(settings.lastFour).toBe("5678");
    expect(settings.environment).toBe("prod");
    // Assert the masked shape doesn't leak the raw key under any field name.
    const serialized = JSON.stringify(settings);
    expect(serialized).not.toContain("sk-super-secret-key");
    expect(serialized).not.toContain("conductorApiKey");
  });
});

describe("settings.update", () => {
  test("creates a settings row with defaults merged with passed fields when none exists", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-update-new");
    const userId = await asUser.mutation(api.users.ensure, {});

    await asUser.mutation(api.settings.update, { model: "opus" });

    const row = await t.run(async (ctx) =>
      ctx.db
        .query("settings")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .unique(),
    );

    expect(row).not.toBeNull();
    expect(row?.agent).toBe("claude");
    expect(row?.screenshotsEnabled).toBe(true);
    expect(row?.model).toBe("opus");
  });

  test("patches only provided fields when a row already exists", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-update-existing");
    await asUser.mutation(api.users.ensure, {});

    await asUser.mutation(api.settings.update, { agent: "codex" });
    await asUser.mutation(api.settings.update, { screenshotsEnabled: false });

    const settings = await asUser.query(api.settings.get, {});
    expect(settings.agent).toBe("codex");
    expect(settings.screenshotsEnabled).toBe(false);
  });

  test("an omitted (undefined) model/defaultProjectId leaves the existing value untouched", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-update-untouched");
    await asUser.mutation(api.users.ensure, {});

    await asUser.mutation(api.settings.update, {
      model: "opus",
      defaultProjectId: "proj-1",
    });
    await asUser.mutation(api.settings.update, { agent: "codex" });

    const settings = await asUser.query(api.settings.get, {});
    expect(settings.model).toBe("opus");
    expect(settings.defaultProjectId).toBe("proj-1");
    expect(settings.agent).toBe("codex");
  });

  test("an explicit null clears a previously-set model", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-update-clear-model");
    await asUser.mutation(api.users.ensure, {});

    await asUser.mutation(api.settings.update, { model: "opus" });
    await asUser.mutation(api.settings.update, { model: null });

    const settings = await asUser.query(api.settings.get, {});
    expect(settings.model).toBeUndefined();
  });

  test("an explicit null clears a previously-set defaultProjectId", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-update-clear-project");
    await asUser.mutation(api.users.ensure, {});

    await asUser.mutation(api.settings.update, { defaultProjectId: "proj-1" });
    await asUser.mutation(api.settings.update, { defaultProjectId: null });

    const settings = await asUser.query(api.settings.get, {});
    expect(settings.defaultProjectId).toBeUndefined();
  });

  test("an explicit null on the insert path stores no literal null", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-update-null-insert");
    const userId = await asUser.mutation(api.users.ensure, {});

    // First-ever settings mutation for this user carries nulls: the insert
    // branch must normalize them to absent fields, not store literal null
    // (which would violate the v.optional(v.string()) schema on read).
    await asUser.mutation(api.settings.update, {
      model: null,
      defaultProjectId: null,
    });

    const row = await t.run(async (ctx) =>
      ctx.db
        .query("settings")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .unique(),
    );
    expect(row).not.toBeNull();
    expect(row?.model).toBeUndefined();
    expect(row?.defaultProjectId).toBeUndefined();
  });
});

describe("cross-user denial", () => {
  test("a user cannot read another user's settings", async () => {
    const t = convexTest(schema, modules);
    const userA = withMockUser(t, "auth0|cross-user-a");
    const userB = withMockUser(t, "auth0|cross-user-b");

    await userA.mutation(api.users.ensure, {});
    await userA.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-user-a-secret-0000",
      conductorEnvironment: "prod",
    });

    await userB.mutation(api.users.ensure, {});
    const settingsB = await userB.query(api.settings.get, {});

    // userB's own settings.get must reflect userB's row, not userA's key.
    expect(settingsB.hasKey).toBe(false);
  });

  test("templates and settings are scoped per-user even with identical field values", async () => {
    const t = convexTest(schema, modules);
    const userA = withMockUser(t, "auth0|scope-a");
    const userB = withMockUser(t, "auth0|scope-b");

    const userAId = await userA.mutation(api.users.ensure, {});
    const userBId = await userB.mutation(api.users.ensure, {});
    expect(userAId).not.toBe(userBId);

    await userA.mutation(api.settings.update, { agent: "cursor" });

    const settingsB = await userB.query(api.settings.get, {});
    expect(settingsB.agent).toBe("claude"); // default, unaffected by userA's update
  });
});

describe("credsFromSettings (KTD5 — default-to-prod lives in one place)", () => {
  test("legacy row (key, no conductorEnvironment) defaults to prod creds", () => {
    const creds = credsFromSettings({ conductorApiKey: "sk-legacy-0000" });
    expect(creds).toEqual({ apiKey: "sk-legacy-0000", environment: "prod" });
  });

  test("staging row builds staging creds", () => {
    const creds = credsFromSettings({
      conductorApiKey: "sk-staging-0000",
      conductorEnvironment: "staging",
    });
    expect(creds).toEqual({ apiKey: "sk-staging-0000", environment: "staging" });
  });

  test("no key -> undefined", () => {
    expect(credsFromSettings({ conductorApiKey: undefined })).toBeUndefined();
    expect(credsFromSettings(undefined)).toBeUndefined();
    expect(credsFromSettings(null)).toBeUndefined();
  });
});

describe("settings.get exposes environment (R5)", () => {
  test("a staging user's row includes environment: staging and still omits the raw key", async () => {
    const t = convexTest(schema, modules);
    const asUser = withMockUser(t, "auth0|settings-staging");
    await asUser.mutation(api.users.ensure, {});

    await asUser.mutation(api.settings.setConductorKey, {
      conductorApiKey: "sk-staging-secret-9999",
      conductorEnvironment: "staging",
    });

    const settings = await asUser.query(api.settings.get, {});
    expect(settings.environment).toBe("staging");
    expect(settings.hasKey).toBe(true);
    const serialized = JSON.stringify(settings);
    expect(serialized).not.toContain("sk-staging-secret-9999");
    expect(serialized).not.toContain("conductorApiKey");
  });
});
