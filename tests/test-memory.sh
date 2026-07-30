#!/usr/bin/env bash
# test-memory.sh — tests for lib/memory.sh

# Mock claude CLI before sourcing memory.sh
create_mock_claude

# Define log function (normally provided by the calling script)
log() {
  echo "[$(date_iso_seconds)] $*" >> "${WARDEN_LOG_FILE:-/dev/null}"
}

source "$WARDEN_HOME/lib/portable.sh"
source "$WARDEN_HOME/lib/extract.sh"
source "$WARDEN_HOME/lib/memory.sh"

# Override claude_memory_dir to use sandbox
claude_memory_dir() {
  local agent="$1"
  local dir="$SANDBOX/memory/${agent}"
  mkdir -p "$dir"
  echo "$dir"
}

# Run the REAL write_workspace_context against the sandbox rather than a stub.
# A hand-copied stub drifts from the implementation and hides regressions in it.
WARDEN_OPENCLAW_HOME="$SANDBOX/openclaw"
eval "orig_write_workspace_context() $(declare -f write_workspace_context | tail -n +2)"
write_workspace_context() {
  mkdir -p "${WARDEN_OPENCLAW_HOME}/agents/${1}"
  orig_write_workspace_context "$@"
}

echo "  memory: claude_memory_dir"

# ─── Memory directory creation ────────────────────────────

mem_dir=$(claude_memory_dir "test-agent")
assert_dir_exists "$mem_dir" "memory dir created for agent"
assert_contains "$mem_dir" "test-agent" "memory dir contains agent name"

echo "  memory: build_fallback_memory"

# ─── Fallback memory ─────────────────────────────────────

fallback=$(build_fallback_memory "line 1
line 2
line 3" "")
assert_contains "$fallback" "fallback" "fallback memory indicates fallback"
assert_contains "$fallback" "line 1" "fallback contains transcript lines"

# With existing context that has pending items
fallback_with_pending=$(build_fallback_memory "transcript content" "## Pending
- Deploy fix to staging
- Update changelog
## Context")
assert_contains "$fallback_with_pending" "Deploy fix" "fallback carries forward pending items"

echo "  memory: write_session_memory"

# ─── Write session memory (happy path) ───────────────────

jsonl_file=$(create_mock_jsonl "test-agent" "sess-mem-001")
transcript_file="$SANDBOX/test-transcript.txt"
extract_session_transcript "$jsonl_file" > "$transcript_file"

write_session_memory "test-agent" "discord-general" "sess-mem-001" "$transcript_file"
exit_code=$?

assert_eq "0" "$exit_code" "write_session_memory returns 0 on success"

mem_dir=$(claude_memory_dir "test-agent")
mem_file="$mem_dir/session_discord-general.md"
assert_file_exists "$mem_file" "memory file created"

content=$(cat "$mem_file")
assert_contains "$content" "session-context-discord-general" "memory has correct frontmatter name"
assert_contains "$content" "session-warden" "memory credits session-warden"
assert_contains "$content" "sess-mem-001" "memory includes session ID"
assert_contains "$content" "## What was happening" "memory has structured sections"
assert_contains "$content" "## Actions taken" "memory has actions section"
assert_contains "$content" "## Pending" "memory has pending section"

echo "  memory: MEMORY.md index"

# ─── MEMORY.md index update ──────────────────────────────

index_file="$mem_dir/MEMORY.md"
assert_file_exists "$index_file" "MEMORY.md index created"
index_content=$(cat "$index_file")
assert_contains "$index_content" "session_discord-general.md" "index references memory file"
assert_contains "$index_content" "discord-general" "index includes channel name"

echo "  memory: index deduplication"

# ─── Write again — should replace, not duplicate ─────────

write_session_memory "test-agent" "discord-general" "sess-mem-002" "$transcript_file"
index_content=$(cat "$index_file")
count=$(grep -c "session_discord-general.md" "$index_file")
assert_eq "1" "$count" "index has exactly one entry per channel (no duplicates)"

echo "  memory: multiple channels"

# ─── Multiple channels stay separate ─────────────────────

write_session_memory "test-agent" "telegram-dm" "sess-mem-003" "$transcript_file"
assert_file_exists "$mem_dir/session_telegram-dm.md" "separate memory file for second channel"

index_content=$(cat "$index_file")
assert_contains "$index_content" "discord-general" "index has first channel"
assert_contains "$index_content" "telegram-dm" "index has second channel"

echo "  memory: empty transcript"

# ─── Empty transcript ────────────────────────────────────

empty_transcript="$SANDBOX/empty-transcript.txt"
: > "$empty_transcript"
write_session_memory "test-agent" "empty-channel" "sess-empty" "$empty_transcript"
# Should not create a memory file for empty transcript
assert_file_not_exists "$mem_dir/session_empty-channel.md" "no memory file for empty transcript"

echo "  memory: missing transcript file"

# ─── Missing transcript file ─────────────────────────────

write_session_memory "test-agent" "missing-channel" "sess-missing" "/nonexistent/transcript.txt" 2>/dev/null
exit_code=$?
assert_eq "1" "$exit_code" "returns 1 for missing transcript"

echo "  memory: workspace context injection"

# ─── Workspace CONTEXT.md ────────────────────────────────

ctx_file="$SANDBOX/openclaw/agents/test-agent/CONTEXT.md"
assert_file_exists "$ctx_file" "CONTEXT.md created in workspace"
ctx_content=$(cat "$ctx_file")
assert_contains "$ctx_content" "sess-mem-003" "CONTEXT.md has session ID"

echo "  memory: workspace MEMORY.md markers"

# ─── Workspace MEMORY.md marker injection ────────────────

ws_mem="$SANDBOX/openclaw/agents/test-agent/MEMORY.md"
assert_file_exists "$ws_mem" "workspace MEMORY.md created"
ws_content=$(cat "$ws_mem")
assert_contains "$ws_content" "SESSION-WARDEN-START" "workspace MEMORY.md has start marker"
assert_contains "$ws_content" "SESSION-WARDEN-END" "workspace MEMORY.md has end marker"
assert_contains "$ws_content" "auto-injected by session-warden" "workspace MEMORY.md credits warden"

echo "  memory: marker replacement on re-write"

# ─── Re-write should replace markers, not append ─────────

write_session_memory "test-agent" "telegram-dm" "sess-mem-004" "$transcript_file"
ws_content=$(cat "$ws_mem")
start_count=$(grep -c "SESSION-WARDEN-START" "$ws_mem")
assert_eq "1" "$start_count" "only one SESSION-WARDEN-START marker after re-write"

echo "  memory: frontmatter format"

# ─── Frontmatter validation ──────────────────────────────

mem_content=$(cat "$mem_dir/session_discord-general.md")
assert_contains "$mem_content" "---" "memory file has frontmatter delimiter"
assert_contains "$mem_content" "name:" "memory file has name field"
assert_contains "$mem_content" "description:" "memory file has description field"
assert_contains "$mem_content" "type: project" "memory file has type field"

rm -f "$transcript_file"

echo "  memory: prompt-cache stability"

# ─── Rewriting is what invalidates the prompt cache ──────
# MEMORY.md and CONTEXT.md are part of the agent's system prompt and
# context-sync rewrites them every few minutes. Touching them when only the
# clock moved throws away the provider's cached prefix for no new information.

cdir="$SANDBOX/openclaw/agents/cache-agent"

write_workspace_context "cache-agent" "Steady summary." "sess-cache-1" "discord-general"
assert_file_exists "$cdir/MEMORY.md" "MEMORY.md created on first write"
c_mem=$(md5sum "$cdir/MEMORY.md" | cut -d' ' -f1)
c_ctx=$(md5sum "$cdir/CONTEXT.md" | cut -d' ' -f1)
c_mtime=$(stat_mtime "$cdir/MEMORY.md")

sleep 1
write_workspace_context "cache-agent" "Steady summary." "sess-cache-1" "discord-general"
assert_eq "$c_mem" "$(md5sum "$cdir/MEMORY.md" | cut -d' ' -f1)" \
  "MEMORY.md unchanged when only the timestamp would move"
assert_eq "$c_ctx" "$(md5sum "$cdir/CONTEXT.md" | cut -d' ' -f1)" \
  "CONTEXT.md unchanged when only the timestamp would move"
assert_eq "$c_mtime" "$(stat_mtime "$cdir/MEMORY.md")" \
  "MEMORY.md not rewritten at all (mtime held)"

# ─── but any real change must still land ─────────────────

sleep 1
write_workspace_context "cache-agent" "A different summary entirely." "sess-cache-1" "discord-general"
assert_contains "$(cat "$cdir/MEMORY.md")" "different summary entirely" \
  "MEMORY.md rewritten when the summary changed"

sleep 1
write_workspace_context "cache-agent" "A different summary entirely." "sess-cache-2" "discord-general"
assert_contains "$(cat "$cdir/CONTEXT.md")" "sess-cache-2" \
  "CONTEXT.md rewritten when the session id changed"

write_workspace_context "cache-agent" "A different summary entirely." "sess-cache-2" "telegram-dm"
assert_contains "$(cat "$cdir/MEMORY.md")" "telegram-dm" \
  "MEMORY.md rewritten when the channel changed"

assert_eq "1" "$(grep -c "SESSION-WARDEN-START" "$cdir/MEMORY.md")" \
  "still exactly one marker block after conditional rewrites"
