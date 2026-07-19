import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import type { Id } from "../_generated/dataModel";

const modules = import.meta.glob("../**/*.ts");

function withMockUser(t: ReturnType<typeof convexTest>, subject: string, email?: string) {
  return t.withIdentity({ subject, email });
}

/** Seeds a user row plus one capture/promptTemplate/projectsCache row for it. */
async function seedUserWithData(
  t: ReturnType<typeof convexTest>,
  subject: string,
  email: string | undefined,
  opts: {
    clientId?: string;
    conductorApiKey?: string;
    withProjectsCache?: boolean;
  } = {},
) {
  const asUser = withMockUser(t, subject, email);
  const userId: Id<"users"> = await asUser.mutation(api.users.ensure, {});

  await t.run(async (ctx) => {
    await ctx.db.insert("captures", {
      userId,
      clientId: opts.clientId ?? `client-${subject}`,
      transcript: "t",
      notes: "",
      projectId: "proj-1",
      projectName: "Project One",
      agent: "claude",
      capturedAt: Date.now(),
      status: "queued",
      attempt: 0,
    });
    await ctx.db.insert("promptTemplates", {
      userId,
      body: "custom body",
      isCustomized: true,
      updatedAt: Date.now(),
    });
    if (opts.withProjectsCache ?? true) {
      await ctx.db.insert("projectsCache", {
        userId,
        projects: [{ id: "proj-1", name: "Project One", gitRemote: "git@example.com" }],
        fetchedAt: Date.now(),
      });
    }
    if (opts.conductorApiKey !== undefined) {
      await ctx.db.insert("settings", {
        userId,
        conductorApiKey: opts.conductorApiKey,
        agent: "claude",
        screenshotsEnabled: true,
      });
    }
  });

  return userId;
}

describe("admin.accountReport", () => {
  test("reports every user matching the email, with counts and masked settings", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";

    const july9 = await seedUserWithData(t, "auth0|july9", email, {
      clientId: "client-july9",
      conductorApiKey: "sk-original-key-1234",
    });
    const july17 = await seedUserWithData(t, "github|july17", email, {
      clientId: "client-july17",
      conductorApiKey: "sk-pasted-key-5678",
    });

    const report = await t.query(internal.admin.accountReport, { email });

    expect(report).toHaveLength(2);
    const july9Row = report.find((r) => r.userId === july9)!;
    const july17Row = report.find((r) => r.userId === july17)!;

    expect(july9Row.authSubject).toBe("auth0|july9");
    expect(july9Row.captureCount).toBe(1);
    expect(july9Row.promptTemplateCount).toBe(1);
    expect(july9Row.hasProjectsCache).toBe(true);
    expect(july9Row.settings).toEqual({ present: true, hasKey: true, lastFour: "1234" });
    expect(july9Row.mergedInto).toBeUndefined();

    expect(july17Row.settings).toEqual({ present: true, hasKey: true, lastFour: "5678" });

    // Never leaks the raw key.
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain("sk-original-key");
    expect(serialized).not.toContain("sk-pasted-key");
  });

  test("includes rows with no email at all (full-scan fallback)", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";

    const withEmail = await seedUserWithData(t, "auth0|has-email", email);
    const withoutEmail = await seedUserWithData(t, "github|no-email", undefined);
    // An unrelated user with a different email should NOT show up.
    await seedUserWithData(t, "auth0|unrelated", "someone-else@example.com");

    const report = await t.query(internal.admin.accountReport, { email });
    const ids = report.map((r) => r.userId);

    expect(ids).toContain(withEmail);
    expect(ids).toContain(withoutEmail);
    expect(report).toHaveLength(2);
  });

  test("reflects mergedInto and a missing settings row", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const primary = await seedUserWithData(t, "auth0|primary", email, {
      conductorApiKey: "sk-a-1111",
    });
    const shell = await seedUserWithData(t, "github|shell", email);

    await t.run(async (ctx) => {
      await ctx.db.patch(shell, { mergedInto: primary });
    });

    const report = await t.query(internal.admin.accountReport, { email });
    const shellRow = report.find((r) => r.userId === shell)!;
    expect(shellRow.mergedInto).toBe(primary);
    expect(shellRow.settings).toEqual({ present: false, hasKey: false, lastFour: undefined });
  });
});

describe("admin.mergeUserData", () => {
  test("dry run returns the manifest and writes nothing", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const to = await seedUserWithData(t, "auth0|to", email, { withProjectsCache: false });
    const from = await seedUserWithData(t, "github|from", email);

    const manifest = await t.mutation(internal.admin.mergeUserData, {
      fromUserId: from,
      toUserId: to,
      dryRun: true,
    });

    expect(manifest.captures).toHaveLength(1);
    expect(manifest.promptTemplates).toHaveLength(1);
    expect(manifest.projectsCache).toHaveLength(1);
    expect(manifest.collisions.captures).toHaveLength(0);
    expect(manifest.skippedProjectsCache).toHaveLength(0);

    // Nothing actually moved.
    const fromRow = await t.run(async (ctx) => ctx.db.get(from));
    expect(fromRow?.mergedInto).toBeUndefined();
    const stillUnderFrom = await t.run(async (ctx) =>
      ctx.db
        .query("captures")
        .withIndex("by_user_time", (q) => q.eq("userId", from))
        .collect(),
    );
    expect(stillUnderFrom).toHaveLength(1);
  });

  test("dry run defaults to true when omitted", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const to = await seedUserWithData(t, "auth0|to-default", email);
    const from = await seedUserWithData(t, "github|from-default", email);

    await t.mutation(internal.admin.mergeUserData, { fromUserId: from, toUserId: to });

    const fromRow = await t.run(async (ctx) => ctx.db.get(from));
    expect(fromRow?.mergedInto).toBeUndefined();
  });

  test("live run repoints rows and marks mergedInto; settings stay untouched", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const to = await seedUserWithData(t, "auth0|live-to", email, {
      conductorApiKey: "sk-original-1111",
      withProjectsCache: false,
    });
    const from = await seedUserWithData(t, "github|live-from", email, {
      conductorApiKey: "sk-pasted-2222",
    });

    const manifest = await t.mutation(internal.admin.mergeUserData, {
      fromUserId: from,
      toUserId: to,
      dryRun: false,
    });

    expect(manifest.captures).toHaveLength(1);
    expect(manifest.promptTemplates).toHaveLength(1);
    expect(manifest.projectsCache).toHaveLength(1);

    const fromRow = await t.run(async (ctx) => ctx.db.get(from));
    expect(fromRow?.mergedInto).toBe(to);

    const toCaptures = await t.run(async (ctx) =>
      ctx.db
        .query("captures")
        .withIndex("by_user_time", (q) => q.eq("userId", to))
        .collect(),
    );
    expect(toCaptures).toHaveLength(2); // to's own + from's repointed

    const fromCapturesLeft = await t.run(async (ctx) =>
      ctx.db
        .query("captures")
        .withIndex("by_user_time", (q) => q.eq("userId", from))
        .collect(),
    );
    expect(fromCapturesLeft).toHaveLength(0);

    // Both settings rows (both Conductor keys) remain exactly where they were.
    const toSettings = await t.run(async (ctx) =>
      ctx.db
        .query("settings")
        .withIndex("by_user", (q) => q.eq("userId", to))
        .unique(),
    );
    const fromSettings = await t.run(async (ctx) =>
      ctx.db
        .query("settings")
        .withIndex("by_user", (q) => q.eq("userId", from))
        .unique(),
    );
    expect(toSettings?.conductorApiKey).toBe("sk-original-1111");
    expect(fromSettings?.conductorApiKey).toBe("sk-pasted-2222");
  });

  test("second live run finds zero rows under from and no-ops", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const to = await seedUserWithData(t, "auth0|idem-to", email);
    const from = await seedUserWithData(t, "github|idem-from", email);

    await t.mutation(internal.admin.mergeUserData, {
      fromUserId: from,
      toUserId: to,
      dryRun: false,
    });

    const secondManifest = await t.mutation(internal.admin.mergeUserData, {
      fromUserId: from,
      toUserId: to,
      dryRun: false,
    });

    expect(secondManifest.captures).toHaveLength(0);
    expect(secondManifest.promptTemplates).toHaveLength(0);
    expect(secondManifest.projectsCache).toHaveLength(0);

    const fromRow = await t.run(async (ctx) => ctx.db.get(from));
    expect(fromRow?.mergedInto).toBe(to);
  });

  test("clientId collision is skipped and reported, never overwritten", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const sharedClientId = "shared-client-uuid";

    const to = await seedUserWithData(t, "auth0|collision-to", email, {
      clientId: sharedClientId,
    });
    const from = await seedUserWithData(t, "github|collision-from", email, {
      clientId: sharedClientId,
    });

    const manifest = await t.mutation(internal.admin.mergeUserData, {
      fromUserId: from,
      toUserId: to,
      dryRun: false,
    });

    expect(manifest.captures).toHaveLength(0);
    expect(manifest.collisions.captures).toHaveLength(1);

    // The from capture is left in place, not deleted or overwritten.
    const fromCaptures = await t.run(async (ctx) =>
      ctx.db
        .query("captures")
        .withIndex("by_user_time", (q) => q.eq("userId", from))
        .collect(),
    );
    expect(fromCaptures).toHaveLength(1);
    expect(fromCaptures[0]?.clientId).toBe(sharedClientId);

    const toCaptures = await t.run(async (ctx) =>
      ctx.db
        .query("captures")
        .withIndex("by_user_time", (q) => q.eq("userId", to))
        .collect(),
    );
    expect(toCaptures).toHaveLength(1); // unchanged, still just its own
  });

  test("leaves from's projectsCache in place when to already has one", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const to = await seedUserWithData(t, "auth0|cache-to", email);
    const from = await seedUserWithData(t, "github|cache-from", email);

    const manifest = await t.mutation(internal.admin.mergeUserData, {
      fromUserId: from,
      toUserId: to,
      dryRun: false,
    });

    expect(manifest.projectsCache).toHaveLength(0);
    expect(manifest.skippedProjectsCache).toHaveLength(1);

    const fromCache = await t.run(async (ctx) =>
      ctx.db
        .query("projectsCache")
        .withIndex("by_user", (q) => q.eq("userId", from))
        .collect(),
    );
    expect(fromCache).toHaveLength(1); // left in place, not deleted
  });

  test("refuses when fromUserId === toUserId", async () => {
    const t = convexTest(schema, modules);
    const userId = await seedUserWithData(t, "auth0|solo", "nabeel@sparkcapital.com");

    await expect(
      t.mutation(internal.admin.mergeUserData, {
        fromUserId: userId,
        toUserId: userId,
        dryRun: true,
      }),
    ).rejects.toThrow();
  });

  test("refuses when either row is missing", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const to = await seedUserWithData(t, "auth0|exists", email);
    const bogusId = to; // grab a validly-shaped id, then delete it

    await t.run(async (ctx) => ctx.db.delete(bogusId));

    await expect(
      t.mutation(internal.admin.mergeUserData, {
        fromUserId: bogusId,
        toUserId: to,
        dryRun: true,
      }),
    ).rejects.toThrow();
  });

  test("refuses a from row already merged into a different user", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const primary = await seedUserWithData(t, "auth0|other-primary", email);
    const thirdParty = await seedUserWithData(t, "auth0|third", email);
    const shell = await seedUserWithData(t, "github|already-merged", email);

    await t.run(async (ctx) => {
      await ctx.db.patch(shell, { mergedInto: primary });
    });

    await expect(
      t.mutation(internal.admin.mergeUserData, {
        fromUserId: shell,
        toUserId: thirdParty,
        dryRun: true,
      }),
    ).rejects.toThrow();
  });

  test("re-running toward the SAME already-merged target is allowed (idempotent)", async () => {
    const t = convexTest(schema, modules);
    const email = "nabeel@sparkcapital.com";
    const to = await seedUserWithData(t, "auth0|reidem-to", email);
    const from = await seedUserWithData(t, "github|reidem-from", email);

    await t.mutation(internal.admin.mergeUserData, { fromUserId: from, toUserId: to, dryRun: false });

    await expect(
      t.mutation(internal.admin.mergeUserData, { fromUserId: from, toUserId: to, dryRun: true }),
    ).resolves.toBeDefined();
  });
});
