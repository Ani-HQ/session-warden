#!/usr/bin/env bash
# test-scan.sh — tests for bin/scan.sh (integration)

create_mock_openclaw
create_mock_claude

echo "  scan: no problems"

# ─── Clean scan with no problems ─────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-scan-healthy"}
  }
}'

# Create recent JSONL so zombie detection doesn't trigger
create_mock_jsonl "test-agent" "sess-scan-healthy" >/dev/null

export WARDEN_DRY_RUN=1
"$WARDEN_HOME/bin/scan.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_not_contains "$log_content" "ROTATE" "no rotation for healthy session"

echo "  scan: agent allowlist"

# ─── Agent allowlist filtering ────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 5000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-scan-filtered"}
  }
}'
create_mock_jsonl "test-agent" "sess-scan-filtered" >/dev/null
touch -d "5 minutes ago" "$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-test-agent/sess-scan-filtered.jsonl"

create_sessions_json "second-agent" '{
  "telegram-dm": {
    "totalTokens": 5000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-scan-second"}
  }
}'
create_mock_jsonl "second-agent" "sess-scan-second" >/dev/null
touch -d "5 minutes ago" "$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-second-agent/sess-scan-second.jsonl"

: > "$WARDEN_LOG_FILE"
export WARDEN_SCAN_AGENTS="second-agent"
export WARDEN_DRY_RUN=1
"$WARDEN_HOME/bin/scan.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_not_contains "$log_content" "test-agent" "filtered agent not scanned"
export WARDEN_SCAN_AGENTS=""

echo "  scan: detect and flag problems"

# ─── Scan detects bloated session ─────────────────────────

: > "$WARDEN_LOG_FILE"
rm -f "$WARDEN_HOME/state/cooldowns/"*

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 5000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-scan-bloated"}
  }
}'

jsonl_file=$(create_mock_jsonl "test-agent" "sess-scan-bloated")
touch -d "10 minutes ago" "$jsonl_file"

export WARDEN_DRY_RUN=1
"$WARDEN_HOME/bin/scan.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "DRY-RUN" "dry run logged for bloated session"
assert_contains "$log_content" "sess-scan-bloated" "session ID in dry-run log"

export WARDEN_DRY_RUN=0

echo "  scan: multiple agents scanned"

# ─── Multiple agents with mixed health ───────────────────

: > "$WARDEN_LOG_FILE"

create_sessions_json "test-agent" '{
  "channel-a": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-multi-a"}
  }
}'
create_mock_jsonl "test-agent" "sess-multi-a" >/dev/null

create_sessions_json "second-agent" '{
  "channel-b": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-multi-b"}
  }
}'
create_mock_jsonl "second-agent" "sess-multi-b" >/dev/null

export WARDEN_DRY_RUN=1
"$WARDEN_HOME/bin/scan.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_not_contains "$log_content" "ROTATE" "no rotation for two healthy agents"

export WARDEN_DRY_RUN=0

echo "  scan: empty agent directory"

# ─── No agents at all ────────────────────────────────────

rm -rf "$SANDBOX/openclaw/agents/"*
: > "$WARDEN_LOG_FILE"

export WARDEN_DRY_RUN=1
"$WARDEN_HOME/bin/scan.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_not_contains "$log_content" "ERROR" "no errors with empty agent directory"

export WARDEN_DRY_RUN=0

echo "  scan: stale recovery dropped at delivery"

# ─── Recovery TTL: stale queue items must not deliver ─────

setup_sandbox
create_mock_openclaw
rec_dir="$WARDEN_HOME/state/pending-recoveries"
mkdir -p "$rec_dir" "$WARDEN_HOME/state/cooldowns"

stale_item="$rec_dir/test-agent-stale.json"
printf '{"agent":"test-agent","channel_key":"agent:test-agent:main","reason":"ZOMBIE"}' > "$stale_item"
touch -d "2 hours ago" "$stale_item"

"$WARDEN_HOME/bin/scan.sh" 2>/dev/null
sleep 2

log_out=$(cat "$WARDEN_LOG_FILE")
assert_contains "$log_out" "dropped stale request for test-agent" "stale recovery dropped, not delivered"
assert_not_contains "$log_out" "RECOVERY: sent to test-agent" "no delivery for stale item"
assert_file_not_exists "$stale_item" "stale item removed from queue"

echo "  scan: duplicate recovery skipped"

# ─── Recovery dedup: recently-recovered channels skipped ──

setup_sandbox
create_mock_openclaw
rec_dir="$WARDEN_HOME/state/pending-recoveries"
mkdir -p "$rec_dir" "$WARDEN_HOME/state/cooldowns"

dup_item="$rec_dir/test-agent-dup.json"
printf '{"agent":"test-agent","channel_key":"agent:test-agent:main","reason":"ZOMBIE"}' > "$dup_item"
date +%s > "$WARDEN_HOME/state/cooldowns/test-agent-agent_test-agent_main.recovered"

"$WARDEN_HOME/bin/scan.sh" 2>/dev/null
sleep 2

log_out=$(cat "$WARDEN_LOG_FILE")
assert_contains "$log_out" "skipped duplicate for test-agent" "duplicate recovery skipped"
assert_not_contains "$log_out" "RECOVERY: sent to test-agent" "no delivery for duplicate"

echo "  scan: fresh recovery delivers"

# ─── Fresh, non-duplicate items still deliver ─────────────

setup_sandbox
create_mock_openclaw
rec_dir="$WARDEN_HOME/state/pending-recoveries"
mkdir -p "$rec_dir" "$WARDEN_HOME/state/cooldowns"

fresh_item="$rec_dir/test-agent-fresh.json"
printf '{"agent":"test-agent","channel_key":"agent:test-agent:main","reason":"ZOMBIE"}' > "$fresh_item"

"$WARDEN_HOME/bin/scan.sh" 2>/dev/null
sleep 2

log_out=$(cat "$WARDEN_LOG_FILE")
assert_contains "$log_out" "RECOVERY: sent to test-agent/agent:test-agent:main" "fresh recovery delivered"
assert_file_exists "$WARDEN_HOME/state/cooldowns/test-agent-agent_test-agent_main.recovered" "recovered marker written after delivery"
