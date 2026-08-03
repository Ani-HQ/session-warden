/**
 * fleet-rate-guard — OpenClaw plugin
 *
 * Cancels outbound operational rate-limit / model-fallback notices so Discord
 * and team chats stay clean. Detect / demote / restore / operator notify live
 * in session-warden (bin/rate-guard.sh + lib/rate-guard.py).
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const STATE_DIR = join(homedir(), ".openclaw", "fleet-rate-guard");
const EVENTS = join(STATE_DIR, "suppressed-events.jsonl");

const OPS_SHAPES = [
  /^↪️\s*Model Fallback/i,
  /Model Fallback cleared/i,
  /hit (a |your )?rate limit/i,
  /hitting a rate limit/i,
  /weekly limit/i,
  /switched things over to/i,
  /switched over to/i,
  /backup model failed/i,
  /I've switched/i,
  /I have switched/i,
  /give it another shot/i,
  /hit a snag while generating/i,
  /couldn't generate a response/i,
  /Agent couldn't generate a response/i,
  /Please try again in a moment or start/i,
  /start fresh with \/new/i,
  /openai isn't accepting your saved login/i,
  /re-authenticate/i,
];

function looksOperational(text) {
  if (!text || typeof text !== "string") return false;
  const t = text.trim();
  if (t.length < 8 || t.length > 1200) return false;
  // Don't cancel real ADHD-status work reports that happen to mention limits.
  if (/\n\*\*(done|blocked|next)\*\*/i.test(t) && t.length > 180) return false;
  return OPS_SHAPES.some((rx) => rx.test(t));
}

function note(event) {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    appendFileSync(
      EVENTS,
      JSON.stringify({ ts: new Date().toISOString(), ...event }) + "\n",
    );
  } catch {
    /* best-effort */
  }
}

function maybeCancel(content, meta) {
  if (!looksOperational(content)) return;
  note({
    kind: "suppressed_notice",
    channel: meta?.channel || meta?.surface || null,
    agent: meta?.agentId || null,
    preview: String(content).trim().slice(0, 180),
  });
  return {
    cancel: true,
    cancelReason: "fleet_rate_guard_ops_notice",
  };
}

export default definePluginEntry({
  id: "fleet-rate-guard",
  name: "Fleet Rate Guard",
  register(api) {
    api.on(
      "message_sending",
      async (event, ctx) => {
        const content = event?.content;
        return maybeCancel(content, {
          channel: event?.channel || ctx?.channelId || ctx?.channel,
          agentId: ctx?.agentId,
        });
      },
      { priority: 100 },
    );

    api.on(
      "reply_payload_sending",
      async (event, ctx) => {
        const payloads = event?.payloads || (event?.payload ? [event.payload] : []);
        for (const p of payloads) {
          const text = p?.text || p?.content || "";
          const decision = maybeCancel(text, {
            channel: event?.channel || ctx?.channelId,
            agentId: ctx?.agentId,
          });
          if (decision) return decision;
        }
      },
      { priority: 100 },
    );
  },
});
