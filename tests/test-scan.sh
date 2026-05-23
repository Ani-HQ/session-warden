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
