#!/usr/bin/env bash
# test-detect.sh — tests for lib/detect.sh

source "$WARDEN_HOME/lib/detect.sh"

echo "  detect: agent_from_sessions_path"

# ─── agent_from_sessions_path ─────────────────────────────

result=$(agent_from_sessions_path "/home/user/.openclaw/agents/my-agent/sessions/sessions.json")
assert_eq "my-agent" "$result" "extract agent name from standard path"

result=$(agent_from_sessions_path "/opt/openclaw/agents/dash/sessions/sessions.json")
assert_eq "dash" "$result" "extract agent from non-home path"

echo "  detect: healthy sessions"

# ─── Healthy session (no problems) ────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-healthy-001"}
  }
}'

# Create a recent JSONL so zombie detection doesn't trigger
create_mock_jsonl "test-agent" "sess-healthy-001" >/dev/null

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_empty "$problems" "healthy session produces no problems"

echo "  detect: threshold detection"

# ─── Token threshold exceeded ─────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 3000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-tokens-001"}
  }
}'

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_contains "$problems" "TOKENS" "detect token threshold exceeded"
assert_contains "$problems" "sess-tokens-001" "include session ID in detection"
assert_contains "$problems" "discord-general" "include channel key in detection"

# ─── Turn threshold exceeded ──────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 600,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-turns-001"}
  }
}'

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_contains "$problems" "TURNS" "detect turn threshold exceeded"

# ─── Compaction threshold exceeded ────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 15,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-compact-001"}
  }
}'

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_contains "$problems" "COMPACTIONS" "detect compaction threshold exceeded"

echo "  detect: failed session handling"

# ─── Failed session (stale) ───────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "failed",
    "updatedAt": '"$(ago_ms 300)"',
    "cliSessionIds": {"claude-cli": "sess-failed-001"}
  }
}'

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_contains "$problems" "FAILED" "detect stale failed session"

# ─── Failed session (recent — should NOT detect) ─────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "failed",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-failed-recent"}
  }
}'

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_not_contains "$problems" "FAILED" "skip recently failed session (not stale)"

echo "  detect: running session skip"

# ─── Running session (should skip even if over threshold) ─

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 5000000,
    "numTurns": 1000,
    "compactionCount": 20,
    "status": "running",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-running-001"}
  }
}'

# Create recent JSONL so zombie detection doesn't trigger
create_mock_jsonl "test-agent" "sess-running-001" >/dev/null

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_empty "$problems" "skip running session even if over all thresholds"

echo "  detect: no CLI session ID"

# ─── Session with no CLI session ID ──────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 5000000,
    "numTurns": 1000,
    "compactionCount": 20,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {}
  }
}'

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_empty "$problems" "skip session with no CLI session ID"

echo "  detect: multiple problems"

# ─── Multiple channels, multiple problems ─────────────────

create_sessions_json "test-agent" '{
  "channel-a": {
    "totalTokens": 3000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-a-001"}
  },
  "channel-b": {
    "totalTokens": 100,
    "numTurns": 800,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-b-001"}
  },
  "channel-c": {
    "totalTokens": 100,
    "numTurns": 10,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-c-001"}
  }
}'

# Create recent JSONLs so zombie detection doesn't trigger on healthy channels
create_mock_jsonl "test-agent" "sess-a-001" >/dev/null
create_mock_jsonl "test-agent" "sess-b-001" >/dev/null
create_mock_jsonl "test-agent" "sess-c-001" >/dev/null

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_contains "$problems" "TOKENS" "detect tokens problem in multi-channel"
assert_contains "$problems" "TURNS" "detect turns problem in multi-channel"
assert_not_contains "$problems" "channel-c" "healthy channel not flagged in multi-channel"

echo "  detect: empty and missing sessions"

# ─── Empty sessions.json ─────────────────────────────────

create_sessions_json "test-agent" '{}'
problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_empty "$problems" "empty sessions.json produces no problems"

# ─── Missing sessions.json ───────────────────────────────

problems=$(detect_sessions_problems "/nonexistent/path/sessions.json" 2>/dev/null)
assert_empty "$problems" "missing sessions.json produces no problems"

echo "  detect: zombie detection"

# ─── Zombie: turn in flight + dead process + stale JSONL ──
# status=running is the evidence that a turn is in flight. Only then does
# "CLI gone + transcript stale" mean something is wedged.

create_sessions_json "test-agent" '{
  "discord-dm": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "running",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-zombie-001"}
  }
}'

# Create a stale JSONL (old mtime)
jsonl_dir="$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-test-agent"
mkdir -p "$jsonl_dir"
echo '{"type":"test"}' > "$jsonl_dir/sess-zombie-001.jsonl"
touch_relative "2 hours ago" "$jsonl_dir/sess-zombie-001.jsonl"

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_contains "$problems" "ZOMBIE" "detect zombie session (dead process + stale JSONL)"

echo "  detect: zombie skip after recovery"

# ─── Zombie skip: recently recovered ─────────────────────

mkdir -p "$WARDEN_HOME/state/cooldowns"
echo "$(date +%s)" > "$WARDEN_HOME/state/cooldowns/test-agent-discord-dm.recovered"

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_not_contains "$problems" "ZOMBIE" "skip zombie if recently recovered"

rm -f "$WARDEN_HOME/state/cooldowns/test-agent-discord-dm.recovered"

echo "  detect: finished turn with fresh updatedAt is not a zombie"

# ─── Heartbeat resting state must NOT be flagged ──────────
# A heartbeat (or any finished turn) leaves status idle/done, a fresh
# updatedAt, an exited CLI and a transcript that stops being written. That is
# the normal resting state of every agent between turns. Treating updatedAt
# alone as "someone is using this" rotated ping/dash/isaac/bloop :main on a
# 2h clock with zero human chat, each rotation re-priming 80-100k tokens.

create_sessions_json "test-agent" '{
  "discord-heartbeat": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-heartbeat-001"}
  }
}'

echo '{"type":"test"}' > "$jsonl_dir/sess-heartbeat-001.jsonl"
touch_relative "2 hours ago" "$jsonl_dir/sess-heartbeat-001.jsonl"

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_not_contains "$problems" "ZOMBIE" "finished turn (status idle, fresh updatedAt, dead CLI, stale JSONL) not flagged as zombie"

echo "  detect: idle session is not a zombie"

# ─── Idle (no recent activity) must NOT be flagged ────────
# Dead process + stale JSONL is the normal resting state of a finished
# conversation. Without recent channel activity there is nothing to fix —
# flagging it creates a rotate->recover->idle->rotate loop across the fleet.

create_sessions_json "test-agent" '{
  "discord-idle": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(ago_ms 10800)"',
    "cliSessionIds": {"claude-cli": "sess-idle-001"}
  }
}'

echo '{"type":"test"}' > "$jsonl_dir/sess-idle-001.jsonl"
touch_relative "3 hours ago" "$jsonl_dir/sess-idle-001.jsonl"

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_not_contains "$problems" "ZOMBIE" "idle session (old updatedAt) not flagged as zombie"

echo "  detect: missing updatedAt treated as idle"

# ─── No updatedAt at all -> no evidence anyone needs it ───

create_sessions_json "test-agent" '{
  "discord-unknown": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "cliSessionIds": {"claude-cli": "sess-unknown-001"}
  }
}'

echo '{"type":"test"}' > "$jsonl_dir/sess-unknown-001.jsonl"
touch_relative "3 hours ago" "$jsonl_dir/sess-unknown-001.jsonl"

problems=$(detect_sessions_problems "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_not_contains "$problems" "ZOMBIE" "session without updatedAt not flagged as zombie"
