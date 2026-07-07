#!/usr/bin/env bash
# test-mcp-supervisor.sh — tests for bin/mcp-supervisor.sh

echo "  mcp-supervisor: no hardcoded personal paths"

# ─── No hardcoded personal paths ──────────────────────────

mcp_content=$(cat "$REAL_WARDEN_HOME/bin/mcp-supervisor.sh")
assert_not_contains "$mcp_content" "/home/" "no hardcoded home paths"

echo "  mcp-supervisor: has configurable server list"

# ─── Server list is configurable ─────────────────────────

assert_contains "$mcp_content" "MCP_SERVERS" "uses MCP_SERVERS variable"
assert_contains "$mcp_content" "mcp-servers.env" "references config file"
assert_contains "$mcp_content" "MCP_SERVER_BINARY" "server binary is configurable"

echo "  mcp-supervisor: usage help"

# ─── Shows usage on bad command ──────────────────────────

output=$(bash "$WARDEN_HOME/bin/mcp-supervisor.sh" badcommand 2>&1)
exit_code=$?
assert_eq "1" "$exit_code" "bad command exits 1"
assert_contains "$output" "Usage:" "shows usage on bad command"

echo "  mcp-supervisor: status command runs"

# ─── Status command doesn't crash ─────────────────────────

echo '{"mcp":{"servers":{}}}' > "$SANDBOX/openclaw/openclaw.json"

output=$(bash "$WARDEN_HOME/bin/mcp-supervisor.sh" status 2>&1)
assert_contains "$output" "notion" "status shows defined server"
