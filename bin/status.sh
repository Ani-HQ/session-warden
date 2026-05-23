#!/usr/bin/env bash
# status.sh — show current session health across all agents

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"

OUTPUT_JSON=0
FILTER_AGENT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)  OUTPUT_JSON=1; shift ;;
    --agent) FILTER_AGENT="$2"; shift 2 ;;
    *)       echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────

format_tokens() {
  local t="$1"
  if [ "$t" -ge 1000000 ]; then
    printf "%.1fM" "$(echo "scale=1; $t / 1000000" | bc 2>/dev/null || echo "$t")"
  elif [ "$t" -ge 1000 ]; then
    printf "%.0fK" "$(echo "scale=0; $t / 1000" | bc 2>/dev/null || echo "$t")"
  else
    echo "$t"
  fi
}

health_level() {
  local tokens="$1" turns="$2" compactions="$3" status="$4"
  local max_t="${WARDEN_MAX_TOKENS:-2000000}"
  local max_turns="${WARDEN_MAX_TURNS:-500}"
  local max_c="${WARDEN_MAX_COMPACTIONS:-10}"

  if [ "$status" = "failed" ]; then
    echo "CRITICAL"
    return
  fi

  local warn=0
  if [ "$tokens" -gt $((max_t * 80 / 100)) ]; then warn=1; fi
  if [ "$turns" -gt $((max_turns * 80 / 100)) ]; then warn=1; fi
  if [ "$compactions" -gt $((max_c * 80 / 100)) ]; then warn=1; fi

  if [ "$warn" -eq 1 ]; then
    echo "WARNING"
  else
    echo "HEALTHY"
  fi
}

time_ago() {
  local ts_ms="$1"
  [ "$ts_ms" = "0" ] || [ "$ts_ms" = "null" ] && { echo "never"; return; }

  local now_ms
  now_ms=$(date +%s)000
  local diff_s=$(( (now_ms - ts_ms) / 1000 ))

  if [ "$diff_s" -lt 60 ]; then
    echo "${diff_s}s ago"
  elif [ "$diff_s" -lt 3600 ]; then
    echo "$((diff_s / 60))m ago"
  elif [ "$diff_s" -lt 86400 ]; then
    echo "$((diff_s / 3600))h ago"
  else
    echo "$((diff_s / 86400))d ago"
  fi
}

# ─── Collect data ─────────────────────────────────────────

total=0
healthy=0
warning=0
critical=0
json_agents="["
first_agent=true

for sjson in "${WARDEN_OPENCLAW_HOME}"/agents/*/sessions/sessions.json; do
  [ -f "$sjson" ] || continue
  agent=$(echo "$sjson" | sed -E 's|.*/agents/([^/]+)/sessions/.*|\1|')

  if [ -n "$FILTER_AGENT" ] && [ "$agent" != "$FILTER_AGENT" ]; then
    continue
  fi

  if [ "$OUTPUT_JSON" -eq 0 ]; then
    echo "Agent: $agent"
  fi

  json_sessions="["
  first_session=true
  agent_has_sessions=0

  while IFS=$'\t' read -r channel_key tokens turns compactions status updated_at cli_sid; do
    [ -z "$channel_key" ] && continue
    agent_has_sessions=1
    total=$((total + 1))

    tokens="${tokens:-0}"
    turns="${turns:-0}"
    compactions="${compactions:-0}"
    status="${status:-active}"
    updated_at="${updated_at:-0}"

    level=$(health_level "$tokens" "$turns" "$compactions" "$status")
    case "$level" in
      HEALTHY)  healthy=$((healthy + 1)) ;;
      WARNING)  warning=$((warning + 1)) ;;
      CRITICAL) critical=$((critical + 1)) ;;
    esac

    if [ "$OUTPUT_JSON" -eq 0 ]; then
      local_tokens=$(format_tokens "$tokens")
      local_updated=$(time_ago "$updated_at")

      printf "  %-36s %-9s tokens: %-8s turns: %-5s compactions: %-3s (%s)\n" \
        "$channel_key" "$level" "$local_tokens" "$turns" "$compactions" "$local_updated"
    fi

    if [ "$OUTPUT_JSON" -eq 1 ]; then
      [ "$first_session" = true ] || json_sessions+=","
      first_session=false
      json_sessions+="{\"channel\":\"$channel_key\",\"status\":\"$status\",\"health\":\"$level\",\"tokens\":$tokens,\"turns\":$turns,\"compactions\":$compactions,\"updatedAt\":$updated_at,\"cliSessionId\":\"${cli_sid:-}\"}"
    fi

  done < <(jq -r '
    to_entries[] |
    [
      .key,
      (.value.totalTokens // 0 | tostring),
      (.value.numTurns // 0 | tostring),
      (.value.compactionCount // 0 | tostring),
      (.value.status // "active"),
      (.value.updatedAt // 0 | tostring),
      (.value.cliSessionIds["claude-cli"] // "")
    ] | @tsv
  ' "$sjson" 2>/dev/null)

  json_sessions+="]"

  if [ "$agent_has_sessions" -eq 0 ] && [ "$OUTPUT_JSON" -eq 0 ]; then
    echo "  (no active sessions)"
  fi

  if [ "$OUTPUT_JSON" -eq 0 ]; then
    echo ""
  fi

  if [ "$OUTPUT_JSON" -eq 1 ]; then
    [ "$first_agent" = true ] || json_agents+=","
    first_agent=false
    json_agents+="{\"agent\":\"$agent\",\"sessions\":$json_sessions}"
  fi
done

json_agents+="]"

# ─── Last rotation info ──────────────────────────────────

last_rotation=""
if [ -f "${WARDEN_HOME}/state/scan.log" ]; then
  last_rotation=$(grep "ROTATE complete" "${WARDEN_HOME}/state/scan.log" 2>/dev/null | tail -1)
fi

last_scan=""
if [ -f "${WARDEN_HOME}/state/scan.log" ]; then
  last_scan=$(tail -1 "${WARDEN_HOME}/state/scan.log" 2>/dev/null | grep -oP '^\[[^\]]+\]' | tr -d '[]')
fi

# ─── Output ───────────────────────────────────────────────

if [ "$OUTPUT_JSON" -eq 1 ]; then
  cat <<JSONEOF
{"agents":$json_agents,"summary":{"total":$total,"healthy":$healthy,"warning":$warning,"critical":$critical},"lastScan":"${last_scan:-unknown}","lastRotation":"${last_rotation:-none}"}
JSONEOF
else
  echo "Summary: $total sessions ($healthy healthy, $warning warning, $critical critical)"

  if [ -n "$last_scan" ]; then
    echo "Last scan: $last_scan"
  fi

  if [ -n "$last_rotation" ]; then
    echo "Last rotation: $last_rotation"
  fi
fi
