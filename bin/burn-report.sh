#!/usr/bin/env bash
# burn-report.sh — "what ate my usage": subscription-window burn report
#
# Reads the burn ledgers (state/burn/<agent>.jsonl, written by lib/burn.sh on
# every scan) and reports tokens consumed per agent/channel inside the current
# subscription window. Counters in the ledger are cumulative per CLI session;
# a drop between consecutive records means the session rotated, so that pair
# contributes the new session's running total instead of a negative delta.
#
# Usage: session-warden burn [--window SECONDS] [--agent NAME] [--solo] [--json]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

# shellcheck source=/dev/null  # Optional deployment-local configuration.
[ -f "${WARDEN_HOME}/config/thresholds.env" ] && source "${WARDEN_HOME}/config/thresholds.env"
# shellcheck source=/dev/null  # Resolved from WARDEN_HOME at runtime.
source "${WARDEN_HOME}/lib/burn.sh"

window="${WARDEN_BURN_WINDOW_SECONDS:-18000}"
budget="${WARDEN_BURN_WINDOW_BUDGET:-0}"
plan_budget="${WARDEN_BURN_PLAN_BUDGET:-0}"
case "$plan_budget" in
  ''|*[!0-9]*) plan_budget=0 ;;
esac
json=0
agent_filter=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)   json=1; shift ;;
    --window) window="$2"; shift 2 ;;
    --agent)  agent_filter="$2"; shift 2 ;;
    --solo)   agent_filter="solo"; shift ;;
    -h|--help)
      echo "Usage: session-warden burn [--window SECONDS] [--agent NAME] [--solo] [--json]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

dir="${WARDEN_HOME}/state/burn"
now=$(date +%s)
since=$(( now - window ))

has_ledgers=0
if [ -d "$dir" ]; then
  for ledger in "$dir"/*.jsonl; do
    [ -f "$ledger" ] || continue
    has_ledgers=1
    break
  done
fi

if [ "$has_ledgers" -eq 0 ]; then
  if [ "$json" -eq 1 ]; then echo "[]"; else
    echo "No burn ledger yet. Sampling starts with the next scan (WARDEN_BURN_ENABLED=1)."
  fi
  exit 0
fi

all_rows=""   # agent|channel|consumed|turns|tokens_now|last_ts
for ledger in "$dir"/*.jsonl; do
  [ -f "$ledger" ] || continue
  agent=$(basename "$ledger" .jsonl)
  [ "$agent" = "events" ] && continue
  while IFS='|' read -r channel consumed turns tokens_now last_ts; do
    [ -z "$channel" ] && continue
    all_rows="${all_rows}${agent}|${channel}|${consumed}|${turns}|${tokens_now}|${last_ts}
"
  done < <(burn_channel_report "$ledger" "$since")
done

rows="$all_rows"
if [ -n "$agent_filter" ]; then
  rows=$(printf '%s' "$all_rows" | awk -F'|' -v agent_filter="$agent_filter" '$1 == agent_filter')
  [ -n "$rows" ] && rows="${rows}
"
fi

if [ -z "$rows" ]; then
  if [ "$json" -eq 1 ]; then echo "[]"; else
    echo "No activity in the last $(( window / 60 )) minutes."
  fi
  exit 0
fi

if [ "$json" -eq 1 ]; then
  jq -Rn \
    --arg rows "$rows" \
    --arg all_rows "$all_rows" \
    --argjson window "$window" \
    --argjson budget "$budget" \
    --argjson plan_budget "$plan_budget" '
    def parse_rows($s):
      [$s | split("\n")[] | select(length > 0) | split("|") |
       {agent: .[0], channel: .[1], consumed: (.[2] | tonumber),
        turns: (.[3] | tonumber), tokens_now: (.[4] | tonumber),
        last_ts: (.[5] | tonumber)}];
    parse_rows($rows) as $channels |
    parse_rows($all_rows) as $all_channels |
    ($channels | map(.consumed) | add // 0) as $total |
    ($channels | map(select(.agent != "solo") | .consumed) | add // 0) as $agent_total |
    ($all_channels | map(.consumed) | add // 0) as $plan_total |
    {window_seconds: $window, budget: $budget, plan_budget: $plan_budget,
     budget_pct: (if $budget > 0 then (($agent_total * 100 / $budget) | floor) else 0 end),
     plan_pct: (if $plan_budget > 0 then (($plan_total * 100 / $plan_budget) | floor) else 0 end),
     channels: ($channels | sort_by(-.consumed)), total_consumed: $total}'
  exit 0
fi

# ─── table output ─────────────────────────────────────────
echo ""
echo "Burn report — last $(( window / 60 )) minutes"
echo "=============================================="
printf '%-14s %-34s %12s %7s %8s\n' "AGENT" "CHANNEL" "TOKENS" "TURNS" "AGO"
total=0
agent_total=0
while IFS='|' read -r agent channel consumed turns _tokens_now last_ts; do
  [ -z "$agent" ] && continue
  ago_min=$(( (now - last_ts) / 60 ))
  printf '%-14s %-34s %12s %7s %7sm\n' "$agent" "${channel:0:34}" "$consumed" "$turns" "$ago_min"
  total=$(( total + consumed ))
  [ "$agent" != "solo" ] && agent_total=$(( agent_total + consumed ))
done < <(printf '%s' "$rows" | sort -t'|' -k3,3nr)
plan_total=$(printf '%s' "$all_rows" | awk -F'|' '{s += $3} END {print s + 0}')
echo "----------------------------------------------"
printf '%-49s %12s\n' "TOTAL" "$total"

if [ "$budget" -gt 0 ] 2>/dev/null; then
  pct=$(( agent_total * 100 / budget ))
  printf '%-49s %11s%%\n' "WINDOW BUDGET USED (${budget} tokens)" "$pct"
fi
if [ "$plan_budget" -gt 0 ] 2>/dev/null; then
  plan_pct=$(( plan_total * 100 / plan_budget ))
  printf '%-49s %11s%%\n' "PLAN WINDOW USED (${plan_budget} tokens)" "$plan_pct"
fi
echo ""
