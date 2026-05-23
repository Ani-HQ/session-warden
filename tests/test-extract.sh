#!/usr/bin/env bash
# test-extract.sh — tests for lib/extract.sh

source "$WARDEN_HOME/lib/extract.sh"

echo "  extract: transcript extraction"

# ─── Basic conversation transcript ────────────────────────

jsonl_file=$(create_mock_jsonl "test-agent" "sess-extract-001")

transcript=$(extract_session_transcript "$jsonl_file")
assert_contains "$transcript" "USER:" "transcript contains USER prefix"
assert_contains "$transcript" "ASSISTANT:" "transcript contains ASSISTANT prefix"
assert_contains "$transcript" "Hello, can you help me fix a bug?" "transcript contains user message"
assert_contains "$transcript" "Fixed! The tests pass now." "transcript contains assistant response"

echo "  extract: tool actions"

# ─── Tool actions in transcript ───────────────────────────

assert_contains "$transcript" "Read" "transcript contains Read tool action"
assert_contains "$transcript" "/src/main.ts" "transcript contains file path from tool"
assert_contains "$transcript" "Edit" "transcript contains Edit tool action"
assert_contains "$transcript" "Bash" "transcript contains Bash tool action"
assert_contains "$transcript" "npm test" "transcript contains command from Bash tool"

echo "  extract: empty and missing files"

# ─── Empty JSONL ──────────────────────────────────────────

empty_file="$SANDBOX/empty.jsonl"
: > "$empty_file"
transcript=$(extract_session_transcript "$empty_file")
assert_empty "$transcript" "empty JSONL produces empty transcript"

# ─── Missing file ────────────────────────────────────────

transcript=$(extract_session_transcript "/nonexistent.jsonl" 2>/dev/null)
assert_empty "$transcript" "missing file produces empty transcript"

echo "  extract: malformed lines"

# ─── JSONL with extra fields (should be ignored) ─────────

extra_file="$SANDBOX/extra-fields.jsonl"
cat > "$extra_file" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"Valid message"}]},"extra_field":"ignored"}
{"type":"system","message":"not a conversation turn"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Valid response"}]},"meta":{"ts":12345}}
JSONL

transcript=$(extract_session_transcript "$extra_file" 2>/dev/null)
assert_contains "$transcript" "Valid message" "valid lines extracted from mixed JSONL"
assert_contains "$transcript" "Valid response" "valid assistant lines extracted from mixed JSONL"

echo "  extract: tool summary"

# ─── Tool summary extraction ─────────────────────────────

jsonl_file=$(create_mock_jsonl "test-agent" "sess-extract-002")

summary=$(extract_tool_summary "$jsonl_file")
assert_not_empty "$summary" "tool summary is not empty"
assert_contains "$summary" "Read" "tool summary includes Read"
assert_contains "$summary" "Edit" "tool summary includes Edit"
assert_contains "$summary" "Bash" "tool summary includes Bash"

echo "  extract: text-only conversation"

# ─── Conversation with no tools ───────────────────────────

text_file="$SANDBOX/text-only.jsonl"
cat > "$text_file" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"What is 2+2?"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"4"}]}}
JSONL

transcript=$(extract_session_transcript "$text_file")
assert_contains "$transcript" "What is 2+2?" "text-only: user message"
assert_contains "$transcript" "4" "text-only: assistant response"
assert_not_contains "$transcript" "→" "text-only: no tool markers"

summary=$(extract_tool_summary "$text_file")
assert_empty "$summary" "text-only: empty tool summary"

echo "  extract: multi-tool single message"

# ─── Multiple tools in one assistant message ──────────────

multi_file="$SANDBOX/multi-tool.jsonl"
cat > "$multi_file" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"Let me check multiple files."},{"type":"tool_use","name":"Read","input":{"file_path":"/a.ts"}},{"type":"tool_use","name":"Read","input":{"file_path":"/b.ts"}},{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
JSONL

transcript=$(extract_session_transcript "$multi_file")
assert_contains "$transcript" "/a.ts" "multi-tool: first file path"
assert_contains "$transcript" "/b.ts" "multi-tool: second file path"
assert_contains "$transcript" "git status" "multi-tool: bash command"
