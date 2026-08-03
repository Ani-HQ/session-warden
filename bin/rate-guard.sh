#!/usr/bin/env bash
# rate-guard.sh — demote rate-limited model providers fleet-wide until reset.
#
# Usage:
#   rate-guard.sh            # detect / demote / restore once
#   rate-guard.sh --once     # same
#   rate-guard.sh --status   # JSON status
#
# Wired by deploy/rate-guard.timer (every ~2 min).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

[ -f "${WARDEN_HOME}/config/thresholds.env" ] && source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/notify.sh"

# Kill switch
[ "${WARDEN_RATE_GUARD:-1}" = "1" ] || exit 0

STATE_DIR="${WARDEN_HOME}/state/rate-guard"
mkdir -p "$STATE_DIR"
LOG="${STATE_DIR}/rate-guard.log"
PY="${WARDEN_HOME}/lib/rate-guard.py"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >/dev/null
}

pretty_provider() {
  case "$1" in
    claude) echo "Claude Max" ;;
    openai) echo "ChatGPT / Codex" ;;
    google) echo "Gemini" ;;
    *) echo "$1" ;;
  esac
}

MODE="once"
case "${1:-}" in
  --status) MODE="status" ;;
  --once|"") MODE="once" ;;
  -h|--help)
    sed -n '2,12p' "$0"
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 1
    ;;
esac

if [ ! -f "$PY" ]; then
  echo "ERROR: missing $PY" >&2
  exit 1
fi

RESULT="$(python3 "$PY" --"$MODE" 2>>"$LOG")" || {
  log "rate-guard.py failed"
  exit 1
}

ACTION="$(printf '%s' "$RESULT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("action",""))' 2>/dev/null || true)"

if [ "$MODE" = "status" ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

log "result=$RESULT"

case "$ACTION" in
  demoted)
    provider="$(printf '%s' "$RESULT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("provider",""))')"
    detail="$(printf '%s' "$RESULT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("detail",""))')"
    until="$(printf '%s' "$RESULT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("resetsAtLabel","unknown"))')"
    pretty="$(pretty_provider "$provider")"
    notify_rate_limit "$pretty" "$detail" "$until"
    log "notified demotion provider=$provider until=$until"
    ;;
  restored)
    provider="$(printf '%s' "$RESULT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("provider",""))')"
    pretty="$(pretty_provider "$provider")"
    notify_rate_limit_cleared "$pretty"
    log "notified restore provider=$provider"
    ;;
  noop|status|"")
    ;;
  *)
    log "unknown action=$ACTION"
    ;;
esac

exit 0
