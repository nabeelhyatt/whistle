// Generates a short, human-readable workspace title from a captured idea via
// a single Claude Haiku call. Mirrors conductorClient.ts's raw-`fetch` idiom
// (no SDK dependency in the Convex default runtime) and its "never die
// silently" spirit — but inverted: this helper is purely cosmetic (it only
// improves `buildWorkspaceName`'s output in pipeline.ts), so it must NEVER
// throw and NEVER stall the pipeline. Every failure mode (missing key,
// non-200, network error, timeout) collapses to `null`, and callers fall
// back to the heuristic name.

const ANTHROPIC_MESSAGES_URL = "https://api.anthropic.com/v1/messages";
const TITLE_MODEL = "claude-haiku-4-5";
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_INPUT_CHARS = 2_000;
const MAX_TITLE_CHARS = 60;

interface AnthropicMessagesResponse {
  content?: Array<{ type?: string; text?: string }>;
}

function truncate(text: string, maxChars: number): string {
  return text.length > maxChars ? text.slice(0, maxChars) : text;
}

function buildPrompt(args: {
  transcript: string;
  notes: string;
  projectName: string;
}): string {
  const transcript = truncate(args.transcript, MAX_INPUT_CHARS);
  const notes = truncate(args.notes, MAX_INPUT_CHARS);
  return (
    "Generate a title for a captured product idea. Reply with ONLY the " +
    "title: 3-5 words, starting with the noun or feature the idea concerns " +
    "(e.g. 'Capture panel redesign', 'Onboarding mic permission fix'). No " +
    "quotes or trailing punctuation. " +
    `Project: ${args.projectName}. Transcript: ${transcript}. Notes: ${notes}.`
  );
}

/**
 * Strips a raw model reply down to a usable title: first line only, quotes
 * removed, whitespace collapsed, capped at ~60 chars. Returns `null` if
 * nothing usable remains.
 */
export function sanitizeTitle(raw: string): string | null {
  const firstLine = raw.split("\n")[0] ?? "";
  const unquoted = firstLine.trim().replace(/^["'“”‘’]+|["'“”‘’]+$/g, "");
  const collapsed = unquoted.replace(/\s+/g, " ").trim();
  if (collapsed.length === 0) return null;
  return collapsed.length > MAX_TITLE_CHARS
    ? collapsed.slice(0, MAX_TITLE_CHARS).trim()
    : collapsed;
}

/**
 * Calls Claude Haiku to produce a short workspace title for a captured idea.
 * Never throws: returns `null` on a missing API key, a non-200 response, a
 * network error, or a timeout, so `pipeline.ts` can always fall back to the
 * heuristic name in `buildWorkspaceName` without the pipeline ever failing
 * or stalling because of this call.
 */
export async function generateWorkspaceTitle(args: {
  transcript: string;
  notes: string;
  projectName: string;
}): Promise<string | null> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (apiKey === undefined || apiKey.length === 0) return null;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const res = await fetch(ANTHROPIC_MESSAGES_URL, {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: TITLE_MODEL,
        max_tokens: 256,
        messages: [{ role: "user", content: buildPrompt(args) }],
      }),
      signal: controller.signal,
    });

    if (!res.ok) {
      console.error(
        `titleGenerator: Anthropic API error — status=${res.status}`,
      );
      return null;
    }

    const body = (await res.json()) as AnthropicMessagesResponse;
    const text = body.content?.find((block) => typeof block.text === "string")
      ?.text;
    if (text === undefined) return null;

    return sanitizeTitle(text);
  } catch (err) {
    // Covers network errors and the AbortController timeout — never let a
    // cosmetic title-generation failure surface as a pipeline error.
    const message = err instanceof Error ? err.message : String(err);
    console.error(`titleGenerator: request failed — ${message}`);
    return null;
  } finally {
    clearTimeout(timeout);
  }
}
