#!/usr/bin/env bash
# backfill-gbrain-links.sh — one-shot: wire the graph for pre-existing
# session-warden pages that were written before the typed/linked upgrade.
#
# For each `session-warden/*` page:
#   - ensure its agent page exists (agent/<name>)
#   - create the performed_by edge session -> agent
#   - create `mentions` edges for any [[wikilinks]] already in the body
#
# It does NOT rewrite page bodies (non-destructive); it only adds graph edges
# and anchor pages. Safe to re-run (links are idempotent upserts).
#
# Usage: bin/backfill-gbrain-links.sh [--limit N] [--dry-run]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/gbrain.sh"

LIMIT=500
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) shift ;;
  esac
done

gbrain_available || { echo "gbrain CLI not found"; exit 1; }

linked=0; anchored=0
# session-warden pages are slugged session-warden/<date>/<agent>-<id>
while IFS=$'\t' read -r slug rest; do
  # Only dated rotation pages: session-warden/<date>/<agent>-<hexid>.
  # live/ pages are linked at write-time by gbrain_ingest_session, so skip them.
  case "$slug" in
    session-warden/[0-9]*-[0-9]*-[0-9]*/*) ;;
    *) continue ;;
  esac
  # derive agent: leaf with the trailing "-<hexid>" stripped
  leaf=$(basename "$slug")
  agent=$(echo "$leaf" | sed -E 's/-[0-9a-f]{6,}$//')
  [ -z "$agent" ] && continue
  agent_slug="agent/$(gbrain_slugify "$agent")"

  if [ "$DRY" = "1" ]; then
    echo "would: $slug -> $agent_slug (performed_by)"
    continue
  fi

  gbrain_ensure_page "$agent_slug" "agent" "$agent" && anchored=$((anchored+1))
  _gb link "$slug" "$agent_slug" --type performed_by >/dev/null 2>&1 && linked=$((linked+1))

  # mentions edges from any wikilinks already in the body
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    gbrain_ensure_page "$target" "$(_gbrain_type_for "$target")" "$(basename "$target" | tr '-' ' ')"
    _gb link "$slug" "$target" --type mentions >/dev/null 2>&1
  done < <(gbrain get "$slug" 2>/dev/null | grep -oE '\[\[[a-zA-Z0-9/_-]+\]\]' \
            | sed -E 's/^\[\[//; s/\]\]$//' | sort -u | head -12)

  echo "linked $slug -> $agent_slug"
done < <(gbrain list --tag session-warden -n "$LIMIT" 2>/dev/null)

echo "done: $linked performed_by edges, agent anchors ensured ($anchored)"
