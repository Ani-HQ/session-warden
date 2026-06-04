#!/usr/bin/env bash
# backfill-gbrain-links.sh — one-shot: wire the graph for pre-existing session
# pages (slug <prefix>/<date>/<agent>-<hexid>) written before the typed/linked
# upgrade. Works for the warden's own pages AND the gbrain-snapshotter's
# sessions/ pages (different tag + prefix, same shape).
#
# For each matching page:
#   - ensure its agent page exists (agent/<name>)
#   - create the performed_by edge session -> agent
#   - create `mentions` edges for any [[wikilinks]] already in the body
#
# It does NOT rewrite page bodies (non-destructive); it only adds graph edges
# and anchor pages. Safe to re-run (links are idempotent upserts).
#
# Usage:
#   bin/backfill-gbrain-links.sh [--tag T] [--prefix P/] [--limit N] [--dry-run]
#   # warden pages (default):    --tag session-warden --prefix session-warden/
#   # snapshotter sessions:      --tag session         --prefix sessions/

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/gbrain.sh"

LIMIT=500
DRY=0
TAG="session-warden"
PREFIX="session-warden/"
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) shift ;;
  esac
done

gbrain_available || { echo "gbrain CLI not found"; exit 1; }

linked=0; anchored=0
# pages are slugged <prefix><date>/<agent>-<hexid>
while IFS=$'\t' read -r slug rest; do
  # Only dated session pages under PREFIX. (warden live/ pages are linked at
  # write-time by gbrain_ingest_session, so the date-segment guard skips them.)
  case "$slug" in
    "${PREFIX}"[0-9]*-[0-9]*-[0-9]*/*) ;;
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
done < <(gbrain list --tag "$TAG" -n "$LIMIT" 2>/dev/null)

echo "done [tag=$TAG prefix=$PREFIX]: $linked performed_by edges, agent anchors ensured ($anchored)"
