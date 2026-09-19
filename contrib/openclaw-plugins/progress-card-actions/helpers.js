/**
 * Pure helpers for progress-card-actions. Kept off the OpenClaw import
 * so unit tests can load them without the plugin SDK.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const WARDEN_HOME = process.env.WARDEN_HOME || join(homedir(), "session-warden");
export const SECRETS = join(homedir(), ".config", "session-warden", "secrets.env");
export const PAYLOAD_RE = /^(stop|steer):([a-z0-9][a-z0-9_-]{0,31})$/;

export function parsePayload(payload) {
  const match = PAYLOAD_RE.exec(String(payload || "").trim());
  if (!match) return null;
  return { action: match[1], agent: match[2] };
}

export function loadAllowedFromSecrets() {
  try {
    const text = readFileSync(SECRETS, "utf8");
    const ids = [];
    for (const line of text.split("\n")) {
      const m = line.match(/^WARDEN_(?:PROGRESS|DISCORD|TELEGRAM)_ALLOWED_USER_IDS=(.*)$/);
      if (!m) continue;
      ids.push(
        ...m[1]
          .replace(/^["']|["']$/g, "")
          .split(/[\s,]+/)
          .filter(Boolean),
      );
    }
    return [...new Set(ids)];
  } catch {
    return [];
  }
}

export function resolveAllowed(pluginIds) {
  if (Array.isArray(pluginIds) && pluginIds.length > 0) {
    return pluginIds.map(String);
  }
  const fromEnv = [
    ...(process.env.WARDEN_PROGRESS_ALLOWED_USER_IDS || "").split(/[\s,]+/),
    ...(process.env.WARDEN_DISCORD_ALLOWED_USER_IDS || "").split(/[\s,]+/),
    ...(process.env.WARDEN_TELEGRAM_ALLOWED_USER_IDS || "").split(/[\s,]+/),
  ].filter(Boolean);
  if (fromEnv.length > 0) return [...new Set(fromEnv)];
  return loadAllowedFromSecrets();
}

export function isAllowed(senderId, allowed, authorizedSender) {
  if (authorizedSender) return true;
  const id = senderId ? String(senderId) : "";
  return id.length > 0 && allowed.includes(id);
}

export function latestProgressState(agent, home = WARDEN_HOME) {
  const dir = join(home, "state", "progress");
  let files;
  try {
    files = readdirSync(dir).filter(
      (name) => name.startsWith(`${agent}-`) && name.endsWith(".json"),
    );
  } catch {
    return null;
  }
  let best = null;
  let bestMtime = -1;
  for (const name of files) {
    const path = join(dir, name);
    let mtime = 0;
    try {
      mtime = statSync(path).mtimeMs;
    } catch {
      continue;
    }
    if (mtime >= bestMtime) {
      bestMtime = mtime;
      best = path;
    }
  }
  if (!best) return null;
  try {
    return JSON.parse(readFileSync(best, "utf8"));
  } catch {
    return null;
  }
}
