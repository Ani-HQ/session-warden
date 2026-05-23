#!/usr/bin/env bash
# setup.sh — create mock sandbox for testing

SANDBOX=""
TEST_RESULTS_FILE=""

setup_sandbox() {
  # Keep results file persistent across sandbox resets
  if [ -z "${TEST_RESULTS_FILE:-}" ]; then
    TEST_RESULTS_FILE=$(mktemp /tmp/session-warden-results-XXXXXX)
  fi

  # Clean up previous sandbox if any
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi

  SANDBOX=$(mktemp -d /tmp/session-warden-test-XXXXXX)
  export SANDBOX TEST_RESULTS_FILE

  # Save real warden home on first call only
  if [ -z "${REAL_WARDEN_HOME:-}" ]; then
    REAL_WARDEN_HOME="$WARDEN_HOME"
  fi
  export REAL_WARDEN_HOME

  # Create a sandbox warden home that symlinks to real code but has its own state
  WARDEN_SANDBOX="$SANDBOX/warden-home"
  mkdir -p "$WARDEN_SANDBOX"
  ln -sf "$REAL_WARDEN_HOME/lib" "$WARDEN_SANDBOX/lib"
  ln -sf "$REAL_WARDEN_HOME/bin" "$WARDEN_SANDBOX/bin"
  # Copy config instead of symlinking — thresholds.env hard-resets PATH which
  # would wipe out mock binaries during tests
  mkdir -p "$WARDEN_SANDBOX/config"
  if [ -f "$REAL_WARDEN_HOME/config/thresholds.env" ]; then
    cp "$REAL_WARDEN_HOME/config/thresholds.env" "$WARDEN_SANDBOX/config/thresholds.env"
    # Strip lines that would override test-controlled values:
    # PATH (would wipe mock binaries), WARDEN_* (setup.sh exports all test values),
    # credentials, DBUS/XDG (cron-only)
    sed -i '/^export PATH=/d; /^export XDG_RUNTIME_DIR=/d; /^export DBUS_SESSION_BUS_ADDRESS=/d; /^WARDEN_/d' "$WARDEN_SANDBOX/config/thresholds.env"
  elif [ -f "$REAL_WARDEN_HOME/config/thresholds.env.example" ]; then
    cp "$REAL_WARDEN_HOME/config/thresholds.env.example" "$WARDEN_SANDBOX/config/thresholds.env"
    sed -i '/^export PATH=/d; /^export XDG_RUNTIME_DIR=/d; /^export DBUS_SESSION_BUS_ADDRESS=/d; /^WARDEN_/d' "$WARDEN_SANDBOX/config/thresholds.env"
  fi
  # Copy any other config files
  for cfg in "$REAL_WARDEN_HOME/config/"*; do
    [ -f "$cfg" ] || continue
    local cfg_name
    cfg_name=$(basename "$cfg")
    [ "$cfg_name" = "thresholds.env" ] && continue
    cp "$cfg" "$WARDEN_SANDBOX/config/"
  done
  ln -sf "$REAL_WARDEN_HOME/hooks" "$WARDEN_SANDBOX/hooks"

  # Sandbox-local state directories
  mkdir -p \
    "$WARDEN_SANDBOX/state/pending-summaries" \
    "$WARDEN_SANDBOX/state/cooldowns" \
    "$WARDEN_SANDBOX/state/context-sync" \
    "$WARDEN_SANDBOX/state/crash-buffers" \
    "$WARDEN_SANDBOX/state/pending-recoveries" \
    "$WARDEN_SANDBOX/state/mcp-supervisor" \
    "$WARDEN_SANDBOX/state/locks"

  # Mock OpenClaw + Claude directory structure
  mkdir -p \
    "$SANDBOX/openclaw/agents/test-agent/sessions" \
    "$SANDBOX/openclaw/agents/second-agent/sessions" \
    "$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-test-agent" \
    "$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-second-agent" \
    "$SANDBOX/memory"

  # Override all paths for tests — WARDEN_HOME points to sandbox
  export WARDEN_HOME="$WARDEN_SANDBOX"
  export WARDEN_OPENCLAW_HOME="$SANDBOX/openclaw"
  export WARDEN_CLAUDE_PROJECTS="$SANDBOX/claude-projects"
  export WARDEN_LOG_FILE="$WARDEN_SANDBOX/state/scan.log"
  export WARDEN_DRY_RUN=0
  export WARDEN_MAX_TOKENS=2000000
  export WARDEN_MAX_TURNS=500
  export WARDEN_MAX_BYTES=4194304
  export WARDEN_MAX_COMPACTIONS=10
  export WARDEN_COOLDOWN_SECONDS=600
  export WARDEN_MAX_CONSECUTIVE_FAILURES=3
  export WARDEN_GATEWAY_RESTART_COOLDOWN_SECONDS=300
  export WARDEN_SUMMARY_MODEL=claude-haiku-4-5-20251001
  export WARDEN_MEMORY_MAX_BYTES=16384
  export WARDEN_SCAN_AGENTS=""
  export WARDEN_TELEGRAM_BOT_TOKEN=""
  export WARDEN_TELEGRAM_CHAT_ID=""
  export WARDEN_ARCHIVE_RETENTION_DAYS=7
  export WARDEN_ACTIVE_THRESHOLD_SECS=60

  # Copy fixture files
  if [ -d "$TESTS_DIR/fixtures" ]; then
    for fixture in "$TESTS_DIR/fixtures"/*.json; do
      [ -f "$fixture" ] || continue
      cp "$fixture" "$SANDBOX/"
    done
  fi

  : > "$WARDEN_LOG_FILE"
}

teardown_sandbox() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
  # Results file cleaned up by runner after reading
}

# Assertion wrappers that write to results file (for cross-subshell tracking)
_record() {
  echo "$1|$2" >> "$TEST_RESULTS_FILE"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-values should be equal}"
  if [ "$expected" = "$actual" ]; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg (expected='$expected' actual='$actual')"
  fi
}

assert_neq() {
  local unexpected="$1" actual="$2" msg="${3:-values should differ}"
  if [ "$unexpected" != "$actual" ]; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg (got='$actual')"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-should contain substring}"
  if echo "$haystack" | grep -qF -- "$needle"; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg (missing='$needle')"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-should not contain substring}"
  if ! echo "$haystack" | grep -qF -- "$needle"; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg (found='$needle')"
  fi
}

assert_empty() {
  local val="$1" msg="${2:-should be empty}"
  if [ -z "$val" ]; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg (got='${val:0:100}')"
  fi
}

assert_not_empty() {
  local val="$1" msg="${2:-should not be empty}"
  if [ -n "$val" ]; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-file should exist: $1}"
  if [ -f "$path" ]; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg"
  fi
}

assert_file_not_exists() {
  local path="$1" msg="${2:-file should not exist: $1}"
  if [ ! -f "$path" ]; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg"
  fi
}

assert_dir_exists() {
  local path="$1" msg="${2:-dir should exist: $1}"
  if [ -d "$path" ]; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg"
  fi
}

assert_exit_code() {
  local expected="$1" actual="$2" msg="${3:-exit code should be $1}"
  assert_eq "$expected" "$actual" "$msg"
}

assert_gt() {
  local a="$1" b="$2" msg="${3:-$1 should be > $2}"
  if [ "$a" -gt "$b" ] 2>/dev/null; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg ($a is not > $b)"
  fi
}

assert_matches() {
  local text="$1" pattern="$2" msg="${3:-should match pattern}"
  if echo "$text" | grep -qE "$pattern"; then
    _record "PASS" "$msg"
  else
    _record "FAIL" "$msg (pattern='$pattern')"
  fi
}

skip_test() {
  local msg="${1:-skipped}"
  _record "SKIP" "$msg"
}

# Create a mock sessions.json with various session states
create_sessions_json() {
  local agent="$1" content="$2"
  local dir="$SANDBOX/openclaw/agents/${agent}/sessions"
  mkdir -p "$dir"
  echo "$content" > "$dir/sessions.json"
}

# Create a mock JSONL file
create_mock_jsonl() {
  local agent="$1" session_id="$2" content="${3:-}"
  local dir="$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-${agent}"
  mkdir -p "$dir"
  local file="$dir/${session_id}.jsonl"

  if [ -n "$content" ]; then
    echo "$content" > "$file"
  else
    # Default: a simple conversation
    cat > "$file" <<'JSONL'
{"type":"user","message":{"content":[{"type":"text","text":"Hello, can you help me fix a bug?"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Sure, I'll look into it."},{"type":"tool_use","name":"Read","input":{"file_path":"/src/main.ts"}}]}}
{"type":"user","message":{"content":[{"type":"text","text":"The error is on line 42."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"I see the issue. Let me fix it."},{"type":"tool_use","name":"Edit","input":{"file_path":"/src/main.ts","old_string":"bug","new_string":"fix"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed! The tests pass now."}]}}
JSONL
  fi
  echo "$file"
}

# Create a mock claude CLI that returns canned summaries
create_mock_claude() {
  local mock_bin="$SANDBOX/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Mock claude CLI for testing
if [[ "$*" == *"-p"* ]]; then
  cat <<'SUMMARY'
## What was happening
You were fixing a bug in the main application file.

## Actions taken
- Read /src/main.ts to identify the issue
- Edited /src/main.ts to fix the bug on line 42
- Ran npm test to verify the fix

## Decisions made
- Chose to fix inline rather than refactor

## Pending / unfinished
- Deploy the fix to staging
- Update the changelog

## Context for next session
The bug was a typo causing a null reference. Fix is committed but not deployed.
SUMMARY
fi
MOCK
  chmod +x "$mock_bin/claude"
  export PATH="$mock_bin:$PATH"
}

# Create a mock openclaw CLI
create_mock_openclaw() {
  local mock_bin="$SANDBOX/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
# Mock openclaw CLI for testing
case "$1" in
  sessions)
    echo "sessions cleanup done"
    ;;
  gateway)
    echo "gateway restarted"
    ;;
  agent)
    echo "message sent"
    ;;
esac
MOCK
  chmod +x "$mock_bin/openclaw"
  export PATH="$mock_bin:$PATH"
}

# Utility: get current epoch in milliseconds
now_ms() {
  echo "$(date +%s)000"
}

# Utility: get epoch ms for N seconds ago
ago_ms() {
  local seconds="$1"
  echo "$(( $(date +%s) - seconds ))000"
}
