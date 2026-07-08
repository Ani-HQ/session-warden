#!/usr/bin/env bash
# burn-report.sh — "what ate my usage": subscription-window burn report
#
# Reads the burn ledgers (state/burn/<agent>.jsonl, written by lib/burn.sh on
# every scan) and reports tokens consumed per agent/channel inside the current
# subscription window. Counters in the ledger are cumulative per CLI session;
# a drop between consecutive records means the session rotated, so that pair
# contributes the new session's running total instead of a negative delta.
#
# Usage: session-warden burn [--window SECONDS] [--agent NAME] [--json]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

[ -f "${WARDEN_HOME}/config/thresholds.env" ] && source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/burn.sh"

window="${WARDEN_BURN_WINDOW_SECONDS:-18000}"
budget="${WARDEN_BURN_WINDOW_BUDGET:-0}"
json=0
agent_filter=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)   json=1; shift ;;
    --window) window="$2"; shift 2 ;;
    --agent)  agent_filter="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: session-warden burn [--window SECONDS] [--agent NAME] [--json]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

dir="${WARDEN_HOME}/state/burn"
now=$(date +%s)
since=$(( now - window ))

if [ ! -d "$dir" ] || ! ls "$dir"/*.jsonl >/dev/null 2>&1; then
  if [ "$json" -eq 1 ]; then echo "[]"; else
    echo "No burn ledger yet. Sampling starts with the next scan (WARDEN_BURN_ENABLED=1)."
  fi
  exit 0
fi

rows=""   # agent|channel|consumed|turns|tokens_now|last_ts
for ledger in "$dir"/*.jsonl; do
  [ -f "$ledger" ] || continue
  agent=$(basename "$ledger" .jsonl)
  [ "$agent" = "events" ] && continue
  [ -n "$agent_filter" ] && [ "$agent" != "$agent_filter" ] && continue
  while IFS='|' read -r channel consumed turns tokens_now last_ts; do
    [ -z "$channel" ] && continue
    rows="${rows}${agent}|${channel}|${consumed}|${turns}|${tokens_now}|${last_ts}
"
  done < <(burn_channel_report "$ledger" "$since")
done

if [ -z "$rows" ]; then
  if [ "$json" -eq 1 ]; then echo "[]"; else
    echo "No activity in the last $(( window / 60 )) minutes."
  fi
  exit 0
fi

if [ "$json" -eq 1 ]; then
  printf '%s' "$rows" | jq -Rn --argjson window "$window" --argjson budget "$budget" '
    [inputs | select(length > 0) | split("|") |
     {agent: .[0], channel: .[1], consumed: (.[2] | tonumber),
      turns: (.[3] | tonumber), tokens_now: (.[4] | tonumber),
      last_ts: (.[5] | tonumber)}] |
    {window_seconds: $window, budget: $budget, channels: sort_by(-.consumed),
     total_consumed: (map(.consumed) | add)}'
  exit 0
fi

# ─── table output ─────────────────────────────────────────
echo ""
echo "Burn report — last $(( window / 60 )) minutes"
echo "=============================================="
printf '%-14s %-34s %12s %7s %8s\n' "AGENT" "CHANNEL" "TOKENS" "TURNS" "AGO"
total=0
while IFS='|' read -r agent channel consumed turns tokens_now last_ts; do
  [ -z "$agent" ] && continue
  ago_min=$(( (now - last_ts) / 60 ))
  printf '%-14s %-34s %12s %7s %7sm\n' "$agent" "${channel:0:34}" "$consumed" "$turns" "$ago_min"
  total=$(( total + consumed ))
done < <(printf '%s' "$rows" | sort -t'|' -k3,3nr)
echo "----------------------------------------------"
printf '%-49s %12s\n' "TOTAL" "$total"

if [ "$budget" -gt 0 ] 2>/dev/null; then
  pct=$(( total * 100 / budget ))
  printf '%-49s %11s%%\n' "WINDOW BUDGET USED (${budget} tokens)" "$pct"
fi
echo ""
