#!/usr/bin/env bash
# mcp-supervisor.sh — keep heavy MCP servers alive between session rotations
#
# MCP servers started via stdio transport restart every time the CLI session
# rotates, adding 10-15s of cold-start latency. This supervisor runs them as
# persistent HTTP processes that survive rotations.
#
# Usage: mcp-supervisor.sh {start|stop|restart|status|ensure}
#
# Configure your servers in config/mcp-servers.env or edit the defaults below.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
STATE_DIR="${WARDEN_HOME}/state/mcp-supervisor"
LOG_FILE="${STATE_DIR}/supervisor.log"
mkdir -p "$STATE_DIR"

log() {
  echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"
}

# ─── Server definitions ──────────────────────────────────
# Define your MCP servers here. Format: name=port
# Each server needs a matching entry in openclaw.json under mcp.servers
# with an env.OPENAPI_MCP_HEADERS field containing the auth token.
#
# Override by creating config/mcp-servers.env with the same format.
declare -A MCP_SERVERS=(
  [notion]=4001
  # Add more servers as needed:
  # [my-other-server]=4002
)

# Load user overrides if present
MCP_SERVERS_CONFIG="${WARDEN_HOME}/config/mcp-servers.env"
if [ -f "$MCP_SERVERS_CONFIG" ]; then
  # shellcheck source=/dev/null  # optional user-provided config
  source "$MCP_SERVERS_CONFIG"
fi

# ─── OpenClaw config ─────────────────────────────────────

OPENCLAW_CONFIG="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}/openclaw.json"

get_server_token() {
  local name="$1"
  jq -r --arg name "$name" '.mcp.servers[$name].env.OPENAPI_MCP_HEADERS // empty' "$OPENCLAW_CONFIG" 2>/dev/null
}

# MCP server binary — override via MCP_SERVER_BINARY env var
MCP_SERVER_BINARY="${MCP_SERVER_BINARY:-notion-mcp-server}"

# ─── Process management ──────────────────────────────────

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
  local port="${MCP_SERVERS[$name]}"
  local token
  token=$(get_server_token "$name")
  local pf
  pf=$(pid_file "$name")

  if is_running "$name"; then
    echo "$name already running (pid $(cat "$pf"))"
    return 0
  fi

  if [ -z "$token" ]; then
    echo "ERROR: no token found for '$name' in $OPENCLAW_CONFIG"
    echo "       Expected: .mcp.servers.$name.env.OPENAPI_MCP_HEADERS"
    return 1
  fi

  if ! command -v "$MCP_SERVER_BINARY" >/dev/null 2>&1; then
    echo "ERROR: $MCP_SERVER_BINARY not found. Install it or set MCP_SERVER_BINARY."
    return 1
  fi

  OPENAPI_MCP_HEADERS="$token" nohup "$MCP_SERVER_BINARY" \
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
  local port="${MCP_SERVERS[$name]}"
  if is_running "$name"; then
    echo "$name: running on port $port (pid $(cat "$(pid_file "$name")"))"
  else
    echo "$name: stopped"
  fi
}

# ─── Commands ─────────────────────────────────────────────

case "${1:-status}" in
  start)
    for name in "${!MCP_SERVERS[@]}"; do
      start_server "$name"
    done
    echo ""
    echo "Update your agent MCP configs to use HTTP transport on the above ports."
    ;;
  stop)
    for name in "${!MCP_SERVERS[@]}"; do
      stop_server "$name"
    done
    ;;
  restart)
    for name in "${!MCP_SERVERS[@]}"; do
      stop_server "$name"
      start_server "$name"
    done
    ;;
  status)
    for name in "${!MCP_SERVERS[@]}"; do
      status_server "$name"
    done
    ;;
  ensure)
    restarted=0
    for name in "${!MCP_SERVERS[@]}"; do
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
