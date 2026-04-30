#!/usr/bin/env bash
# mcp-supervisor.sh — keep heavy MCP servers alive between session rotations
# Runs notion-mcp-server instances with HTTP transport so they survive CLI restarts.
# Usage: mcp-supervisor.sh start|stop|status|restart

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${WARDEN_HOME}/state/mcp-supervisor"
LOG_FILE="${STATE_DIR}/supervisor.log"
mkdir -p "$STATE_DIR"

log() {
  echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"
}

# Notion server definitions: name → port
# Tokens are read from openclaw.json at runtime (not hardcoded)
declare -A NOTION_PORTS=(
  [notion]=4001
  [notion-duet]=4002
  [notion-crossval]=4003
)

OPENCLAW_CONFIG="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}/openclaw.json"

get_notion_token() {
  local name="$1"
  jq -r --arg name "$name" '.mcp.servers[$name].env.OPENAPI_MCP_HEADERS // empty' "$OPENCLAW_CONFIG" 2>/dev/null
}

pid_file() {
  echo "${STATE_DIR}/${1}.pid"
}

is_running() {
  local name="$1"
  local pf
  pf=$(pid_file "$name")
  [ -f "$pf" ] && kill -0 "$(cat "$pf")" 2>/dev/null
}

start_server() {
  local name="$1"
  local port="${NOTION_PORTS[$name]}"
  local token
  token=$(get_notion_token "$name")
  local pf
  pf=$(pid_file "$name")

  if is_running "$name"; then
    echo "$name already running (pid $(cat "$pf"))"
    return 0
  fi

  if [ -z "$token" ]; then
    echo "ERROR: no token found for $name in $OPENCLAW_CONFIG"
    return 1
  fi

  OPENAPI_MCP_HEADERS="$token" nohup notion-mcp-server \
    --transport http \
    --port "$port" \
    --disable-auth \
    >> "${STATE_DIR}/${name}.log" 2>&1 &

  local pid=$!
  echo "$pid" > "$pf"

  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    echo "$name started on port $port (pid $pid)"
    log "START: $name on port $port (pid $pid)"
  else
    echo "ERROR: $name failed to start (check ${STATE_DIR}/${name}.log)"
    log "ERROR: $name failed to start"
    rm -f "$pf"
    return 1
  fi
}

stop_server() {
  local name="$1"
  local pf
  pf=$(pid_file "$name")

  if ! is_running "$name"; then
    echo "$name not running"
    rm -f "$pf"
    return 0
  fi

  local pid
  pid=$(cat "$pf")
  kill "$pid" 2>/dev/null
  sleep 1
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  rm -f "$pf"
  echo "$name stopped (was pid $pid)"
  log "STOP: $name (pid $pid)"
}

status_server() {
  local name="$1"
  local port="${NOTION_PORTS[$name]}"
  if is_running "$name"; then
    echo "$name: running on port $port (pid $(cat "$(pid_file "$name")"))"
  else
    echo "$name: stopped"
  fi
}

case "${1:-status}" in
  start)
    for name in "${!NOTION_PORTS[@]}"; do
      start_server "$name"
    done
    echo ""
    echo "Update agent-mcps.json: run sync-agent-mcps.sh to switch to persistent mode"
    ;;
  stop)
    for name in "${!NOTION_PORTS[@]}"; do
      stop_server "$name"
    done
    ;;
  restart)
    for name in "${!NOTION_PORTS[@]}"; do
      stop_server "$name"
      start_server "$name"
    done
    ;;
  status)
    for name in "${!NOTION_PORTS[@]}"; do
      status_server "$name"
    done
    ;;
  ensure)
    # Idempotent: start any servers that aren't running
    restarted=0
    for name in "${!NOTION_PORTS[@]}"; do
      if ! is_running "$name"; then
        start_server "$name"
        restarted=$((restarted + 1))
      fi
    done
    [ "$restarted" -gt 0 ] && log "ENSURE: restarted $restarted servers"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|ensure}"
    exit 1
    ;;
esac
