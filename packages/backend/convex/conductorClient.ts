// Conductor API client: a single fetch helper plus typed endpoint wrappers.
//
// TECH-SPEC §6 "Error classification lives in one conductorFetch helper" —
// every network call the pipeline makes goes through `conductorFetch` below,
// so error taxonomy (auth / transient / workspaceSetup) is decided in exactly
// one place. See docs/CONDUCTOR-API.md for the endpoint reference and the
// empirically-verified behavior this file encodes (U4 findings).

const API_BASE = "https://api.conductor.build";

/** Conductor's error envelope (docs/CONDUCTOR-API.md "Auth" section). */
export interface StructuredError {
  code?: string;
  userMessage: string;
  debugMessage?: string;
  retryable?: boolean;
  source?: string;
  details?: unknown;
  underlying?: unknown;
}

/** The pipeline's normalized error classification (TECH-SPEC §6 + §5 errorCode). */
export type ConductorErrorClass =
  | "auth" // 401/403 — terminal, route user to Settings
  | "workspaceSetup" // other 4xx — terminal for this attempt, user-retryable
  | "network" // 5xx / network / retryable:true — transient, backoff+retry
  | "duplicateMessage" // send-shaped 500 with Postgres 23505 — NOT a blind retry (finding 1)
  | "unknown";

export class ConductorApiError extends Error {
  readonly errorClass: ConductorErrorClass;
  readonly status: number | undefined;
  readonly userMessage: string;
  readonly structured: StructuredError | undefined;

  constructor(params: {
    errorClass: ConductorErrorClass;
    status?: number;
    userMessage: string;
    structured?: StructuredError;
  }) {
    super(params.userMessage);
    this.name = "ConductorApiError";
    this.errorClass = params.errorClass;
    this.status = params.status;
    this.userMessage = params.userMessage;
    this.structured = params.structured;
  }
}

/**
 * Classifies an HTTP response's error into the pipeline's error taxonomy
 * (TECH-SPEC §6). `isSendEndpoint` special-cases the messageId-send call:
 *
 * Finding 1 (U4, unknown #6): re-POSTing the same messageId is NOT deduped
 * server-side — it hard-fails with HTTP 500 and Postgres code "23505"
 * (unique-constraint violation on session_messages_queue_pkey). This is not
 * a transient failure to blindly retry: it means *our own prior send already
 * succeeded*. The classifier surfaces this as "duplicateMessage" so
 * pipeline.submit's send step knows to re-check the session's message list
 * (step 4a) rather than resend or generically backoff-retry a 500.
 */
function classifyError(
  status: number,
  body: unknown,
  isSendEndpoint: boolean,
): ConductorErrorClass {
  const structured = parseStructuredError(body);

  if (
    isSendEndpoint &&
    status === 500 &&
    structured?.code === "23505"
  ) {
    return "duplicateMessage";
  }

  if (status === 401 || status === 403) {
    return "auth";
  }

  if (status >= 500) {
    return "network";
  }

  if (structured?.retryable === true) {
    return "network";
  }

  if (status >= 400) {
    return "workspaceSetup";
  }

  return "unknown";
}

function parseStructuredError(body: unknown): StructuredError | undefined {
  if (
    body !== null &&
    typeof body === "object" &&
    "userMessage" in body &&
    typeof (body as { userMessage?: unknown }).userMessage === "string"
  ) {
    return body as StructuredError;
  }
  return undefined;
}

function defaultUserMessage(status: number, rawText: string): string {
  if (rawText.trim().length > 0) return rawText.slice(0, 500);
  return `Conductor API request failed with status ${status}`;
}

export interface ConductorFetchOptions {
  apiKey: string;
  method: "GET" | "POST";
  path: string;
  body?: unknown;
  /**
   * Marks the `POST /v0/sessions/{id}/messages` call so the classifier can
   * apply the 23505-duplicate special-case (finding 1). Every other endpoint
   * leaves this false.
   */
  isSendEndpoint?: boolean;
}

/**
 * The single fetch entrypoint for all Conductor API calls. On success,
 * returns the parsed JSON body. On failure, throws a `ConductorApiError`
 * carrying the normalized error class and `StructuredError.userMessage`
 * (falling back to a generic message when the body isn't the expected
 * shape — docs/CONDUCTOR-API.md notes `content`/error bodies are untyped
 * and must be parsed defensively).
 */
export async function conductorFetch<T = unknown>(
  options: ConductorFetchOptions,
): Promise<T> {
  const { apiKey, method, path, body, isSendEndpoint = false } = options;
  const url = `${API_BASE}${path}`;

  let res: Response;
  try {
    res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch (err) {
    // Network-level failure (DNS, connection refused, etc.) — always
    // transient per §6. Log so this is visible in the Convex dashboard's
    // live function logs (never log the API key or request body).
    const message = err instanceof Error ? err.message : String(err);
    console.error(
      `Conductor API network error: ${method} ${path} — ${message}`,
    );
    throw new ConductorApiError({
      errorClass: "network",
      userMessage: `Network error calling Conductor API: ${message}`,
    });
  }

  const rawText = await res.text();
  let parsedBody: unknown;
  try {
    parsedBody = rawText ? JSON.parse(rawText) : undefined;
  } catch {
    parsedBody = undefined;
  }

  if (!res.ok) {
    const errorClass = classifyError(res.status, parsedBody, isSendEndpoint);
    const structured = parseStructuredError(parsedBody);
    // Log so non-2xx failures are visible in the Convex dashboard's live
    // function logs (never log the API key or request body).
    console.error(
      `Conductor API error: ${method} ${path} — status=${res.status} errorClass=${errorClass}`,
    );
    throw new ConductorApiError({
      errorClass,
      status: res.status,
      userMessage: structured?.userMessage ?? defaultUserMessage(res.status, rawText),
      structured,
    });
  }

  return parsedBody as T;
}

// ─── Typed endpoint wrappers ────────────────────────────────────────────

export interface ConductorProject {
  id: string;
  name: string;
  gitRemote: string;
}

export interface ListProjectsResponse {
  data: ConductorProject[];
  offset: number;
  hasMore: boolean;
}

export async function listProjects(
  apiKey: string,
  opts?: { limit?: number; offset?: number },
): Promise<ListProjectsResponse> {
  const params = new URLSearchParams();
  if (opts?.limit !== undefined) params.set("limit", String(opts.limit));
  if (opts?.offset !== undefined) params.set("offset", String(opts.offset));
  const qs = params.toString();
  return conductorFetch<ListProjectsResponse>({
    apiKey,
    method: "GET",
    path: `/v0/projects${qs ? `?${qs}` : ""}`,
  });
}

export interface CreateWorkspaceResponse {
  workspaceId: string;
  sessionId: string;
  deepLink: string;
}

export async function createWorkspace(
  apiKey: string,
  args: { projectId: string; name: string; agent: string; model?: string },
): Promise<CreateWorkspaceResponse> {
  return conductorFetch<CreateWorkspaceResponse>({
    apiKey,
    method: "POST",
    path: "/v0/workspaces",
    body: {
      projectId: args.projectId,
      name: args.name,
      agent: args.agent,
      ...(args.model !== undefined && { model: args.model }),
    },
  });
}

export type WorkspaceStatusValue =
  | "initializing"
  | "ready"
  | "sleeping"
  | "archived"
  | "deleted"
  | "updating";

export interface WorkspaceStatusResponse {
  status: WorkspaceStatusValue;
  lifecycleStep?: string;
  errorMessage?: string;
  updatedAt?: string | number;
}

export async function getWorkspaceStatus(
  apiKey: string,
  workspaceId: string,
): Promise<WorkspaceStatusResponse> {
  return conductorFetch<WorkspaceStatusResponse>({
    apiKey,
    method: "GET",
    path: `/v0/workspaces/${workspaceId}/status`,
  });
}

export interface SendMessageResponse {
  messageId: string;
  state: "queued" | "sent";
}

/**
 * Sends a prompt to a session. Callers MUST perform the step-4a message-list
 * check (see pipeline.ts) before calling this, and MUST treat a thrown
 * "duplicateMessage" error class as proof the send already succeeded rather
 * than retrying (finding 1 / unknown #6).
 */
export async function sendMessage(
  apiKey: string,
  sessionId: string,
  args: { message: string; messageId: string },
): Promise<SendMessageResponse> {
  return conductorFetch<SendMessageResponse>({
    apiKey,
    method: "POST",
    path: `/v0/sessions/${sessionId}/messages`,
    body: { message: args.message, messageId: args.messageId },
    isSendEndpoint: true,
  });
}

export type SessionStatusValue = "idle" | "working" | "error";

export interface SessionStatusResponse {
  status: SessionStatusValue;
  errorMessage?: string;
}

export async function getSessionStatus(
  apiKey: string,
  sessionId: string,
): Promise<SessionStatusResponse> {
  return conductorFetch<SessionStatusResponse>({
    apiKey,
    method: "GET",
    path: `/v0/sessions/${sessionId}/status`,
  });
}

/**
 * A message in a session's conversation. `content` is untyped in the
 * Conductor OpenAPI schema (docs/CONDUCTOR-API.md) — parse it defensively.
 * `id`/`messageId` are both accepted since the live API's message-list shape
 * for the client-supplied id is not yet confirmed by a real fixture (U4
 * unknown #4 remains blocked on a working scratch-project agent run); once
 * that fixture exists, only field-name mapping in `extractOurMessageId`
 * below needs to change, not the extraction call sites.
 */
export interface ConductorMessage {
  id?: string;
  messageId?: string;
  sessionId?: string;
  sessionIndex?: number;
  type?: string;
  content?: unknown;
  receivedAt?: string | number;
}

export interface ListMessagesResponse {
  data: ConductorMessage[];
}

export async function listMessages(
  apiKey: string,
  sessionId: string,
): Promise<ListMessagesResponse> {
  return conductorFetch<ListMessagesResponse>({
    apiKey,
    method: "GET",
    path: `/v0/sessions/${sessionId}/messages`,
  });
}

export interface ConductorWorkspaceListEntry {
  id?: string;
  workspaceId?: string;
  name?: string;
  status?: string;
}

export interface ListProjectWorkspacesResponse {
  data: ConductorWorkspaceListEntry[];
}

export async function listProjectWorkspaces(
  apiKey: string,
  projectId: string,
): Promise<ListProjectWorkspacesResponse> {
  return conductorFetch<ListProjectWorkspacesResponse>({
    apiKey,
    method: "GET",
    path: `/v0/projects/${projectId}/workspaces`,
  });
}

export interface ConductorSession {
  id?: string;
  sessionId?: string;
}

export interface ListWorkspaceSessionsResponse {
  data: ConductorSession[];
}

export async function listWorkspaceSessions(
  apiKey: string,
  workspaceId: string,
): Promise<ListWorkspaceSessionsResponse> {
  return conductorFetch<ListWorkspaceSessionsResponse>({
    apiKey,
    method: "GET",
    path: `/v0/workspaces/${workspaceId}/sessions`,
  });
}
