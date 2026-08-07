/**
 * harvest-skill-actions — OpenClaw plugin
 *
 * Handles Discord button clicks on skill-harvester proposal cards posted via
 * `openclaw message send --presentation` (lib/notify.sh notify_harvest_skill_discord).
 *
 * Namespace: harvest
 * Payloads:  promote:<agent>:<skill>
 *            promote-shared:<agent>:<skill>
 *            reject:<agent>:<skill>
 *            view:<agent>:<skill>
 *
 * Clicks are default-deny gated to WARDEN_DISCORD_ALLOWED_USER_IDS (or plugin
 * config allowedUserIds). Agents live in these channels too.
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const OPENCLAW_BASE = process.env.WARDEN_OPENCLAW_HOME || join(homedir(), ".openclaw");
const WARDEN_HOME = process.env.WARDEN_HOME || join(homedir(), "session-warden");
const PENDING_BASE = join(OPENCLAW_BASE, "skills-pending");
const REJECTED_BASE = join(OPENCLAW_BASE, "skills-rejected");
const SECRETS = join(homedir(), ".config", "session-warden", "secrets.env");

const PAYLOAD_RE =
  /^(promote|promote-shared|reject|view):([a-z0-9][a-z0-9_-]{0,63}):([a-z0-9][a-z0-9-]{0,63})$/;

const inFlight = new Set();

function loadAllowedFromSecrets() {
  try {
    const text = readFileSync(SECRETS, "utf8");
    for (const line of text.split("\n")) {
      const m = line.match(/^WARDEN_DISCORD_ALLOWED_USER_IDS=(.*)$/);
      if (!m) continue;
      return m[1]
        .replace(/^["']|["']$/g, "")
        .split(/[\s,]+/)
        .filter(Boolean);
    }
  } catch {
    /* missing secrets file is fine */
  }
  return [];
}

function resolveAllowed() {
  const fromEnv = (process.env.WARDEN_DISCORD_ALLOWED_USER_IDS || "")
    .split(/[\s,]+/)
    .filter(Boolean);
  if (fromEnv.length > 0) return fromEnv;
  return loadAllowedFromSecrets();
}

function pendingDir(agent, skill) {
  const dir = resolve(PENDING_BASE, agent, skill);
  if (!dir.startsWith(PENDING_BASE + sep)) return null;
  return dir;
}

function tail(text, max) {
  if (!text) return "";
  return text.length <= max ? text : "…" + text.slice(-max);
}

async function runPromote(agent, skill, shared) {
  const args = [agent, skill];
  if (shared) args.push("--shared");
  try {
    const { stdout, stderr } = await execFileAsync(
      join(WARDEN_HOME, "bin", "promote-skill.sh"),
      args,
      { timeout: 60_000 },
    );
    return { ok: true, output: [stdout, stderr].filter(Boolean).join("\n").trim() };
  } catch (err) {
    const output = [err.stdout, err.stderr, err.message].filter(Boolean).join("\n").trim();
    return { ok: false, output };
  }
}

export default definePluginEntry({
  id: "harvest-skill-actions",
  name: "Harvest Skill Actions",
  register(api) {
    api.registerInteractiveHandler({
      channel: "discord",
      namespace: "harvest",
      async handler(ctx) {
        const payload = ctx?.interaction?.payload || "";
        const match = PAYLOAD_RE.exec(payload);
        if (!match) return { handled: false };

        const [, action, agent, skill] = match;
        const allowed = resolveAllowed();
        const senderId = ctx?.senderId ? String(ctx.senderId) : "";

        if (!allowed.includes(senderId)) {
          api.logger?.info?.(
            `harvest-skill-actions: refused ${action} ${agent}/${skill} from ${ctx?.senderUsername || "?"} (${senderId})`,
          );
          await ctx.respond.reply({
            text: "You are not on the harvest allowlist (`WARDEN_DISCORD_ALLOWED_USER_IDS`).",
            ephemeral: true,
          });
          return { handled: true };
        }

        const dir = pendingDir(agent, skill);
        if (!dir) return { handled: false };
        const draftPath = join(dir, "SKILL.md");
        const key = `${agent}/${skill}`;
        const who = ctx.senderUsername || senderId;

        if (action === "view") {
          let draft;
          try {
            draft = readFileSync(draftPath, "utf8");
          } catch {
            await ctx.respond.reply({
              text: `No pending draft for \`${key}\` — already promoted or rejected?`,
              ephemeral: true,
            });
            return { handled: true };
          }
          const body = draft.length > 1800 ? draft.slice(0, 1800) + "\n… (truncated)" : draft;
          await ctx.respond.reply({
            text: "```markdown\n" + body + "\n```",
            ephemeral: true,
          });
          return { handled: true };
        }

        if (inFlight.has(key)) {
          await ctx.respond.reply({
            text: `Already working on \`${key}\` — hold on.`,
            ephemeral: true,
          });
          return { handled: true };
        }
        inFlight.add(key);
        try {
          await ctx.respond.acknowledge();

          if (action === "reject") {
            if (!existsSync(draftPath)) {
              await ctx.respond.reply({
                text: `No pending draft for \`${key}\` — already promoted or rejected?`,
                ephemeral: true,
              });
              return { handled: true };
            }
            const ts = new Date().toISOString().replace(/[-:]/g, "").slice(0, 15);
            const dest = join(REJECTED_BASE, agent, `${skill}-${ts}`);
            mkdirSync(join(REJECTED_BASE, agent), { recursive: true });
            renameSync(dir, dest);
            api.logger?.info?.(`harvest-skill-actions: rejected ${key} → ${dest} (by ${who})`);
            await ctx.respond.clearComponents({
              text: `🧰 \`${key}\`\n🗑 rejected by <@${senderId}>`,
            });
            await ctx.respond.followUp({
              text: `Rejected — draft moved to \`${dest}\`.`,
              ephemeral: true,
            });
            return { handled: true };
          }

          const shared = action === "promote-shared";
          const { ok, output } = await runPromote(agent, skill, shared);
          if (ok) {
            api.logger?.info?.(
              `harvest-skill-actions: promoted ${key}${shared ? " (shared)" : ""} (by ${who})`,
            );
            await ctx.respond.clearComponents({
              text: `🧰 \`${key}\`\n✅ promoted${shared ? " fleet-wide" : ""} by <@${senderId}>`,
            });
            await ctx.respond.followUp({
              text: "```\n" + tail(output, 1800) + "\n```",
              ephemeral: true,
            });
          } else {
            api.logger?.error?.(`harvest-skill-actions: promote FAILED for ${key}: ${output}`);
            await ctx.respond.followUp({
              text: "Promote failed:\n```\n" + tail(output, 1800) + "\n```",
              ephemeral: true,
            });
          }
          return { handled: true };
        } catch (err) {
          api.logger?.error?.(
            `harvest-skill-actions: error on ${action} ${key}: ${err?.stack || err?.message || err}`,
          );
          try {
            await ctx.respond.followUp({
              text: "Something went wrong — check gateway logs for harvest-skill-actions.",
              ephemeral: true,
            });
          } catch {
            /* interaction expired */
          }
          return { handled: true };
        } finally {
          inFlight.delete(key);
        }
      },
    });
  },
});
