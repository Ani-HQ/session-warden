#!/usr/bin/env bash
# cache-report.sh — per-agent prompt-cache hit rate (the missing gauge)
#
# Anthropic serves a repeated prompt prefix from cache at ~10% of the price of
# fresh input tokens, but only on an exact prefix match. A mutation above the
# cache point (model swap, MCP tool-list change, injected timestamp) silently
# reverts every call to full price. Nothing errors; only the hit rate moves.
#
# Reads the usage counters OpenClaw persists in each agent's session JSONLs
# (via lib/cache-report.py) and reports cacheRead / (input+cacheRead+cacheWrite)
# per agent. --check evaluates thresholds and alerts on Telegram, one throttled
# alert per agent, and snapshots the run for drop detection next time.
#
# Usage: session-warden cache [--days N] [--agent NAME] [--json] [--check]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

# shellcheck source=/dev/null  # Optional deployment-local configuration.
[ -f "${WARDEN_HOME}/config/thresholds.env" ] && source "${WARDEN_HOME}/config/thresholds.env"
# shellcheck source=/dev/null  # Resolved from WARDEN_HOME at runtime.
source "${WARDEN_HOME}/lib/notify.sh"

OPENCLAW_BASE="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
ROSTER_FILE="${WARDEN_FLEET_ROSTER:-${WARDEN_HOME}/config/fleet-roster.tsv}"
REPORTER="${WARDEN_HOME}/lib/cache-report.py"
STATE_DIR="${WARDEN_HOME}/state/cache"

days="${WARDEN_CACHE_WINDOW_DAYS:-7}"
warn_pct="${WARDEN_CACHE_WARN_PCT:-70}"
drop_pct="${WARDEN_CACHE_DROP_PCT:-20}"
min_tokens="${WARDEN_CACHE_MIN_TOKENS:-200000}"
cooldown="${WARDEN_CACHE_ALERT_COOLDOWN_SECONDS:-86400}"

json=0 check=0 agent_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json)  json=1; shift ;;
    --check) check=1; shift ;;
    --days)  days="$2"; shift 2 ;;
    --agent) agent_filter="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: session-warden cache [--days N] [--agent NAME] [--json] [--check]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "${WARDEN_CACHE_ENABLED:-1}" != "1" ]; then
  [ "$json" -eq 1 ] && echo '{}' || echo "cache report disabled (WARDEN_CACHE_ENABLED=0)"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "cache-report: python3 not found" >&2; exit 1; }
[ -f "$REPORTER" ] || { echo "cache-report: missing $REPORTER" >&2; exit 1; }

# Roster agents (production fleet) when a roster exists; else auto-discover.
agents=""
if [ -n "$agent_filter" ]; then
  agents="$agent_filter"
elif [ -f "$ROSTER_FILE" ]; then
  agents=$(grep -v '^#' "$ROSTER_FILE" | cut -f1 | grep -v '^$' | paste -sd, -)
fi

report=$(python3 "$REPORTER" "${OPENCLAW_BASE}/agents" --days "$days" \
  ${agents:+--agents "$agents"} --json) || { echo "cache-report: reporter failed" >&2; exit 1; }

if [ "$json" -eq 1 ]; then
  printf '%s\n' "$report"
  exit 0
fi

# ─── check mode: thresholds + throttled Telegram alerts ───
if [ "$check" -eq 1 ]; then
  mkdir -p "$STATE_DIR"
  prev="$STATE_DIR/last-check.json"
  now=$(date +%s)
  alerts=""

  while IFS=$'\t' read -r agent hit prompt_tokens; do
    [ -z "$agent" ] && continue
    [ "$hit" = "null" ] && continue
    [ "$prompt_tokens" -lt "$min_tokens" ] 2>/dev/null && continue
    hit_int="${hit%.*}"

    reason=""
    if [ "$hit_int" -lt "$warn_pct" ] 2>/dev/null; then
      reason="hit rate ${hit}% is below the ${warn_pct}% floor"
    fi
    if [ -f "$prev" ]; then
      prev_hit=$(jq -r --arg a "$agent" \
        '.agents[]? | select(.agent==$a) | .hit_pct // empty' "$prev" 2>/dev/null)
      if [ -n "$prev_hit" ] && [ "${prev_hit%.*}" -ge 0 ] 2>/dev/null; then
        delta=$(( ${prev_hit%.*} - hit_int ))
        if [ "$delta" -ge "$drop_pct" ]; then
          reason="${reason:+$reason; }dropped ${delta} points since last check (${prev_hit}% → ${hit}%)"
        fi
      fi
    fi
    [ -z "$reason" ] && continue

    stamp="$STATE_DIR/alert-${agent}.stamp"
    if [ -f "$stamp" ]; then
      last_alert=$(cat "$stamp" 2>/dev/null || echo 0)
      [ $(( now - last_alert )) -lt "$cooldown" ] && continue
    fi
    echo "$now" > "$stamp"
    alerts="${alerts}${agent}: ${reason} (${prompt_tokens} prompt tokens/${days}d)
"
  done < <(jq -r '.agents[] |
      [.agent, (.hit_pct // "null" | tostring),
       ((.input + .cache_read + .cache_write) | tostring)] | @tsv' \
      <<< "$report")

  if [ -n "$alerts" ]; then
    notify_alert "prompt-cache hit rate" "$alerts
A drop means a prefix mutation is defeating the cache: check for model swaps, MCP tool-list changes, or anything dynamic injected above the cache point."
  fi
  printf '%s\n' "$report" > "$prev"
  [ -n "$alerts" ] && printf 'ALERT\n%s' "$alerts" || echo "OK"
  exit 0
fi

# ─── default: human table ─────────────────────────────────
printf '%-9s %8s %12s %12s %10s %8s %7s\n' \
  AGENT HIT% CACHE_READ CACHE_WRITE INPUT OUTPUT CALLS
jq -r '.agents[] | [.agent, (.hit_pct // "-" | tostring),
    (.cache_read|tostring), (.cache_write|tostring),
    (.input|tostring), (.output|tostring), (.calls|tostring)] | @tsv' \
  <<< "$report" \
| while IFS=$'\t' read -r a h cr cw i o c; do
    printf '%-9s %8s %12s %12s %10s %8s %7s\n' "$a" "$h" "$cr" "$cw" "$i" "$o" "$c"
  done
fleet=$(jq -r '"fleet hit rate: \(.fleet.hit_pct // "-")% over \(.window_days)d (read \(.fleet.cache_read) / wrote \(.fleet.cache_write) / uncached \(.fleet.input))"' <<< "$report")
echo "─"
echo "$fleet"
