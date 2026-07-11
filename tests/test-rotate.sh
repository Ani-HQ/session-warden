#!/usr/bin/env bash
# test-rotate.sh — tests for bin/rotate.sh

create_mock_openclaw

echo "  rotate: dry run"

# ─── Dry run mode ────────────────────────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 3000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-rotate-dry"}
  }
}'

jsonl_file=$(create_mock_jsonl "test-agent" "sess-rotate-dry")
touch_relative "5 minutes ago" "$jsonl_file"

export WARDEN_DRY_RUN=1
"$WARDEN_HOME/bin/rotate.sh" "test-agent" "discord-general" "sess-rotate-dry" "TOKENS" "tokens=3000000" 2>/dev/null
exit_code=$?
export WARDEN_DRY_RUN=0

assert_eq "0" "$exit_code" "dry run exits 0"
assert_file_exists "$jsonl_file" "dry run does not archive JSONL"

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "DRY-RUN" "dry run logged"

echo "  rotate: successful rotation"

# ─── Full rotation ────────────────────────────────────────

# Clear cooldowns
rm -f "$WARDEN_HOME/state/cooldowns/"*

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 3000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-rotate-001"}
  }
}'

jsonl_file=$(create_mock_jsonl "test-agent" "sess-rotate-001")
touch_relative "5 minutes ago" "$jsonl_file"

"$WARDEN_HOME/bin/rotate.sh" "test-agent" "discord-general" "sess-rotate-001" "TOKENS" "tokens=3000000" 2>/dev/null
exit_code=$?

assert_eq "0" "$exit_code" "rotation exits 0"
assert_file_not_exists "$jsonl_file" "JSONL archived (moved away)"

# Check archived file exists
archived=$(ls "$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-test-agent/sess-rotate-001.jsonl.archived-"* 2>/dev/null | head -1)
assert_not_empty "$archived" "archived JSONL file exists"

# Check backup
backup=$(ls "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json.pre-rotate-"* 2>/dev/null | head -1)
assert_not_empty "$backup" "sessions.json backup created"

# Check session cleanup (cliSessionIds nulled)
cli_sid=$(jq -r '.["discord-general"].cliSessionIds // "null"' "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json" 2>/dev/null)
assert_eq "null" "$cli_sid" "cliSessionIds nulled after rotation"

# Check summary job queued
pending=$(ls "$WARDEN_HOME/state/pending-summaries/"*.json 2>/dev/null | head -1)
assert_not_empty "$pending" "summary job queued"

# Check recovery message queued
recovery=$(ls "$WARDEN_HOME/state/pending-recoveries/"*.json 2>/dev/null | head -1)
assert_not_empty "$recovery" "recovery message queued"

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "ROTATE complete" "rotation logged"
assert_contains "$log_content" "test-agent" "agent name in log"

echo "  rotate: cooldown skip"

# ─── Cooldown: skip if rotated recently ───────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 3000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-rotate-002"}
  }
}'

"$WARDEN_HOME/bin/rotate.sh" "test-agent" "discord-general" "sess-rotate-002" "TOKENS" "tokens=3000000" 2>/dev/null
exit_code=$?

assert_eq "2" "$exit_code" "cooldown returns exit code 2"

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "COOLDOWN" "cooldown logged"

echo "  rotate: consecutive failure backoff"

# ─── Failure backoff ──────────────────────────────────────

# Reset cooldown
rm -f "$WARDEN_HOME/state/cooldowns/"*

# Set failure counter to max
echo "3" > "$WARDEN_HOME/state/cooldowns/test-agent-discord-general.failures"

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "failed",
    "updatedAt": '"$(ago_ms 300)"',
    "cliSessionIds": {"claude-cli": "sess-rotate-003"}
  }
}'

"$WARDEN_HOME/bin/rotate.sh" "test-agent" "discord-general" "sess-rotate-003" "FAILED" "status=failed" 2>/dev/null
exit_code=$?

assert_eq "2" "$exit_code" "failure backoff returns exit code 2"

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "BACKOFF" "backoff logged"

echo "  rotate: mid-turn protection"

# ─── Mid-turn protection ─────────────────────────────────

rm -f "$WARDEN_HOME/state/cooldowns/"*

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 3000000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-rotate-004"}
  }
}'

# Create JSONL with very recent mtime (just now)
jsonl_file=$(create_mock_jsonl "test-agent" "sess-rotate-004")
touch "$jsonl_file"

"$WARDEN_HOME/bin/rotate.sh" "test-agent" "discord-general" "sess-rotate-004" "TOKENS" "tokens=3000000" 2>/dev/null
exit_code=$?

assert_eq "2" "$exit_code" "mid-turn protection defers rotation"

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "DEFERRED" "mid-turn deferral logged"

echo "  rotate: summary job content"

# ─── Verify summary job JSON content ─────────────────────

pending_files=("$WARDEN_HOME/state/pending-summaries/"*.json)
if [ -f "${pending_files[0]}" ]; then
  job_content=$(cat "${pending_files[0]}")
  assert_contains "$job_content" "test-agent" "summary job has agent name"
  assert_contains "$job_content" "discord-general" "summary job has channel key"
  assert_contains "$job_content" "archived_jsonl" "summary job has archived JSONL path"
  assert_contains "$job_content" "TOKENS" "summary job has reason"
else
  skip_test "no pending summary jobs to verify"
fi
