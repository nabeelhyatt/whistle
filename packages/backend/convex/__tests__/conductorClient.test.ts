import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { conductorFetch, ConductorApiError } from "../conductorClient";

// U3: conductorFetch is the single fetch entrypoint for all Conductor API
// calls (see conductorClient.ts's header comment) — these tests verify the
// two failure chokepoints (network-level throw, non-2xx response) each log
// via console.error so failures are visible in the Convex dashboard's live
// function logs, without changing the thrown ConductorApiError's shape.

describe("conductorFetch logging", () => {
  let errorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    errorSpy.mockRestore();
    vi.unstubAllGlobals();
  });

  test("network-level throw logs method/path/message and still throws a network ConductorApiError", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.reject(new Error("getaddrinfo ENOTFOUND"))),
    );

    await expect(
      conductorFetch({
        apiKey: "sk-should-never-be-logged",
        method: "GET",
        path: "/v0/projects",
      }),
    ).rejects.toMatchObject({
      errorClass: "network",
    } satisfies Partial<ConductorApiError>);

    expect(errorSpy).toHaveBeenCalledTimes(1);
    const [message] = errorSpy.mock.calls[0];
    expect(message).toContain("GET");
    expect(message).toContain("/v0/projects");
    expect(message).toContain("getaddrinfo ENOTFOUND");
    // Never log the API key.
    expect(message).not.toContain("sk-should-never-be-logged");
  });

  test("non-2xx response logs method/path/status/errorClass and still throws a classified ConductorApiError", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify({ userMessage: "Invalid API key" }), {
            status: 401,
            headers: { "content-type": "application/json" },
          }),
        ),
      ),
    );

    await expect(
      conductorFetch({
        apiKey: "sk-should-never-be-logged",
        method: "POST",
        path: "/v0/workspaces",
        body: { secretPrompt: "should never be logged either" },
      }),
    ).rejects.toMatchObject({
      errorClass: "auth",
      status: 401,
    } satisfies Partial<ConductorApiError>);

    expect(errorSpy).toHaveBeenCalledTimes(1);
    const [message] = errorSpy.mock.calls[0];
    expect(message).toContain("POST");
    expect(message).toContain("/v0/workspaces");
    expect(message).toContain("401");
    expect(message).toContain("auth");
    // Never log the API key or the request body (which carries the
    // rendered prompt).
    expect(message).not.toContain("sk-should-never-be-logged");
    expect(message).not.toContain("secretPrompt");
    expect(message).not.toContain("should never be logged either");
  });
});
