import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { generateWorkspaceTitle, sanitizeTitle } from "../titleGenerator";

// generateWorkspaceTitle must never throw and must never stall the pipeline
// (see titleGenerator.ts's header comment) — every failure mode collapses to
// `null`. These tests mock global fetch the same way conductorClient.test.ts
// does for its own single-fetch-entrypoint tests.

describe("generateWorkspaceTitle", () => {
  const ORIGINAL_ENV = process.env.OPENROUTER_API_KEY;
  let errorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    process.env.OPENROUTER_API_KEY = "sk-or-test-key";
  });

  afterEach(() => {
    errorSpy.mockRestore();
    vi.unstubAllGlobals();
    if (ORIGINAL_ENV === undefined) {
      delete process.env.OPENROUTER_API_KEY;
    } else {
      process.env.OPENROUTER_API_KEY = ORIGINAL_ENV;
    }
  });

  test("returns the sanitized title on a successful response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(
            JSON.stringify({
              choices: [{ message: { content: "Dark mode toggle" } }],
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
          JSON.stringify({ choices: [{ message: { content: "Some title" } }] }),
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
    expect(url).toBe("https://openrouter.ai/api/v1/chat/completions");
    expect(init.method).toBe("POST");
    expect(init.headers.authorization).toBe("Bearer sk-or-test-key");
    const body = JSON.parse(init.body as string);
    expect(body.model).toBe("anthropic/claude-haiku-4.5");
    expect(body.messages[0].content).toContain("improve login flow");
    expect(body.messages[0].content).toContain("make it faster");
    expect(body.messages[0].content).toContain("Whistle");
  });

  test("returns null when OPENROUTER_API_KEY is unset, without calling fetch", async () => {
    delete process.env.OPENROUTER_API_KEY;
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
    vi.useFakeTimers();
    vi.stubGlobal(
      "fetch",
      vi.fn((_url: string, init?: RequestInit) =>
        new Promise((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => {
            reject(new DOMException("This operation was aborted", "AbortError"));
          });
        }),
      ),
    );

    const titlePromise = generateWorkspaceTitle({
      transcript: "anything",
      notes: "",
      projectName: "Whistle",
    });
    await vi.advanceTimersByTimeAsync(2_000);

    const title = await titlePromise;
    expect(title).toBeNull();
  });

  test("returns null when the response body has no usable content", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify({ choices: [] }), { status: 200 }),
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
    const long = Array.from({ length: 5 }, () => "A".repeat(15)).join(" ");
    const result = sanitizeTitle(long);
    expect(result).not.toBeNull();
    expect(result!.length).toBe(60);
  });

  test("returns null for titles outside the required 3-5 word range", () => {
    expect(sanitizeTitle("Settings")).toBeNull();
    expect(sanitizeTitle("One two three four five six")).toBeNull();
  });

  test("removes orphan-tag delimiters and trailing punctuation", () => {
    expect(sanitizeTitle("Capture #panel redesign!")).toBe("Capture panel redesign");
  });

  test("returns null for empty input after sanitizing", () => {
    expect(sanitizeTitle("   \n  ")).toBeNull();
    expect(sanitizeTitle("")).toBeNull();
    expect(sanitizeTitle(`""`)).toBeNull();
  });
});
