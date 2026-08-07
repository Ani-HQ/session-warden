'use strict';

/**
 * discord-harvest-actions — button handler for skill-harvest proposal cards.
 *
 * The harvester (bin/harvest-skills.sh) posts one Discord message per staged
 * SKILL.md draft with Promote / Promote shared / Reject / View draft buttons
 * (lib/notify.sh notify_harvest_skill_discord). This long-running service
 * connects to the Discord gateway (no public HTTPS endpoint needed) and turns
 * button clicks into the same actions the operator would run by hand:
 *
 *   promote        → bin/promote-skill.sh <agent> <skill>
 *   promote-shared → bin/promote-skill.sh <agent> <skill> --shared
 *   reject         → move the pending dir to ~/.openclaw/skills-rejected/
 *   view           → ephemeral reply with the SKILL.md draft
 *
 * Clicks are gated to WARDEN_DISCORD_ALLOWED_USER_IDS (comma/space separated
 * Discord user IDs). Empty allowlist = every click is refused — the fleet's
 * own agents live in these channels, so default-deny is deliberate.
 *
 * Run via bin/harvest-actions.sh (sources config/thresholds.env), deployed
 * with deploy/harvest-actions.service.
 */

const { execFile } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Client, Events, GatewayIntentBits, MessageFlags } = require('discord.js');

const TOKEN = process.env.WARDEN_DISCORD_BOT_TOKEN || process.env.DISCORD_BOT_TOKEN;
const WARDEN_HOME = process.env.WARDEN_HOME || path.join(os.homedir(), 'session-warden');
const OPENCLAW_BASE = process.env.WARDEN_OPENCLAW_HOME || path.join(os.homedir(), '.openclaw');
const PENDING_BASE = path.join(OPENCLAW_BASE, 'skills-pending');
const REJECTED_BASE = path.join(OPENCLAW_BASE, 'skills-rejected');
const ALLOWED_USERS = (process.env.WARDEN_DISCORD_ALLOWED_USER_IDS || '')
  .split(/[\s,]+/)
  .filter(Boolean);

if (!TOKEN) {
  console.error('WARDEN_DISCORD_BOT_TOKEN not set — exiting');
  process.exit(1);
}
if (ALLOWED_USERS.length === 0) {
  console.error(
    'WARDEN_DISCORD_ALLOWED_USER_IDS is empty — every button click will be refused. ' +
      'Set it in config/thresholds.env.'
  );
}

// Mirrors the slugs the harvester produces (slugify caps at 64 lowercase
// chars) and agent names from the roster. Anything else is treated as a
// forged custom_id and ignored.
const CUSTOM_ID = /^harvest:(promote|promote-shared|reject|view):([a-z0-9][a-z0-9_-]{0,63}):([a-z0-9][a-z0-9-]{0,63})$/;

// One action at a time per proposal — a double-click must not race
// promote-skill.sh against itself.
const inFlight = new Set();

function pendingDir(agent, skill) {
  const dir = path.resolve(PENDING_BASE, agent, skill);
  // Belt-and-braces: the regex already forbids path separators and dots.
  if (!dir.startsWith(PENDING_BASE + path.sep)) return null;
  return dir;
}

function runPromote(agent, skill, shared) {
  return new Promise((resolve) => {
    const args = [agent, skill];
    if (shared) args.push('--shared');
    execFile(
      path.join(WARDEN_HOME, 'bin', 'promote-skill.sh'),
      args,
      { timeout: 60_000 },
      (err, stdout, stderr) => {
        resolve({
          ok: !err,
          output: [stdout, stderr].filter(Boolean).join('\n').trim(),
        });
      }
    );
  });
}

function tail(text, max) {
  if (!text) return '';
  return text.length <= max ? text : '…' + text.slice(-max);
}

// Mark the proposal card as handled: append the outcome, drop the buttons.
async function settleCard(interaction, statusLine) {
  try {
    await interaction.message.edit({
      content: `${interaction.message.content}\n${statusLine}`,
      components: [],
    });
  } catch (err) {
    console.error(`could not edit proposal card: ${err.message}`);
  }
}

async function handleButton(interaction) {
  const match = CUSTOM_ID.exec(interaction.customId);
  if (!match) return;
  const [, action, agent, skill] = match;

  if (!ALLOWED_USERS.includes(interaction.user.id)) {
    console.log(`refused ${action} on ${agent}/${skill} from ${interaction.user.tag} (${interaction.user.id})`);
    await interaction.reply({
      content: 'You are not on the harvest allowlist (`WARDEN_DISCORD_ALLOWED_USER_IDS`).',
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  const dir = pendingDir(agent, skill);
  if (!dir) return;
  const draftPath = path.join(dir, 'SKILL.md');

  if (action === 'view') {
    let draft;
    try {
      draft = fs.readFileSync(draftPath, 'utf8');
    } catch {
      await interaction.reply({
        content: `No pending draft at \`${draftPath}\` — already promoted or rejected?`,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }
    const body = draft.length > 1800 ? draft.slice(0, 1800) + '\n… (truncated)' : draft;
    await interaction.reply({
      content: '```markdown\n' + body + '\n```',
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  const key = `${agent}/${skill}`;
  if (inFlight.has(key)) {
    await interaction.reply({
      content: `Already working on \`${key}\` — hold on.`,
      flags: MessageFlags.Ephemeral,
    });
    return;
  }
  inFlight.add(key);
  try {
    // promote-skill.sh can take a few seconds (GBrain ingestion) — ack now.
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    if (action === 'reject') {
      if (!fs.existsSync(draftPath)) {
        await interaction.editReply(`No pending draft for \`${key}\` — already promoted or rejected?`);
        return;
      }
      const ts = new Date().toISOString().replace(/[-:]/g, '').slice(0, 15);
      const dest = path.join(REJECTED_BASE, agent, `${skill}-${ts}`);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.renameSync(dir, dest);
      console.log(`rejected ${key} → ${dest} (by ${interaction.user.tag})`);
      await settleCard(interaction, `🗑 rejected by <@${interaction.user.id}>`);
      await interaction.editReply(`Rejected — draft moved to \`${dest}\`.`);
      return;
    }

    // promote | promote-shared
    const shared = action === 'promote-shared';
    const { ok, output } = await runPromote(agent, skill, shared);
    if (ok) {
      console.log(`promoted ${key}${shared ? ' (shared)' : ''} (by ${interaction.user.tag})`);
      await settleCard(
        interaction,
        `✅ promoted${shared ? ' fleet-wide' : ''} by <@${interaction.user.id}>`
      );
      await interaction.editReply('```\n' + tail(output, 1800) + '\n```');
    } else {
      console.error(`promote FAILED for ${key}: ${output}`);
      await interaction.editReply('Promote failed:\n```\n' + tail(output, 1800) + '\n```');
    }
  } catch (err) {
    console.error(`error handling ${action} on ${key}: ${err.stack || err.message}`);
    try {
      const msg = 'Something went wrong — check the harvest-actions logs.';
      if (interaction.deferred || interaction.replied) await interaction.editReply(msg);
      else await interaction.reply({ content: msg, flags: MessageFlags.Ephemeral });
    } catch {
      /* interaction expired — nothing left to do */
    }
  } finally {
    inFlight.delete(key);
  }
}

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

client.on('interactionCreate', (interaction) => {
  if (!interaction.isButton()) return;
  handleButton(interaction).catch((err) => console.error(err.stack || err.message));
});

client.once(Events.ClientReady, () => {
  console.log(
    `discord-harvest-actions ready as ${client.user.tag} ` +
      `(pending: ${PENDING_BASE}, allowlist: ${ALLOWED_USERS.length} user(s))`
  );
});

client.login(TOKEN).catch((err) => {
  console.error(`Discord login failed: ${err.message}`);
  process.exit(1);
});
