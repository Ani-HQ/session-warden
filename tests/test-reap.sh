#!/usr/bin/env bash
# test-reap.sh — tests for lib/reap.sh (stall reaper)

source "$WARDEN_HOME/lib/reap.sh"

# ─── reap_last_progress_epoch ────────────────────────────
echo "  reap: last_progress_epoch"

# updatedAt (ms) newer than jsonl mtime (s)
result=$(reap_last_progress_epoch 2000000 1500)
assert_eq "2000" "$result" "updatedAt ms wins when newer"

# jsonl mtime newer than updatedAt
result=$(reap_last_progress_epoch 1000000 5000)
assert_eq "5000" "$result" "jsonl mtime wins when newer"

# missing jsonl mtime (0) falls back to updatedAt
result=$(reap_last_progress_epoch 3000000 0)
assert_eq "3000" "$result" "zero jsonl mtime falls back to updatedAt"

# ─── reap_stall_verdict ──────────────────────────────────
echo "  reap: stall_verdict"

# running + idle past cap => STUCK (liveness is NOT part of the verdict — it
# only decides the action: kill vs clear vs escalate)
now=100000
result=$(reap_stall_verdict "running" "$now" $((now - 1000)) 900)
assert_eq "STUCK" "$result" "running + idle>cap is STUCK"

# running + idle under cap => healthy
result=$(reap_stall_verdict "running" "$now" $((now - 100)) 900)
assert_empty "$result" "running + idle<cap is healthy"

# running + stale but no live child still counts as STUCK (orchestrator clears it)
result=$(reap_stall_verdict "running" "$now" $((now - 5000)) 900)
assert_eq "STUCK" "$result" "running + stale is STUCK regardless of process liveness"

# not running (idle/done) => never STUCK, even if very old
result=$(reap_stall_verdict "done" "$now" $((now - 99999)) 900)
assert_empty "$result" "done session is never STUCK"

result=$(reap_stall_verdict "failed" "$now" $((now - 99999)) 900)
assert_empty "$result" "failed session is never STUCK"

# ─── reap_list_running ───────────────────────────────────
echo "  reap: list_running"

create_sessions_json "test-agent" '{
  "agent:test-agent:discord:channel:1": {
    "status": "running",
    "updatedAt": 1700000000000,
    "cliSessionIds": {"claude-cli": "sess-running-1"}
  },
  "agent:test-agent:discord:channel:2": {
    "status": "done",
    "updatedAt": 1700000000000,
    "cliSessionIds": {"claude-cli": "sess-done-2"}
  },
  "agent:test-agent:discord:channel:3": {
    "status": "running",
    "updatedAt": 1700000000000,
    "cliSessionIds": {}
  }
}'

running=$(reap_list_running "$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json")
assert_contains "$running" "sess-running-1" "lists the running session with a cli id"
assert_contains "$running" "agent:test-agent:discord:channel:1" "includes channel key"
assert_contains "$running" "1700000000000" "includes updatedAt"
assert_not_contains "$running" "sess-done-2" "excludes done sessions"
assert_not_contains "$running" "channel:3" "excludes running sessions without a cli id"

# ─── reap_schema_drift (contract self-check) ─────────────
echo "  reap: schema_drift"

drift_dir="$SANDBOX/openclaw/agents/test-agent/sessions"; mkdir -p "$drift_dir"

# healthy schema => no drift
create_sessions_json "test-agent" '{
  "agent:test-agent:c1": {"status":"done","updatedAt":1700000000000,"cliSessionIds":{"claude-cli":"s1"}}
}'
result=$(reap_schema_drift "$drift_dir/sessions.json")
assert_empty "$result" "recognized schema is not drift"

# empty store => not drift (fresh agent)
create_sessions_json "test-agent" '{}'
result=$(reap_schema_drift "$drift_dir/sessions.json")
assert_empty "$result" "empty session store is not drift"

# missing file => not drift (nothing to read)
result=$(reap_schema_drift "$SANDBOX/openclaw/agents/test-agent/sessions/nope.json")
assert_empty "$result" "missing file is not drift"

# entries present but none expose our keys => DRIFT (schema changed under us)
create_sessions_json "test-agent" '{
  "agent:test-agent:c1": {"someNewShape":true,"foo":"bar"},
  "agent:test-agent:c2": {"baz":1}
}'
result=$(reap_schema_drift "$drift_dir/sessions.json")
assert_eq "DRIFT" "$result" "entries without status/cliSessionIds/updatedAt is DRIFT"

# unparseable json => DRIFT (can't read state at all)
echo 'this is not json {' > "$drift_dir/sessions.json"
result=$(reap_schema_drift "$drift_dir/sessions.json")
assert_eq "DRIFT" "$result" "unparseable sessions.json is DRIFT"

# ─── reap_find_agent_pid (mock pgrep + fake /proc) ───────
echo "  reap: find_agent_pid (safety-gated)"

mock_bin="$SANDBOX/bin"; mkdir -p "$mock_bin"
# Mock pgrep: echo the pids listed in REAP_TEST_PIDS regardless of pattern.
cat > "$mock_bin/pgrep" <<'MOCK'
#!/usr/bin/env bash
for p in ${REAP_TEST_PIDS:-}; do echo "$p"; done
MOCK
chmod +x "$mock_bin/pgrep"
export PATH="$mock_bin:$PATH"

# Fake procfs with environ files. Match is on env (OPENCLAW_MCP_SESSION_KEY +
# AGENT_ID), NOT cmdline — the CLI overwrites its title to bare "claude".
fake_proc="$SANDBOX/proc"; mkdir -p "$fake_proc/4242" "$fake_proc/9999"
printf 'PATH=/usr/bin\0OPENCLAW_MCP_AGENT_ID=test-agent\0OPENCLAW_MCP_SESSION_KEY=agent:test-agent:c1\0' > "$fake_proc/4242/environ"
printf 'PATH=/usr/bin\0OPENCLAW_MCP_AGENT_ID=other-agent\0OPENCLAW_MCP_SESSION_KEY=agent:other-agent:c1\0' > "$fake_proc/9999/environ"
export WARDEN_PROC="$fake_proc"

# pid 4242: agent + session key both match => matched
export REAP_TEST_PIDS="4242"
result=$(reap_find_agent_pid "agent:test-agent:c1" "test-agent")
assert_eq "4242" "$result" "returns pid when agent + session key match"

# pid 9999 belongs to a different agent => rejected (safety gate)
export REAP_TEST_PIDS="9999"
result=$(reap_find_agent_pid "agent:test-agent:c1" "test-agent")
assert_empty "$result" "rejects pid whose OPENCLAW_MCP_AGENT_ID is a different agent"

# right agent, WRONG session key => rejected (don't kill another session's child)
mkdir -p "$fake_proc/4243"
printf 'PATH=/usr/bin\0OPENCLAW_MCP_AGENT_ID=test-agent\0OPENCLAW_MCP_SESSION_KEY=agent:test-agent:OTHER\0' > "$fake_proc/4243/environ"
export REAP_TEST_PIDS="4243"
result=$(reap_find_agent_pid "agent:test-agent:c1" "test-agent")
assert_empty "$result" "rejects same-agent pid bound to a different session"

# a stray claude with no OPENCLAW env (e.g. a human's session) => rejected
mkdir -p "$fake_proc/7777"
printf 'PATH=/usr/bin\0HOME=/home/someone\0' > "$fake_proc/7777/environ"
export REAP_TEST_PIDS="7777"
result=$(reap_find_agent_pid "agent:test-agent:c1" "test-agent")
assert_empty "$result" "rejects stray claude with no OPENCLAW_MCP env"

# no candidate pids at all => empty
export REAP_TEST_PIDS=""
result=$(reap_find_agent_pid "agent:test-agent:c1" "test-agent")
assert_empty "$result" "empty when no candidate processes"
unset REAP_TEST_PIDS

unset WARDEN_PROC

# ─── reap_kill_pid (dry-run never kills) ─────────────────
echo "  reap: kill_pid dry-run"

WARDEN_DRY_RUN=1
out=$(reap_kill_pid 999999 1)
rc=$?
assert_eq "0" "$rc" "dry-run kill returns success"
assert_contains "$out" "dry-run" "dry-run kill announces intent, kills nothing"
WARDEN_DRY_RUN=0
