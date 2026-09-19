/**
 * progress-card-actions — OpenClaw plugin
 *
 * Handles Stop / Steer on long-task progress cards posted via
 * `bin/progress-card.sh` (`openclaw message send --presentation`).
 *
 * Namespace: progress
 * Payloads:  stop:<agent>
 *            steer:<agent>
 *
 * Telegram returns submitText so Stop rides the control lane.
 * Discord also calls chat.abort for the agent's latest progress session.
 *
 * Clicks are default-deny unless the sender is an OpenClaw-authorized
 * operator or listed in WARDEN_PROGRESS_ALLOWED_USER_IDS /
 * WARDEN_DISCORD_ALLOWED_USER_IDS (or plugin config allowedUserIds).
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  isAllowed,
  latestProgressState,
  parsePayload,
  resolveAllowed,
} from "./helpers.js";

const execFileAsync = promisify(execFile);

function openclawBin() {
  if (process.env.OPENCLAW_BIN) return process.env.OPENCLAW_BIN;
  return "openclaw";
}

export async function abortAgentRun(agent, sessionKey) {
  if (!sessionKey) return { ok: false, output: "no session key" };
  try {
    const { stdout, stderr } = await execFileAsync(
      openclawBin(),
      [
        "gateway",
        "call",
        "chat.abort",
        "--params",
        JSON.stringify({ sessionKey, agentId: agent }),
      ],
      { timeout: 15_000 },
    );
    return { ok: true, output: [stdout, stderr].filter(Boolean).join("\n").trim() };
  } catch (err) {
    const output = [err.stdout, err.stderr, err.message].filter(Boolean).join("\n").trim();
    return { ok: false, output };
  }
}

function cardText(ctx, extra) {
  const prior =
    ctx?.callback?.messageText ||
    ctx?.interaction?.messageText ||
    "";
  const line = extra.replace(/^\n+|\n+$/g, "");
  if (!prior.trim()) return line;
  if (prior.includes(line)) return prior;
  return `${prior.trim()}\n${line}`;
}

async function deny(ctx, channel) {
  const text = "You are not allowed to Stop or Steer this run.";
  if (channel === "discord") {
    await ctx.respond.reply({ text, ephemeral: true });
  } else {
    await ctx.respond.reply({ text });
  }
}

async function finishStop(ctx, channel, who) {
  const text = cardText(ctx, `stopped by ${who}`);
  if (channel === "discord") {
    await ctx.respond.clearComponents({ text });
  } else {
    try {
      await ctx.respond.editMessage({ text });
      await ctx.respond.clearButtons();
    } catch {
      await ctx.respond.reply({ text });
    }
  }
}

async function promptSteer(ctx, channel) {
  const text = "Reply with the correction. Mid-run messages steer this turn.";
  if (channel === "discord") {
    await ctx.respond.reply({ text, ephemeral: true });
  } else {
    await ctx.respond.reply({ text });
  }
}

function registerChannel(api, channel, pluginCfg) {
  api.registerInteractiveHandler({
    channel,
    namespace: "progress",
    async handler(ctx) {
      const payload = ctx?.interaction?.payload || ctx?.callback?.payload || "";
      const parsed = parsePayload(payload);
      if (!parsed) return { handled: false };

      const { action, agent } = parsed;
      const allowed = resolveAllowed(pluginCfg?.allowedUserIds);
      const senderId = ctx?.senderId ? String(ctx.senderId) : "";
      const authorized = Boolean(ctx?.auth?.isAuthorizedSender);
      const who = ctx.senderUsername || senderId || "someone";

      if (!isAllowed(senderId, allowed, authorized)) {
        api.logger?.info?.(
          `progress-card-actions: refused ${action} ${agent} from ${who} (${senderId})`,
        );
        await deny(ctx, channel);
        return { handled: true };
      }

      if (action === "steer") {
        if (channel === "discord") {
          try {
            await ctx.respond.acknowledge();
          } catch {
            /* already acknowledged */
          }
        }
        await promptSteer(ctx, channel);
        api.logger?.info?.(`progress-card-actions: steer prompt ${agent} (by ${who})`);
        return { handled: true };
      }

      if (channel === "discord") {
        try {
          await ctx.respond.acknowledge();
        } catch {
          /* already acknowledged */
        }
      }

      const state = latestProgressState(agent);
      const sessionKey = state?.channel || "";
      const result = await abortAgentRun(agent, sessionKey);
      if (result.ok) {
        api.logger?.info?.(`progress-card-actions: aborted ${agent} ${sessionKey} (by ${who})`);
      } else {
        api.logger?.error?.(
          `progress-card-actions: abort failed ${agent}: ${result.output}`,
        );
      }
      await finishStop(ctx, channel, who);

      if (channel === "telegram") {
        return { handled: true, submitText: "stop" };
      }
      return { handled: true };
    },
  });
}

export default definePluginEntry({
  id: "progress-card-actions",
  name: "Progress Card Actions",
  register(api) {
    const cfg = api.config || {};
    registerChannel(api, "discord", cfg);
    registerChannel(api, "telegram", cfg);
  },
});
