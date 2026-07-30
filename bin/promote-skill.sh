#!/usr/bin/env bash
# promote-skill.sh — promote a staged skill-harvester draft into a live skills dir.
#
# Counterpart to bin/harvest-skills.sh: the harvester STAGES SKILL.md drafts in
# ~/.openclaw/skills-pending/<agent>/<skill>/ for human review; this script
# promotes one. It:
#   1. moves the pending skill dir into the agent's live skills dir
#      (~/.openclaw/agents/<agent>/skills/<skill>/), or the fleet-wide shared
#      dir (~/.openclaw/skills/<skill>/) with --shared,
#   2. records the skill in GBrain as skills/<skill-name> with provenance
#      frontmatter per ops/gbrain-conventions (scope by team,
#      source: skill-harvester, trust: inferred).
#
# Usage: promote-skill.sh <agent> <skill-name> [--shared]
#   default:  install into the agent's own skills dir
#   --shared: install into ~/.openclaw/skills/ for the whole fleet

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/roster.sh"
source "${WARDEN_HOME}/lib/gbrain.sh"

LOG_FILE="${WARDEN_HOME}/state/harvest.log"
log() { echo "[$(date -Iseconds)] PROMOTE-SKILL: $*" >> "$LOG_FILE"; }

AGENT="${1:-}"
SKILL="${2:-}"
if [ -z "$AGENT" ] || [ -z "$SKILL" ]; then
  echo "usage: promote-skill.sh <agent> <skill-name> [--shared]" >&2
  exit 2
fi
SHARED=0
[ "${3:-}" = "--shared" ] && SHARED=1

OPENCLAW_BASE="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
pending_dir="${OPENCLAW_BASE}/skills-pending/${AGENT}/${SKILL}"

[ -f "${pending_dir}/SKILL.md" ] || {
  echo "no pending skill: ${pending_dir}/SKILL.md" >&2
  echo "staged proposals for ${AGENT}:" >&2
  ls -1 "${OPENCLAW_BASE}/skills-pending/${AGENT}" >&2 2>/dev/null || echo "  (none)" >&2
  exit 1
}

if [ "$SHARED" = "1" ]; then
  dest_dir="${OPENCLAW_BASE}/skills/${SKILL}"
else
  dest_dir="${OPENCLAW_BASE}/agents/${AGENT}/skills/${SKILL}"
  [ -d "${OPENCLAW_BASE}/agents/${AGENT}" ] || { echo "no such agent: ${AGENT}" >&2; exit 1; }
fi
if [ -e "$dest_dir" ]; then
  echo "destination already exists: ${dest_dir} — refusing to overwrite" >&2
  exit 1
fi

SCOPE="$(team_for "$AGENT")"

# 1. Move the pending skill into the live skills dir.
mkdir -p "$(dirname "$dest_dir")"
mv "$pending_dir" "$dest_dir" || { echo "move failed: ${pending_dir} → ${dest_dir}" >&2; exit 1; }
rmdir "${OPENCLAW_BASE}/skills-pending/${AGENT}" 2>/dev/null || true
echo "promoted ${SKILL} → ${dest_dir}/"
log "$AGENT: promoted '${SKILL}' → ${dest_dir} (shared: ${SHARED})"

# 2. Record provenance in GBrain (best-effort; conventions: scope per team,
#    source: skill-harvester, trust: inferred — see gbrain get ops/gbrain-conventions)
if gbrain_available; then
  slug="skills/${SKILL}"
  date_str=$(date +%Y-%m-%d)
  desc=$(awk '/^description:/ {sub(/^description:[[:space:]]*/, ""); print; exit}' "${dest_dir}/SKILL.md")
  audience="agent ${AGENT}"
  [ "$SHARED" = "1" ] && audience="all agents (shared)"
  printf -- '---\ntype: skill\ntitle: skill: %s\nscope: %s\nsource: skill-harvester\ntrust: inferred\nagent: %s\ntags:\n  - skill\n  - skill-harvester\n  - %s\n---\n\n**%s** — harvested from %s'\''s sessions by session-warden'\''s skill harvester (bin/harvest-skills.sh), promoted %s for %s.\n\n%s\n\nInstalled at: `%s/SKILL.md`\n' \
    "$SKILL" "$SCOPE" "$AGENT" "$AGENT" \
    "$SKILL" "$AGENT" "$date_str" "$audience" \
    "${desc:-'(no description in frontmatter)'}" "$dest_dir" | _gb_put "$slug" \
    && echo "  gbrain: put ${slug}" \
    || echo "  gbrain: put FAILED for ${slug} (non-fatal)"
  _gb link "$slug" "agent/${AGENT}" --type performed_by >/dev/null 2>&1
else
  echo "  gbrain CLI not found — skipped GBrain ingestion"
fi

echo "done: ${SKILL} live for ${AGENT}$([ "$SHARED" = "1" ] && echo ' (shared fleet-wide)')"
