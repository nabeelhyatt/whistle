import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { generateWorkspaceTitle, sanitizeTitle } from "../titleGenerator";

// generateWorkspaceTitle must never throw and must never stall the pipeline
// (see titleGenerator.ts's header comment) — every failure mode collapses to
// `null`. These tests mock global fetch the same way conductorClient.test.ts
// does for its own single-fetch-entrypoint tests.

describe("generateWorkspaceTitle", () => {
  const ORIGINAL_ENV = process.env.ANTHROPIC_API_KEY;
  let errorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    process.env.ANTHROPIC_API_KEY = "sk-ant-test-key";
  });

  afterEach(() => {
    errorSpy.mockRestore();
    vi.unstubAllGlobals();
    if (ORIGINAL_ENV === undefined) {
      delete process.env.ANTHROPIC_API_KEY;
    } else {
      process.env.ANTHROPIC_API_KEY = ORIGINAL_ENV;
    }
  });

  test("returns the sanitized title on a successful response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(
            JSON.stringify({
              content: [{ type: "text", text: "Dark mode toggle" }],
            }),
            { status: 200 },
          ),
        ),
      ),
    );

    const title = await generateWorkspaceTitle({
      transcript: "add a dark mode toggle to settings",
      notes: "",
      projectName: "Whistle",
    });

    expect(title).toBe("Dark mode toggle");
  });

  test("sends the expected request shape", async () => {
    const fetchMock = vi.fn(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({ content: [{ type: "text", text: "Some title" }] }),
          { status: 200 },
        ),
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    await generateWorkspaceTitle({
      transcript: "improve login flow",
      notes: "make it faster",
      projectName: "Whistle",
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://api.anthropic.com/v1/messages");
    expect(init.method).toBe("POST");
    expect(init.headers["x-api-key"]).toBe("sk-ant-test-key");
    expect(init.headers["anthropic-version"]).toBe("2023-06-01");
    const body = JSON.parse(init.body as string);
    expect(body.model).toBe("claude-haiku-4-5");
    expect(body.messages[0].content).toContain("improve login flow");
    expect(body.messages[0].content).toContain("make it faster");
    expect(body.messages[0].content).toContain("Whistle");
  });

  test("returns null when ANTHROPIC_API_KEY is unset, without calling fetch", async () => {
    delete process.env.ANTHROPIC_API_KEY;
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const title = await generateWorkspaceTitle({
      transcript: "anything",
      notes: "",
      projectName: "Whistle",
    });

    expect(title).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("returns null on a non-200 response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(new Response("rate limited", { status: 429 })),
      ),
    );

    const title = await generateWorkspaceTitle({
      transcript: "anything",
      notes: "",
      projectName: "Whistle",
    });

    expect(title).toBeNull();
  });

  test("returns null on a network error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.reject(new Error("getaddrinfo ENOTFOUND"))),
    );

    const title = await generateWorkspaceTitle({
      transcript: "anything",
      notes: "",
      projectName: "Whistle",
    });

    expect(title).toBeNull();
  });

  test("returns null when the request is aborted (timeout path)", async () => {
    // Exercises the same catch path a real 10s AbortController timeout takes,
    // without waiting on the real timer.
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.reject(new DOMException("This operation was aborted", "AbortError")),
      ),
    );

    const title = await generateWorkspaceTitle({
      transcript: "anything",
      notes: "",
      projectName: "Whistle",
    });

    expect(title).toBeNull();
  });

  test("returns null when the response body has no usable text block", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify({ content: [] }), { status: 200 }),
        ),
      ),
    );

    const title = await generateWorkspaceTitle({
      transcript: "anything",
      notes: "",
      projectName: "Whistle",
    });

    expect(title).toBeNull();
  });
});

describe("sanitizeTitle", () => {
  test("takes the first line only", () => {
    expect(sanitizeTitle("Dark mode toggle\nSome extra commentary")).toBe(
      "Dark mode toggle",
    );
  });

  test("strips surrounding quotes", () => {
    expect(sanitizeTitle(`"Dark mode toggle"`)).toBe("Dark mode toggle");
    expect(sanitizeTitle(`'Dark mode toggle'`)).toBe("Dark mode toggle");
  });

  test("collapses internal whitespace", () => {
    expect(sanitizeTitle("Dark   mode\ttoggle")).toBe("Dark mode toggle");
  });

  test("caps at 60 characters", () => {
    const long = "A".repeat(100);
    const result = sanitizeTitle(long);
    expect(result).not.toBeNull();
    expect(result!.length).toBe(60);
  });

  test("returns null for empty input after sanitizing", () => {
    expect(sanitizeTitle("   \n  ")).toBeNull();
    expect(sanitizeTitle("")).toBeNull();
    expect(sanitizeTitle(`""`)).toBeNull();
  });
});
