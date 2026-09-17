#!/usr/bin/env bash
# progress-card.sh — agent-facing long-task progress card
#
# Usage:
#   progress-card.sh start|update|done|blocked \
#     --agent dash \
#     --channel agent:dash:discord:channel:123 \
#     --title "Dahej tier-1" \
#     --done 23 --total 57 \
#     --now "Flow-Tech Valves — looking up decision-maker" \
#     [--last "wrote row 23"] \
#     [--sheet-url URL] \
#     [--discord-target channel:123] \
#     [--telegram-target CHAT_ID] \
#     [--force]
#
# Post once, edit in place. Throttle: every WARDEN_PROGRESS_EVERY_N items
# or WARDEN_PROGRESS_THROTTLE_SECONDS, whichever comes first. start / done /
# blocked always send.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

# Optional — knobs only. Missing file is fine in tests.
# shellcheck source=/dev/null
[ -f "${WARDEN_HOME}/config/thresholds.env" ] && source "${WARDEN_HOME}/config/thresholds.env"
# shellcheck source=../lib/progress-card.sh
source "${WARDEN_HOME}/lib/progress-card.sh"

usage() {
  cat <<'EOF'
Usage: progress-card.sh start|update|done|blocked --agent NAME --channel KEY [options]

Options:
  --title TEXT
  --done N
  --total N
  --now TEXT
  --last TEXT
  --sheet-url URL
  --discord-target channel:ID
  --telegram-target CHAT_ID
  --force
EOF
}

progress_card_cli() {
  local action="${1:-}"
  shift || true
  case "$action" in
    start|update|done|blocked) ;;
    -h|--help|help|"") usage; [ -n "$action" ] && [ "$action" != "help" ] && [ "$action" != "-h" ] && [ "$action" != "--help" ] && return 2; return 0 ;;
    *) echo "progress-card: unknown action: $action" >&2; usage >&2; return 2 ;;
  esac

  unset PROGRESS_CARD_AGENT PROGRESS_CARD_CHANNEL PROGRESS_CARD_TITLE
  unset PROGRESS_CARD_DONE PROGRESS_CARD_TOTAL PROGRESS_CARD_NOW
  unset PROGRESS_CARD_LAST PROGRESS_CARD_SHEET_URL
  unset PROGRESS_CARD_DISCORD_TARGET PROGRESS_CARD_TELEGRAM_TARGET
  PROGRESS_CARD_FORCE="${PROGRESS_CARD_FORCE:-0}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) PROGRESS_CARD_AGENT="$2"; shift 2 ;;
      --channel) PROGRESS_CARD_CHANNEL="$2"; shift 2 ;;
      --title) PROGRESS_CARD_TITLE="$2"; shift 2 ;;
      --done) PROGRESS_CARD_DONE="$2"; shift 2 ;;
      --total) PROGRESS_CARD_TOTAL="$2"; shift 2 ;;
      --now) PROGRESS_CARD_NOW="$2"; shift 2 ;;
      --last) PROGRESS_CARD_LAST="$2"; shift 2 ;;
      --sheet-url) PROGRESS_CARD_SHEET_URL="$2"; shift 2 ;;
      --discord-target) PROGRESS_CARD_DISCORD_TARGET="$2"; shift 2 ;;
      --telegram-target) PROGRESS_CARD_TELEGRAM_TARGET="$2"; shift 2 ;;
      --force) PROGRESS_CARD_FORCE=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "progress-card: unknown option: $1" >&2; usage >&2; return 2 ;;
    esac
  done

  export PROGRESS_CARD_AGENT PROGRESS_CARD_CHANNEL PROGRESS_CARD_TITLE
  export PROGRESS_CARD_DONE PROGRESS_CARD_TOTAL PROGRESS_CARD_NOW
  export PROGRESS_CARD_LAST PROGRESS_CARD_SHEET_URL
  export PROGRESS_CARD_DISCORD_TARGET PROGRESS_CARD_TELEGRAM_TARGET
  export PROGRESS_CARD_FORCE
  progress_card_run "$action"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  progress_card_cli "$@"
fi
