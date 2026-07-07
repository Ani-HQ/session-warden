#!/usr/bin/env bash
# apply-lessons.sh — promote staged reflector lessons into an agent's memory.
#
# Counterpart to bin/reflect.sh: the reflector STAGES lessons in
# memory/pending-lessons-YYYY-MM-DD.md for human review; this script applies
# them. For each pending file it:
#   1. appends the bullets under "## Lessons learned" in the agent's MEMORY.md
#      (below the warden-injected context block),
#   2. records each lesson in GBrain as lessons/<agent>/YYYY-MM-DD-<n> with
#      provenance frontmatter per ops/gbrain-conventions (scope by team,
#      source: reflector, trust: inferred),
#   3. archives the pending file to memory/applied/.
#
# Usage: apply-lessons.sh <agent> [--all]
#   default: apply only the most recent pending-lessons file
#   --all:   apply every pending-lessons file for the agent

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/gbrain.sh"

LOG_FILE="${WARDEN_HOME}/state/reflect.log"
log() { echo "[$(date -Iseconds)] APPLY-LESSONS: $*" >> "$LOG_FILE"; }

AGENT="${1:-}"
if [ -z "$AGENT" ]; then
  echo "usage: apply-lessons.sh <agent> [--all]" >&2
  exit 2
fi
APPLY_ALL=0
[ "${2:-}" = "--all" ] && APPLY_ALL=1

OPENCLAW_BASE="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
agent_home="${OPENCLAW_BASE}/agents/${AGENT}"
mem_dir="${agent_home}/memory"
memfile="${agent_home}/MEMORY.md"

[ -d "$agent_home" ] || { echo "no such agent: ${AGENT} (${agent_home})" >&2; exit 1; }
[ -f "$memfile" ]    || { echo "no MEMORY.md for ${AGENT} (${memfile})" >&2; exit 1; }

# Keep in sync with bin/reflect.sh.
case "$AGENT" in
  ping|bloop|dash|isaac) SCOPE="work" ;;
  *)                     SCOPE="personal" ;;
esac

# Same section-aware insert as reflect.sh: append at the end of the
# "## Lessons learned" section that lives below the warden block.
append_to_lessons() {
  local bullets_file="$1"
  awk -v bf="$bullets_file" '
    function flush() {
      if (done) return
      while ((getline line < bf) > 0) print line
      close(bf); print ""; done=1
    }
    /<!-- SESSION-WARDEN-START -->/ {inwb=1}
    /<!-- SESSION-WARDEN-END -->/   {inwb=0; print; next}
    inwb {print; next}
    insec && /^## / {flush(); insec=0}
    /^## Lessons learned/ {insec=1}
    {print}
    END {if (insec) flush()}
  ' "$memfile" > "${memfile}.apply-tmp" && mv "${memfile}.apply-tmp" "$memfile"
}

pending_files=$(find "$mem_dir" -maxdepth 1 -name 'pending-lessons-*.md' 2>/dev/null | sort)
if [ -z "$pending_files" ]; then
  echo "no pending-lessons files for ${AGENT}"
  exit 0
fi
[ "$APPLY_ALL" = "0" ] && pending_files=$(echo "$pending_files" | tail -1)

applied_dir="${mem_dir}/applied"
mkdir -p "$applied_dir"

total=0
while IFS= read -r pf; do
  [ -f "$pf" ] || continue
  fdate=$(basename "$pf" | sed -E 's/^pending-lessons-([0-9]{4}-[0-9]{2}-[0-9]{2})\.md$/\1/')
  [ "$fdate" = "$(basename "$pf")" ] && fdate=$(date +%Y-%m-%d)

  bullets_tmp=$(mktemp)
  grep -E '^- ' "$pf" > "$bullets_tmp" || true
  n=$(grep -c . "$bullets_tmp" || true)
  if [ "$n" -eq 0 ]; then
    echo "${pf}: no bullets — archiving without applying"
    mv "$pf" "${applied_dir}/"
    rm -f "$bullets_tmp"
    continue
  fi

  # 1. Append into MEMORY.md
  if ! append_to_lessons "$bullets_tmp"; then
    echo "failed to update ${memfile} — aborting (pending file untouched)" >&2
    rm -f "$bullets_tmp"
    exit 1
  fi
  echo "applied ${n} lesson(s) from $(basename "$pf") to ${memfile}"
  log "$AGENT: applied ${n} lesson(s) from $(basename "$pf")"

  # 2. Record each lesson in GBrain (best-effort; conventions: scope per team,
  #    source: reflector, trust: inferred — see gbrain get ops/gbrain-conventions)
  if gbrain_available; then
    i=0
    while IFS= read -r b; do
      i=$((i + 1))
      slug="lessons/${AGENT}/${fdate}-${i}"
      printf -- '---\ntype: lesson\ntitle: %s lesson %s #%d\nscope: %s\nsource: reflector\ntrust: inferred\nagent: %s\ntags:\n  - lesson\n  - reflector\n  - %s\n---\n\n%s\n' \
        "$AGENT" "$fdate" "$i" "$SCOPE" "$AGENT" "$AGENT" "$b" | _gb_put "$slug" \
        && echo "  gbrain: put ${slug}" \
        || echo "  gbrain: put FAILED for ${slug} (non-fatal)"
      _gb link "$slug" "agent/${AGENT}" --type performed_by >/dev/null 2>&1
    done < "$bullets_tmp"
  else
    echo "  gbrain CLI not found — skipped GBrain ingestion"
  fi

  # 3. Archive the pending file
  mv "$pf" "${applied_dir}/"
  echo "archived $(basename "$pf") → ${applied_dir}/"
  rm -f "$bullets_tmp"
  total=$((total + n))
done < <(echo "$pending_files")

echo "done: ${total} lesson(s) applied for ${AGENT}"
