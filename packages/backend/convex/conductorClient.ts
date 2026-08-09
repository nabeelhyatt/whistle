// Conductor API client: a single fetch helper plus typed endpoint wrappers.
//
// TECH-SPEC §6 "Error classification lives in one conductorFetch helper" —
// every network call the pipeline makes goes through `conductorFetch` below,
// so error taxonomy (auth / transient / workspaceSetup) is decided in exactly
// one place. See docs/CONDUCTOR-API.md for the endpoint reference and the
// empirically-verified behavior this file encodes (U4 findings).

/** The two Conductor API deployments. Keys carry no environment marker —
 * WorkOS-minted, each Roundhouse deployment validates against its own WorkOS
 * environment — so the environment is discovered by probing (see
 * `resolveConductorEnvironment` below), never parsed from the key. */
export type ConductorEnvironment = "prod" | "staging";

export const CONDUCTOR_API_BASES: Record<ConductorEnvironment, string> = {
  prod: "https://api.conductor.build",
  staging: "https://stage-api.conductor.build",
};

/** A resolved key + the environment it was validated against. Every typed
 * wrapper below takes this instead of a bare `apiKey` so the base URL always
 * travels with the key that was probed against it (KTD2). */
export interface ConductorCreds {
  apiKey: string;
  environment: ConductorEnvironment;
}

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
  creds: ConductorCreds;
  method: "GET" | "POST";
  path: string;
  body?: unknown;
  /**
   * Marks the `POST /v0/sessions/{id}/messages` call so the classifier can
   * apply the 23505-duplicate special-case (finding 1). Every other endpoint
   * leaves this false.
   */
  isSendEndpoint?: boolean;
  /**
   * When `false`, suppresses the `console.error` this helper otherwise emits
   * on both failure paths (network-level throw and non-2xx response).
   * Defaults to `true` — every caller keeps logging except `getMe` (F12),
   * which uses this for its own /me probe: a 404 from a deployment that
   * doesn't serve /me yet is expected, not an error worth surfacing in the
   * Convex dashboard's live logs.
   */
  logErrors?: boolean;
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
  const { creds, method, path, body, isSendEndpoint = false, logErrors = true } = options;
  const url = `${CONDUCTOR_API_BASES[creds.environment]}${path}`;

  let res: Response;
  try {
    res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${creds.apiKey}`,
        "Content-Type": "application/json",
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch (err) {
    // Network-level failure (DNS, connection refused, etc.) — always
    // transient per §6. Log so this is visible in the Convex dashboard's
    // live function logs (never log the API key or request body).
    const message = err instanceof Error ? err.message : String(err);
    if (logErrors) {
      console.error(
        `Conductor API network error: ${method} ${path} — ${message}`,
      );
    }
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
    if (logErrors) {
      console.error(
        `Conductor API error: ${method} ${path} — status=${res.status} errorClass=${errorClass}`,
      );
    }
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
  creds: ConductorCreds,
  opts?: { limit?: number; offset?: number },
): Promise<ListProjectsResponse> {
  const params = new URLSearchParams();
  if (opts?.limit !== undefined) params.set("limit", String(opts.limit));
  if (opts?.offset !== undefined) params.set("offset", String(opts.offset));
  const qs = params.toString();
  return conductorFetch<ListProjectsResponse>({
    creds,
    method: "GET",
    path: `/v0/projects${qs ? `?${qs}` : ""}`,
  });
}

export async function listAllProjects(
  creds: ConductorCreds,
  opts?: { limit?: number },
): Promise<ConductorProject[]> {
  const limit = opts?.limit ?? 50;
  const projects: ConductorProject[] = [];
  let offset = 0;

  for (;;) {
    const page = await listProjects(creds, { limit, offset });
    projects.push(...page.data);

    if (!page.hasMore) {
      return projects;
    }

    const nextOffset = page.offset + page.data.length;
    offset = nextOffset > offset ? nextOffset : offset + limit;
  }
}

export interface CreateWorkspaceResponse {
  workspaceId: string;
  sessionId: string;
  deepLink: string;
}

export async function createWorkspace(
  creds: ConductorCreds,
  args: { projectId: string; name: string; agent: string; model?: string },
): Promise<CreateWorkspaceResponse> {
  return conductorFetch<CreateWorkspaceResponse>({
    creds,
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
  creds: ConductorCreds,
  workspaceId: string,
): Promise<WorkspaceStatusResponse> {
  return conductorFetch<WorkspaceStatusResponse>({
    creds,
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
  creds: ConductorCreds,
  sessionId: string,
  args: { message: string; messageId: string },
): Promise<SendMessageResponse> {
  return conductorFetch<SendMessageResponse>({
    creds,
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
  creds: ConductorCreds,
  sessionId: string,
): Promise<SessionStatusResponse> {
  return conductorFetch<SessionStatusResponse>({
    creds,
    method: "GET",
    path: `/v0/sessions/${sessionId}/status`,
  });
}

/**
 * A message in a session's conversation. `content` is untyped in the
 * Conductor OpenAPI schema (docs/CONDUCTOR-API.md) — parse it defensively.
 * The live API uses generated top-level ids and puts the client-supplied UUID
 * in the untyped content envelope (`id`/`turnId`/`userMessageId`). Pipeline
 * helpers therefore inspect both these legacy top-level fields and content.
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
  creds: ConductorCreds,
  sessionId: string,
): Promise<ListMessagesResponse> {
  return conductorFetch<ListMessagesResponse>({
    creds,
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
  creds: ConductorCreds,
  projectId: string,
): Promise<ListProjectWorkspacesResponse> {
  return conductorFetch<ListProjectWorkspacesResponse>({
    creds,
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
  creds: ConductorCreds,
  workspaceId: string,
): Promise<ListWorkspaceSessionsResponse> {
  return conductorFetch<ListWorkspaceSessionsResponse>({
    creds,
    method: "GET",
    path: `/v0/workspaces/${workspaceId}/sessions`,
  });
}

export interface ConductorMe {
  organizationId?: string;
  // SEAM: the API doesn't return an org name yet, but will soon — the field
  // is parsed leniently so names light up here the day it ships, with no
  // code change (see conductorOrgs.organizationName in schema.ts).
  organizationName?: string;
  authMethod?: string;
}

/**
 * Best-effort identity probe (`GET /me`, experimental stability). Returns
 * `undefined` on ANY failure — 404 from a deployment that doesn't serve it
 * yet, auth errors, network errors, unexpected body shape — because every
 * caller treats this as optional metadata (org dedupe at key-save time,
 * organizationName backfill), never as validation. Goes through
 * `conductorFetch` so the no-key-logging invariant holds.
 */
export async function getMe(
  creds: ConductorCreds,
): Promise<ConductorMe | undefined> {
  let body: unknown;
  try {
    body = await conductorFetch<unknown>({
      creds,
      method: "GET",
      path: "/me",
      // F12: a 404 from a deployment that doesn't serve /me yet (the
      // common case today) is expected, not an error — don't spam the
      // dashboard's live logs once per org per refresh.
      logErrors: false,
    });
  } catch {
    return undefined;
  }
  if (body === null || typeof body !== "object") return undefined;
  const record = body as Record<string, unknown>;
  const str = (key: string): string | undefined =>
    typeof record[key] === "string" ? (record[key] as string) : undefined;
  const organizationId = str("organizationId");
  // Server org name lands here when the API ships it (accept either
  // `organizationName` or a plain `name`).
  const organizationName = str("organizationName") ?? str("name");
  const authMethod = str("authMethod");
  // F11: match the doc comment — undefined when every expected field is
  // absent, rather than an all-undefined object that looks like a hit.
  if (
    organizationId === undefined &&
    organizationName === undefined &&
    authMethod === undefined
  ) {
    return undefined;
  }
  return { organizationId, organizationName, authMethod };
}

// ─── Environment resolution (probe, don't parse — KTD1) ─────────────────

export type ResolveConductorEnvironmentResult =
  | { ok: true; environment: ConductorEnvironment; projects: ConductorProject[] }
  | { ok: false; reason: "invalid" | "network"; message: string };

/**
 * Discovers which Conductor deployment a key belongs to by probing prod then
 * staging with the existing paginated `listAllProjects` helper — never a
 * `limit: 1` probe, since the successful probe's full project list doubles
 * as the `projectsCache` seed (KTD1). First success wins.
 *
 * Both hosts return an identical `401 {"code":"UNAUTHORIZED"}` for a
 * wrong-environment key (verified live), so `errorClass === "auth"` from
 * *both* attempts is the only thing that means "invalid key" (KTD4). Any
 * other non-network failure (workspaceSetup/unknown — e.g. a 429/400) is
 * NOT auth-from-both, so it must not be reported as "invalid" either: it's
 * surfaced as `reason: "network"` too, since we can't distinguish "this key
 * is bad" from "Conductor rejected the probe for some other reason" without
 * both hosts agreeing it's an auth failure. An outage — or any ambiguous
 * failure — must never masquerade as a bad key.
 */
export async function resolveConductorEnvironment(
  apiKey: string,
): Promise<ResolveConductorEnvironmentResult> {
  const environments: ConductorEnvironment[] = ["prod", "staging"];
  let allAuth = true;
  let sawNetwork = false;
  let lastMessage = "Conductor didn't accept that key.";

  for (const environment of environments) {
    try {
      const projects = await listAllProjects({ apiKey, environment });
      return { ok: true, environment, projects };
    } catch (err) {
      if (err instanceof ConductorApiError) {
        if (err.errorClass !== "auth") allAuth = false;
        if (err.errorClass === "network") sawNetwork = true;
        lastMessage = err.userMessage;
      } else {
        allAuth = false;
        sawNetwork = true;
        lastMessage = err instanceof Error ? err.message : String(err);
      }
    }
  }

  // "invalid" is only earned when BOTH hosts classified the failure as auth
  // (KTD4). Anything else — an explicit network failure, or a non-auth,
  // non-network failure like workspaceSetup (429/400) — is reported as
  // "network" so the caller never tells the user their key is wrong when we
  // don't actually know that.
  if (sawNetwork || !allAuth) {
    return { ok: false, reason: "network", message: lastMessage };
  }
  return { ok: false, reason: "invalid", message: lastMessage };
}
