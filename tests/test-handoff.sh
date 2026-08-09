#!/usr/bin/env bash
# test-handoff.sh — model-switch handoff for OpenClaw + Hermes

create_mock_claude

# Mock openclaw so graceful flush is a no-op success
cat > "$SANDBOX/bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$SANDBOX/bin/openclaw"

# Mock gbrain as present-but-noop put
cat > "$SANDBOX/bin/gbrain" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  put) cat >/dev/null; exit 0 ;;
  get|list|tag|link|timeline-add) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$SANDBOX/bin/gbrain"

log() { echo "[test] $*" >> "$WARDEN_LOG_FILE"; }

source "$WARDEN_HOME/lib/portable.sh"
source "$WARDEN_HOME/lib/handoff.sh"

# Point Claude memory at sandbox (handoff uses claude_memory_dir from memory.sh)
claude_memory_dir() {
  local agent="$1"
  local dir="$SANDBOX/memory/${agent}"
  mkdir -p "$dir"
  echo "$dir"
}

echo "  handoff: detect runtime"

assert_eq "openclaw" "$(handoff_detect_runtime test-agent)" "detects openclaw agent"
assert_eq "unknown" "$(handoff_detect_runtime no-such-agent || true)" "unknown agent"

echo "  handoff: openclaw capture"

sid="sess-handoff-001"
create_mock_jsonl "test-agent" "$sid"
# make JSONL look idle (mtime old enough)
touch -t 202001010000 "$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-test-agent/${sid}.jsonl" 2>/dev/null \
  || touch -d "2020-01-01" "$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-test-agent/${sid}.jsonl"

create_sessions_json "test-agent" "{
  \"agent:test-agent:discord:channel:general\": {
    \"cliSessionIds\": {\"claude-cli\": \"${sid}\"},
    \"status\": \"idle\",
    \"updatedAt\": 1000000000000
  }
}"
mkdir -p "$SANDBOX/openclaw/agents/test-agent"

handoff_agent "test-agent" "model-switch"
rc=$?
assert_eq "0" "$rc" "openclaw handoff succeeds"

mem_glob=$(ls "$SANDBOX/memory/test-agent"/session_*.md 2>/dev/null | head -1)
assert_not_empty "$mem_glob" "openclaw memory file written"
assert_file_exists "$SANDBOX/openclaw/agents/test-agent/CONTEXT.md" "workspace CONTEXT.md written"
assert_file_exists "$SANDBOX/openclaw/agents/test-agent/MEMORY.md" "workspace MEMORY.md injected"

echo "  handoff: refuse empty without --force"

create_sessions_json "empty-agent" '{
  "agent:empty-agent:main": {
    "cliSessionIds": {"claude-cli": "missing-session"},
    "status": "idle"
  }
}'
mkdir -p "$SANDBOX/openclaw/agents/empty-agent"
handoff_agent "empty-agent" "model-switch"
rc=$?
assert_eq "1" "$rc" "empty extract refuses without force"

handoff_agent "empty-agent" "model-switch" --force
rc=$?
assert_eq "0" "$rc" "empty extract allowed with --force"

echo "  handoff: hermes extract + memory"

# Isolate HOME so hermes home lands in sandbox
OLD_HOME="$HOME"
export HOME="$SANDBOX"
mkdir -p "$HOME/.hermes-baymax/memories"
python3 - <<'PY'
import sqlite3, time
from pathlib import Path
home = Path.home() / ".hermes-baymax"
db = home / "state.db"
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE sessions (
  id TEXT PRIMARY KEY, source TEXT, user_id TEXT, session_key TEXT,
  chat_id TEXT, chat_type TEXT, thread_id TEXT, display_name TEXT,
  origin_json TEXT, expiry_finalized INTEGER, model TEXT, model_config TEXT,
  system_prompt TEXT, parent_session_id TEXT, started_at REAL, ended_at REAL,
  end_reason TEXT, message_count INTEGER, tool_call_count INTEGER,
  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
  cache_write_tokens INTEGER, reasoning_tokens INTEGER, cwd TEXT,
  git_branch TEXT, git_repo_root TEXT, billing_provider TEXT,
  billing_base_url TEXT, billing_mode TEXT, estimated_cost_usd REAL,
  actual_cost_usd REAL, cost_status TEXT, cost_source TEXT,
  pricing_version TEXT, title TEXT, api_call_count INTEGER,
  handoff_state TEXT, handoff_platform TEXT, handoff_error TEXT,
  compression_failure_cooldown_until REAL, compression_failure_error TEXT,
  rewind_count INTEGER, archived INTEGER
);
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT,
  content TEXT, tool_call_id TEXT, tool_calls TEXT, tool_name TEXT,
  timestamp REAL, token_count INTEGER, finish_reason TEXT,
  reasoning TEXT, reasoning_content TEXT, reasoning_details TEXT,
  codex_reasoning_items TEXT, codex_message_items TEXT,
  platform_message_id TEXT, observed INTEGER, active INTEGER, compacted INTEGER
);
""")
sid = "20260809_test_hermes"
now = time.time()
con.execute(
    "INSERT INTO sessions (id, started_at, ended_at, archived, message_count, title) VALUES (?,?,?,?,?,?)",
    (sid, now, None, 0, 2, "test"),
)
con.execute(
    "INSERT INTO messages (session_id, role, content, timestamp, active, compacted) VALUES (?,?,?,?,1,0)",
    (sid, "user", "Please plan dinner macros for the neck injury downtime and track lunch.", now),
)
con.execute(
    "INSERT INTO messages (session_id, role, content, tool_calls, timestamp, active, compacted) VALUES (?,?,?,?,?,1,0)",
    (
        sid,
        "assistant",
        "Calibrated a low-carb high-protein protocol. Pending: confirm dinner.",
        '[{"function":{"name":"terminal","arguments":"{\\"command\\":\\"ls\\"}"}}]',
        now + 1,
    ),
)
con.commit()
con.close()
print(sid)
PY

assert_eq "hermes" "$(handoff_detect_runtime baymax)" "detects hermes agent"

# Extract unit check
out=$(python3 "$WARDEN_HOME/lib/extract-hermes.py" "$HOME/.hermes-baymax")
assert_contains "$out" "USER:" "hermes extract has USER"
assert_contains "$out" "ASSISTANT:" "hermes extract has ASSISTANT"
assert_contains "$out" "→ terminal" "hermes extract has tool action"

handoff_agent "baymax" "model-switch"
rc=$?
assert_eq "0" "$rc" "hermes handoff succeeds"
assert_file_exists "$HOME/.hermes-baymax/memories/HANDOFF.md" "hermes HANDOFF.md written"
assert_file_exists "$HOME/.hermes-baymax/CONTEXT.md" "hermes CONTEXT.md written"
assert_contains "$(cat "$HOME/.hermes-baymax/memories/HANDOFF.md")" "What was happening" "hermes handoff has sections"

export HOME="$OLD_HOME"

echo "  handoff: CLI entrypoints"

help_out=$("$REAL_WARDEN_HOME/bin/session-warden" help 2>/dev/null)
assert_contains "$help_out" "handoff" "CLI help lists handoff"
assert_contains "$help_out" "model-switch" "CLI help lists model-switch"

"$REAL_WARDEN_HOME/bin/handoff.sh" 2>/dev/null
rc=$?
assert_eq "2" "$rc" "handoff.sh without args exits 2"
