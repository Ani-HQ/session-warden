/**
 * error-humanizer — OpenClaw plugin.
 *
 * Hooks `message_sending` and rewrites machine-shaped error replies into a
 * short, human line that keeps the actual cause, via Gemini Flash. Any
 * failure (no key, timeout, API error) delivers the original text untouched.
 *
 * Successor to session-warden's dist-patch of the same name: same behavior,
 * but built on the public plugin SDK so it survives OpenClaw upgrades.
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const DEFAULT_MODEL = "gemini-3-flash-preview";
const DEFAULT_TIMEOUT_MS = 8000;
const MAX_INPUT_CHARS = 4000;

// Only rewrite messages that look like machine error copy, not normal agent
// prose that happens to mention an error.
const ERROR_SHAPES = [
  /^⚠️/u,
  /^❌/u,
  /^Error:/i,
  /^\[error]/i,
  /Please try again, or use \/new/i,
  /Something went wrong while processing/i,
  /agent failed before reply/i,
  /rate.?limit(ed)?/i,
  /usage limit (?:reached|exceeded)/i,
  /overloaded_error|invalid_request_error|internal server error/i,
];

const SKIP_SHAPES = [
  /```/, // code blocks: probably a deliberate report, not raw error copy
  /\n[-*] .*\n[-*] /, // bulleted status updates
];

function looksLikeRawError(text) {
  if (!text || typeof text !== "string") return false;
  const t = text.trim();
  if (t.length < 8 || t.length > MAX_INPUT_CHARS) return false;
  if (SKIP_SHAPES.some((rx) => rx.test(t))) return false;
  return ERROR_SHAPES.some((rx) => rx.test(t));
}

function resolveApiKey(cfg) {
  if (cfg?.apiKey) return cfg.apiKey;
  try {
    const oc = JSON.parse(
      readFileSync(join(homedir(), ".openclaw", "openclaw.json"), "utf8"),
    );
    const key = oc?.models?.providers?.google?.apiKey;
    if (key) return key;
  } catch {
    /* fall through */
  }
  return process.env.GEMINI_API_KEY || null;
}

const rewriteCache = new Map(); // original -> { text, at }
const CACHE_TTL_MS = 60 * 60 * 1000;

async function humanize(original, cfg) {
  const cachedHit = rewriteCache.get(original);
  if (cachedHit && Date.now() - cachedHit.at < CACHE_TTL_MS) {
    return cachedHit.text;
  }
  const apiKey = resolveApiKey(cfg);
  if (!apiKey) return null;
  const model = cfg?.model || DEFAULT_MODEL;
  const timeoutMs = cfg?.timeoutMs || DEFAULT_TIMEOUT_MS;

  const prompt =
    "You rewrite raw error messages from an AI-agent platform into ONE short, " +
    "human, lightly witty chat reply (max 2 sentences). Rules: keep the " +
    "concrete cause visible in plain words; no jargon like 'gateway', " +
    "'harness' or HTTP codes unless essential; if the original tells the " +
    "user to retry or start fresh with /new, keep that instruction; never " +
    "invent details; output ONLY the rewritten reply.\n\nRaw error:\n" +
    original;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0.6,
            maxOutputTokens: 1024,
            thinkingConfig: { thinkingBudget: 0 },
          },
        }),
        signal: controller.signal,
      },
    );
    if (!res.ok) return null;
    const data = await res.json();
    const text = data?.candidates?.[0]?.content?.parts?.[0]?.text?.trim();
    if (!text || text.length < 4 || text.length > 600) return null;
    rewriteCache.set(original, { text, at: Date.now() });
    if (rewriteCache.size > 200) {
      const oldest = rewriteCache.keys().next().value;
      rewriteCache.delete(oldest);
    }
    return text;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export default definePluginEntry({
  id: "error-humanizer",
  name: "Error Humanizer",
  register(api) {
    const cfg = api?.pluginConfig ?? api?.config ?? null;
    api.on(
      "message_sending",
      async (event) => {
        const content = event?.content;
        if (!looksLikeRawError(content)) return;
        const rewritten = await humanize(content.trim(), cfg);
        if (!rewritten || rewritten === content) return;
        return { content: rewritten };
      },
      { priority: 10, timeoutMs: DEFAULT_TIMEOUT_MS + 2000 },
    );
  },
});
