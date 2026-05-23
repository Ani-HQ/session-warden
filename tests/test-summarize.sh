#!/usr/bin/env bash
# test-summarize.sh — tests for bin/summarize.sh

create_mock_claude
create_mock_openclaw

echo "  summarize: process pending job"

# ─── Pending summary job gets processed ───────────────────

archive_dir="$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-test-agent"
mkdir -p "$archive_dir"
archived_jsonl="$archive_dir/sess-sum-001.jsonl.archived-20260522-120000"
cat > "$archived_jsonl" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"Deploy the fix to staging."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Deploying now."},{"type":"tool_use","name":"Bash","input":{"command":"git push origin staging"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Deployed successfully."}]}}
JSONL

pending_dir="$WARDEN_HOME/state/pending-summaries"
cat > "$pending_dir/test-agent-20260522-120000.json" <<JOB
{
  "agent": "test-agent",
  "channel_key": "discord-general",
  "cli_session_id": "sess-sum-001",
  "archived_jsonl": "$archived_jsonl",
  "timestamp": "20260522-120000",
  "reason": "TOKENS"
}
JOB

"$WARDEN_HOME/bin/summarize.sh" >> "$WARDEN_LOG_FILE" 2>&1

assert_file_not_exists "$pending_dir/test-agent-20260522-120000.json" "pending job cleaned up after processing"

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "SUMMARY" "summarize logged"

echo "  summarize: missing archived JSONL"

# ─── Missing archived JSONL skips gracefully ─────────────

cat > "$pending_dir/test-agent-missing.json" <<JOB
{
  "agent": "test-agent",
  "channel_key": "discord-general",
  "cli_session_id": "sess-missing",
  "archived_jsonl": "/nonexistent/file.jsonl",
  "timestamp": "20260522-999999",
  "reason": "TOKENS"
}
JOB

"$WARDEN_HOME/bin/summarize.sh" >> "$WARDEN_LOG_FILE" 2>&1

assert_file_not_exists "$pending_dir/test-agent-missing.json" "missing JSONL job cleaned up"

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "missing" "missing JSONL logged"

echo "  summarize: no pending jobs"

# ─── No pending jobs -> no-op ────────────────────────────

rm -f "$pending_dir/"*.json
: > "$WARDEN_LOG_FILE"

"$WARDEN_HOME/bin/summarize.sh" >> "$WARDEN_LOG_FILE" 2>&1
exit_code=$?

assert_eq "0" "$exit_code" "no pending jobs exits cleanly"

echo "  summarize: tiny transcript skipped"

# ─── Very small JSONL produces tiny transcript ────────────

tiny_jsonl="$archive_dir/sess-tiny.jsonl.archived-20260522-130000"
echo '{"type":"user"}' > "$tiny_jsonl"

cat > "$pending_dir/test-agent-tiny.json" <<JOB
{
  "agent": "test-agent",
  "channel_key": "discord-tiny",
  "cli_session_id": "sess-tiny",
  "archived_jsonl": "$tiny_jsonl",
  "timestamp": "20260522-130000",
  "reason": "TOKENS"
}
JOB

"$WARDEN_HOME/bin/summarize.sh" >> "$WARDEN_LOG_FILE" 2>&1

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "too small" "tiny transcript skip logged"
