#!/usr/bin/env bash
# test-status.sh — tests for bin/status.sh

echo "  status: healthy sessions display"

# ─── Healthy sessions ────────────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-status-001"}
  }
}'

output=$("$WARDEN_HOME/bin/status.sh" 2>/dev/null)
assert_contains "$output" "test-agent" "status shows agent name"
assert_contains "$output" "HEALTHY" "status shows HEALTHY for normal session"
assert_contains "$output" "discord-general" "status shows channel name"
assert_contains "$output" "Summary:" "status shows summary line"

echo "  status: warning threshold"

# ─── Warning (near threshold) ────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 1800000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-status-warn"}
  }
}'

output=$("$WARDEN_HOME/bin/status.sh" 2>/dev/null)
assert_contains "$output" "WARNING" "status shows WARNING for near-threshold session"

echo "  status: critical (failed)"

# ─── Critical (failed status) ────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "failed",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-status-crit"}
  }
}'

output=$("$WARDEN_HOME/bin/status.sh" 2>/dev/null)
assert_contains "$output" "CRITICAL" "status shows CRITICAL for failed session"

echo "  status: multiple agents"

# ─── Multiple agents display ─────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-status-multi-a"}
  }
}'

create_sessions_json "second-agent" '{
  "telegram-dm": {
    "totalTokens": 200000,
    "numTurns": 100,
    "compactionCount": 2,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-status-multi-b"}
  }
}'

output=$("$WARDEN_HOME/bin/status.sh" 2>/dev/null)
assert_contains "$output" "test-agent" "multi-agent: first agent shown"
assert_contains "$output" "second-agent" "multi-agent: second agent shown"
assert_contains "$output" "2 sessions" "multi-agent: correct total count"

echo "  status: agent filter"

# ─── Agent filter ─────────────────────────────────────────

output=$("$WARDEN_HOME/bin/status.sh" --agent test-agent 2>/dev/null)
assert_contains "$output" "test-agent" "agent filter: shows filtered agent"
assert_not_contains "$output" "second-agent" "agent filter: hides other agents"

echo "  status: JSON output"

# ─── JSON output mode ────────────────────────────────────

json_output=$("$WARDEN_HOME/bin/status.sh" --json 2>/dev/null)
assert_contains "$json_output" '"agents"' "JSON output has agents key"
assert_contains "$json_output" '"summary"' "JSON output has summary key"
assert_contains "$json_output" '"healthy"' "JSON output has healthy count"

# Validate it's parseable JSON
echo "$json_output" | jq . >/dev/null 2>&1
exit_code=$?
assert_eq "0" "$exit_code" "JSON output is valid JSON"

echo "  status: no sessions"

# ─── No active sessions ──────────────────────────────────

create_sessions_json "test-agent" '{}'
rm -f "$SANDBOX/openclaw/agents/second-agent/sessions/sessions.json"

output=$("$WARDEN_HOME/bin/status.sh" 2>/dev/null)
assert_contains "$output" "0 sessions" "no sessions: shows 0 count"

echo "  status: empty agent directory"

# ─── No agents at all ────────────────────────────────────

rm -rf "$SANDBOX/openclaw/agents/"*

output=$("$WARDEN_HOME/bin/status.sh" 2>/dev/null)
assert_contains "$output" "0 sessions" "empty: shows 0 sessions"
