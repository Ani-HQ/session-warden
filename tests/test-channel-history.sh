#!/usr/bin/env bash
# test-channel-history.sh — tests for lib/channel-history.sh

# channel-history.sh uses WARDEN_HOME and CRASH_BUFFER_DIR
export CRASH_BUFFER_DIR="$WARDEN_HOME/state/crash-buffers"
mkdir -p "$CRASH_BUFFER_DIR"

source "$WARDEN_HOME/lib/channel-history.sh"

log() {
  echo "[$(date_iso_seconds)] $*" >> "$WARDEN_LOG_FILE"
}

echo "  channel-history: crash buffer write and read"

# ─── Write a crash buffer directly ───────────────────────

buffer_file="$CRASH_BUFFER_DIR/test-agent-discord-general.json"
cat > "$buffer_file" <<BUFFER
{
  "agent": "test-agent",
  "channel_key": "discord-general",
  "provider": "discord",
  "captured_at": $(date +%s),
  "unprocessed_messages": [
    {"author": "ani", "content": "fix the deploy bug", "timestamp": "2026-05-22T10:00:00Z"},
    {"author": "zara", "content": "also check the staging env", "timestamp": "2026-05-22T10:01:00Z"}
  ],
  "last_bot_message": {"author": "test-agent", "content": "Working on the refactor now.", "timestamp": "2026-05-22T09:55:00Z"}
}
BUFFER

output=$(read_crash_buffer "test-agent" "discord-general")
assert_not_empty "$output" "crash buffer read returns content"
assert_contains "$output" "Unprocessed Messages" "crash buffer has header"
assert_contains "$output" "fix the deploy bug" "crash buffer has first message"
assert_contains "$output" "also check the staging env" "crash buffer has second message"
assert_contains "$output" "ani" "crash buffer has author name"
assert_contains "$output" "last response before crash" "crash buffer has bot context"
assert_contains "$output" "Working on the refactor" "crash buffer has bot's last message"

echo "  channel-history: crash buffer TTL"

# ─── Expired crash buffer ────────────────────────────────

expired_file="$CRASH_BUFFER_DIR/test-agent-expired-channel.json"
cat > "$expired_file" <<BUFFER
{
  "agent": "test-agent",
  "channel_key": "expired-channel",
  "provider": "discord",
  "captured_at": $(($(date +%s) - 99999)),
  "unprocessed_messages": [
    {"author": "someone", "content": "old message", "timestamp": "2026-01-01T00:00:00Z"}
  ]
}
BUFFER

output=$(read_crash_buffer "test-agent" "expired-channel")
assert_empty "$output" "expired crash buffer returns empty"
assert_file_not_exists "$expired_file" "expired crash buffer file deleted"

echo "  channel-history: crash buffer clear"

# ─── Clear crash buffer ──────────────────────────────────

assert_file_exists "$buffer_file" "buffer file exists before clear"
clear_crash_buffer "test-agent" "discord-general"
assert_file_not_exists "$buffer_file" "buffer file removed after clear"

echo "  channel-history: read nonexistent buffer"

# ─── Read nonexistent buffer ─────────────────────────────

output=$(read_crash_buffer "test-agent" "nonexistent-channel")
assert_empty "$output" "nonexistent buffer returns empty string"

echo "  channel-history: cleanup expired buffers"

# ─── Cleanup expired crash buffers ────────────────────────

fresh_file="$CRASH_BUFFER_DIR/test-agent-fresh.json"
cat > "$fresh_file" <<BUFFER
{
  "captured_at": $(date +%s),
  "unprocessed_messages": [{"content": "fresh"}]
}
BUFFER

old_file="$CRASH_BUFFER_DIR/test-agent-old.json"
cat > "$old_file" <<BUFFER
{
  "captured_at": $(($(date +%s) - 99999)),
  "unprocessed_messages": [{"content": "old"}]
}
BUFFER

cleanup_expired_crash_buffers

assert_file_exists "$fresh_file" "fresh buffer survives cleanup"
assert_file_not_exists "$old_file" "old buffer removed by cleanup"

echo "  channel-history: empty unprocessed messages"

# ─── Buffer with no unprocessed messages ──────────────────

empty_buf="$CRASH_BUFFER_DIR/test-agent-empty-msgs.json"
cat > "$empty_buf" <<BUFFER
{
  "agent": "test-agent",
  "channel_key": "empty-msgs",
  "provider": "discord",
  "captured_at": $(date +%s),
  "unprocessed_messages": [],
  "last_bot_message": null
}
BUFFER

output=$(read_crash_buffer "test-agent" "empty-msgs")
assert_empty "$output" "buffer with no unprocessed messages returns empty"
