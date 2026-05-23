#!/usr/bin/env bash
# test-context-sync.sh — tests for bin/context-sync.sh

create_mock_claude

echo "  context-sync: syncs modified session"

# ─── Active session with modified JSONL gets synced ───────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-csync-001"}
  }
}'

jsonl_file=$(create_mock_jsonl "test-agent" "sess-csync-001")

# Make sure mtime tracking dir exists
mkdir -p "$WARDEN_HOME/state/context-sync"

# No previous sync state -> should sync
: > "$WARDEN_LOG_FILE"
"$WARDEN_HOME/bin/context-sync.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "CONTEXT-SYNC" "context sync ran"

echo "  context-sync: skips unmodified session"

# ─── Session not modified since last sync ─────────────────

: > "$WARDEN_LOG_FILE"

# Run again without modifying JSONL — should skip
"$WARDEN_HOME/bin/context-sync.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_not_contains "$log_content" "capturing" "unmodified session not re-synced"

echo "  context-sync: syncs after modification"

# ─── Modified JSONL triggers re-sync ─────────────────────

sleep 1
echo '{"type":"user","message":{"content":[{"type":"text","text":"new message"}]}}' >> "$jsonl_file"

: > "$WARDEN_LOG_FILE"
"$WARDEN_HOME/bin/context-sync.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_contains "$log_content" "CONTEXT-SYNC" "modified session re-synced"

echo "  context-sync: skips tiny JSONL"

# ─── Very small JSONL skipped ─────────────────────────────

create_sessions_json "second-agent" '{
  "telegram-dm": {
    "totalTokens": 100,
    "numTurns": 1,
    "compactionCount": 0,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-csync-tiny"}
  }
}'

tiny_dir="$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-second-agent"
mkdir -p "$tiny_dir"
echo 'x' > "$tiny_dir/sess-csync-tiny.jsonl"

: > "$WARDEN_LOG_FILE"
"$WARDEN_HOME/bin/context-sync.sh" 2>/dev/null

log_content=$(cat "$WARDEN_LOG_FILE" 2>/dev/null)
assert_not_contains "$log_content" "second-agent" "tiny JSONL not synced"

echo "  context-sync: no sessions"

# ─── No sessions to sync ─────────────────────────────────

rm -rf "$SANDBOX/openclaw/agents/"*
: > "$WARDEN_LOG_FILE"

"$WARDEN_HOME/bin/context-sync.sh" 2>/dev/null
exit_code=$?
assert_eq "0" "$exit_code" "no sessions exits cleanly"
