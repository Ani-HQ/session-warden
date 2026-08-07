#!/usr/bin/env bash
# harvest-skills.sh — weekly per-agent skill mining (the "skill harvester").
#
# The reflector distills LESSONS (one-line rules); nothing captures repeated
# WORKFLOWS. This job closes that loop weekly: for each agent it gathers the
# week's material (rotation summaries, daily memory notes, applied lessons),
# lists the agent's existing skills so nothing is re-proposed, and asks a
# strong model to identify workflows the agent performed 2+ times that no
# existing skill covers — emitting a complete SKILL.md draft for each (max 2
# per agent per run).
#
# Proposals are STAGED under ~/.openclaw/skills-pending/<agent>/<skill>/SKILL.md
# — never written into a live skills dir. The intended flow is: review a
# draft, edit it if needed, then promote it with
#   bin/promote-skill.sh <agent> <skill-name> [--shared]
#
# Run weekly via systemd timer (see deploy/harvest.{service,timer}), Sunday
# early morning, after the nightly reflector so the week's lessons are staged.
#
# Usage: harvest-skills.sh [--agent <name>] [--dry-run]
#   --agent    harvest a single agent instead of WARDEN_HARVEST_AGENTS
#   --dry-run  print proposed SKILL.md drafts to stdout; write/notify nothing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/roster.sh"
source "${WARDEN_HOME}/lib/portable.sh"   # stat_mtime / stat_size
[ -f "${WARDEN_HOME}/lib/notify.sh" ] && source "${WARDEN_HOME}/lib/notify.sh"

# Defaults (override in config/thresholds.env)
HARVEST_AGENTS="${WARDEN_HARVEST_AGENTS:-$(roster_agents)}"
HARVEST_MODEL="${WARDEN_HARVEST_MODEL:-claude-sonnet-4-6}"
WINDOW_DAYS="${WARDEN_HARVEST_WINDOW_DAYS:-7}"
WINDOW_MINUTES=$((WINDOW_DAYS * 1440))

LOG_FILE="${WARDEN_HOME}/state/harvest.log"
mkdir -p "${WARDEN_HOME}/state"
log() { echo "[$(date -Iseconds)] HARVEST: $*" >> "$LOG_FILE"; }

# --- Flags ------------------------------------------------------------------
ONLY_AGENT=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   ONLY_AGENT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "usage: harvest-skills.sh [--agent <name>] [--dry-run]" >&2; exit 2 ;;
  esac
done
[ -n "$ONLY_AGENT" ] && HARVEST_AGENTS="$ONLY_AGENT"

LOCKFILE="${WARDEN_HOME}/state/harvest.lock"
exec 196>"$LOCKFILE"
if ! flock -n 196; then
  log "another harvest is running — skipping"
  exit 0
fi

CLAUDE_BASE="${WARDEN_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
OPENCLAW_BASE="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
PENDING_BASE="${OPENCLAW_BASE}/skills-pending"

# Slugify a model-proposed skill name into a safe directory name.
slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-64
}

log "run starting (agents: ${HARVEST_AGENTS}, model: ${HARVEST_MODEL}, window: ${WINDOW_DAYS}d, dry_run: ${DRY_RUN})"

notify_lines=""
total_skills=0
harvested=0

for agent in $HARVEST_AGENTS; do
  agent_home="${OPENCLAW_BASE}/agents/${agent}"
  if [ ! -d "$agent_home" ]; then
    log "$agent: no agent dir — SKIP"
    continue
  fi

  # --- 1. Gather the week's material ---------------------------------------
  material_file="${WARDEN_HOME}/state/harvest-${agent}.material"
  : > "$material_file"

  # a) rotation summaries written by the warden
  while IFS= read -r summ; do
    [ -f "$summ" ] || continue
    {
      printf '\n===== rotation summary: %s =====\n' "$(basename "$summ")"
      head -c 8000 "$summ"
    } >> "$material_file"
  done < <(find "${CLAUDE_BASE}/-home-$(whoami)--openclaw-agents-${agent}/memory" -maxdepth 1 -name 'session_*.md' -mmin -"$WINDOW_MINUTES" 2>/dev/null | sort)

  # b) the agent's own daily notes (incl. staged pending-lessons — evidence
  #    of behavior is exactly what we're mining)
  while IFS= read -r note; do
    [ -f "$note" ] || continue
    {
      printf '\n===== daily note: %s =====\n' "$(basename "$note")"
      head -c 8000 "$note"
    } >> "$material_file"
  done < <(find "${agent_home}/memory" -maxdepth 1 -name '*.md' -mmin -"$WINDOW_MINUTES" 2>/dev/null | sort)

  # c) lessons already applied this week (memory/applied/)
  while IFS= read -r lesson; do
    [ -f "$lesson" ] || continue
    {
      printf '\n===== applied lessons: %s =====\n' "$(basename "$lesson")"
      head -c 8000 "$lesson"
    } >> "$material_file"
  done < <(find "${agent_home}/memory/applied" -maxdepth 1 -name '*.md' -mmin -"$WINDOW_MINUTES" 2>/dev/null | sort)

  material_bytes=$(stat_size "$material_file")
  if [ "$material_bytes" -lt 200 ]; then
    log "$agent: no material in last ${WINDOW_DAYS}d (${material_bytes}B) — SKIP"
    rm -f "$material_file"
    continue
  fi

  # Cap total material so one chatty agent can't blow the context/cost budget.
  head -c 60000 "$material_file" > "${material_file}.cap" && mv "${material_file}.cap" "$material_file"
  log "$agent: gathered ${material_bytes}B of material (capped at 60000B)"

  # Existing skill names (per-agent + shared + already-staged proposals) so
  # the model never proposes a duplicate.
  existing_skills=$( {
    ls -1 "${agent_home}/skills" 2>/dev/null
    ls -1 "${OPENCLAW_BASE}/skills" 2>/dev/null
    ls -1 "${PENDING_BASE}/${agent}" 2>/dev/null
  } | sort -u)

  # --- 2. Mine (one strong-model call per agent) ---------------------------
  proposals=$(cat "$material_file" | timeout 240 claude -p --model "$HARVEST_MODEL" "You are a skill-mining system reviewing one week of work by an AI agent named '${agent}' (rotation summaries, daily notes, and applied lessons — piped in below).

The agent's EXISTING skills — anything covered by one of these must NOT be proposed:
${existing_skills:-(none)}

Identify workflows the agent performed at least TWICE this week that are NOT covered by an existing skill. A workflow is a repeatable multi-step procedure (e.g. 'draft a personalized outreach reply', 'compile the weekly ads report') — not a one-off task, not a personality trait, not a single command. Propose at most 2, best first.

For each qualifying workflow, output a complete SKILL.md draft in EXACTLY this format:

=== SKILL: <skill-name> ===
---
name: <skill-name>
description: <one sentence on what it does, then trigger conditions: 'Use when ...'>
---
# <Human Title>

<one-paragraph overview>

## Steps
1. <concrete, ordered steps distilled from how the agent actually did it>

## Known failure modes
- <mistakes or dead ends the agent actually hit this week, and how to avoid them>

## Anti-patterns
- <things the agent (or its operator) explicitly corrected or rejected>
=== END SKILL ===

Hard rules:
- <skill-name> must be lowercase-hyphenated (e.g. warm-prospect-reply).
- Ground every step, failure mode, and anti-pattern in the material below — invent nothing.
- Evidence bar: the workflow must visibly occur 2+ times in the material. One occurrence = not a skill.
- If nothing clears the bar (2+ occurrences AND not covered by an existing skill AND general enough to reuse), output exactly: NO_SKILLS

Output ONLY the skill blocks (or NO_SKILLS). No preamble, no commentary, no code fences." 2>/dev/null)
  rm -f "$material_file"

  if [ -z "$proposals" ]; then
    log "$agent: mining returned empty (LLM failure?) — skipping agent"
    continue
  fi
  if echo "$proposals" | grep -q '^[[:space:]]*NO_SKILLS[[:space:]]*$'; then
    log "$agent: NO_SKILLS"
    [ "$DRY_RUN" = "1" ] && echo "${agent}: NO_SKILLS"
    continue
  fi

  # --- 3. Parse the skill blocks (cap at 2 per agent per run) ---------------
  parse_dir="${WARDEN_HOME}/state/harvest-${agent}.proposals"
  rm -rf "$parse_dir" && mkdir -p "$parse_dir"
  echo "$proposals" | awk -v dir="$parse_dir" '
    /^=== SKILL: / {
      n++
      name=$0; sub(/^=== SKILL: */, "", name); sub(/ *=+ *$/, "", name)
      cap = (n <= 2)
      if (cap) { print name > (dir "/" n ".name"); file = dir "/" n ".skill" }
      next
    }
    /^=== END SKILL/ {cap=0; next}
    /^```/ {next}
    cap {print > file}
  '

  n_staged=0
  agent_names=""
  for i in 1 2; do
    [ -f "${parse_dir}/${i}.name" ] || continue
    raw_name=$(head -1 "${parse_dir}/${i}.name")
    skill_name=$(slugify "$raw_name")
    if [ -z "$skill_name" ] || [ ! -s "${parse_dir}/${i}.skill" ]; then
      log "$agent: proposal ${i} unparseable (name: '${raw_name}') — dropped"
      continue
    fi
    # Belt-and-braces duplicate guard (the model was told, but enforce anyway).
    if printf '%s\n' "$existing_skills" | grep -qx "$skill_name"; then
      log "$agent: proposal '${skill_name}' duplicates an existing skill — dropped"
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      echo "=== ${agent}: proposed skill '${skill_name}' ==="
      cat "${parse_dir}/${i}.skill"
      echo ""
    else
      stage_dir="${PENDING_BASE}/${agent}/${skill_name}"
      mkdir -p "$stage_dir"
      cp "${parse_dir}/${i}.skill" "${stage_dir}/SKILL.md"
      log "$agent: staged '${skill_name}' → ${stage_dir}/SKILL.md"
      # Interactive Discord card (Promote / Reject / View buttons) — no-op
      # unless WARDEN_DISCORD_BOT_TOKEN + WARDEN_HARVEST_DISCORD_CHANNEL_ID
      # are set. The Telegram digest below is unaffected.
      if type notify_harvest_skill_discord &>/dev/null; then
        skill_desc=$(awk '/^description:/ {sub(/^description:[[:space:]]*/, ""); print; exit}' "${stage_dir}/SKILL.md")
        notify_harvest_skill_discord "$agent" "$skill_name" "$skill_desc" \
          || log "$agent: discord proposal card FAILED for '${skill_name}' (non-fatal)"
      fi
    fi
    agent_names="${agent_names}${agent_names:+, }\`${skill_name}\`"
    n_staged=$((n_staged + 1))
  done
  rm -rf "$parse_dir"

  if [ "$n_staged" -eq 0 ]; then
    log "$agent: mining output had no usable skill blocks"
    continue
  fi
  log "$agent: ${n_staged} skill proposal(s) this run"
  notify_lines="${notify_lines}• \`${agent}\`: ${n_staged} skill(s) proposed — ${agent_names}"$'\n'
  total_skills=$((total_skills + n_staged))
  harvested=$((harvested + 1))
done

# --- 4. Notify (one digest per run) ------------------------------------------
if [ "$DRY_RUN" != "1" ] && [ -n "$notify_lines" ]; then
  if type notify_harvester &>/dev/null; then
    summary="${notify_lines}
Total: ${total_skills} skill draft(s) across ${harvested} agent(s).
Staged under: \`~/.openclaw/skills-pending/<agent>/<skill>/SKILL.md\`
Review the draft, then promote:
\`~/session-warden/bin/promote-skill.sh <agent> <skill-name>\` (or \`--shared\` for the fleet)"
    if notify_harvester "$summary"; then
      log "telegram notification sent"
    else
      log "telegram notification FAILED (non-fatal)"
    fi
  fi
fi

log "run complete: ${total_skills} skill draft(s) across ${harvested} agent(s)"
flock -u 196
