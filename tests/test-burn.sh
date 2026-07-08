#!/usr/bin/env bash
# test-burn.sh — tests for lib/burn.sh (burn firewall ledger)

source "$WARDEN_HOME/lib/burn.sh"

echo "  burn: ledger sampling"

# ─── basic sampling ───────────────────────────────────────
setup_sandbox

create_sessions_json "test-agent" '{
  "agent:test-agent:main": {
    "status": "idle",
    "totalTokens": 1234,
    "numTurns": 7,
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-burn-1"}
  },
  "agent:test-agent:side": {
    "status": "idle",
    "totalTokens": 50,
    "numTurns": 2,
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-burn-2"}
  },
  "agent:test-agent:unbound": {
    "status": "idle",
    "totalTokens": 999,
    "numTurns": 3,
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {}
  }
}'

sjson="$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json"
burn_sample_agent "$sjson"
ledger="$WARDEN_HOME/state/burn/test-agent.jsonl"

assert_file_exists "$ledger" "ledger created on first sample"
assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "one record per bound channel (unbound skipped)"
assert_eq "1234" "$(jq -r 'select(.channel == "agent:test-agent:main") | .tokens' "$ledger")" "main channel tokens recorded"
assert_eq "7"    "$(jq -r 'select(.channel == "agent:test-agent:main") | .turns'  "$ledger")" "main channel turns recorded"
assert_eq "sess-burn-1" "$(jq -r 'select(.channel == "agent:test-agent:main") | .sid' "$ledger")" "session id recorded"
assert_not_empty "$(jq -r 'select(.channel == "agent:test-agent:main") | .ts' "$ledger")" "timestamp recorded"

# ─── dedup: unchanged counters append nothing ─────────────
burn_sample_agent "$sjson"
assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "unchanged counters do not append"

# ─── changed counter appends a new cumulative record ──────
create_sessions_json "test-agent" '{
  "agent:test-agent:main": {
    "status": "running",
    "totalTokens": 5678,
    "numTurns": 9,
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-burn-1"}
  },
  "agent:test-agent:side": {
    "status": "idle",
    "totalTokens": 50,
    "numTurns": 2,
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-burn-2"}
  }
}'
burn_sample_agent "$sjson"
assert_eq "3" "$(wc -l < "$ledger" | tr -d ' ')" "changed counter appends one record"
assert_eq "5678" "$(jq -r 'select(.channel == "agent:test-agent:main") | .tokens' "$ledger" | tail -1)" "latest record has new cumulative total"
assert_eq "50" "$(jq -r 'select(.channel == "agent:test-agent:side") | .tokens' "$ledger" | tail -1)" "side channel unchanged, not re-recorded"

# ─── disabled flag is a clean no-op ───────────────────────
setup_sandbox
create_sessions_json "test-agent" '{
  "agent:test-agent:main": {
    "status": "idle",
    "totalTokens": 100,
    "numTurns": 1,
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-burn-off"}
  }
}'
sjson="$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json"
WARDEN_BURN_ENABLED=0 burn_sample_agent "$sjson"
rc=$?
assert_exit_code "0" "$rc" "disabled sampling exits 0"
assert_file_not_exists "$WARDEN_HOME/state/burn/test-agent.jsonl" "disabled sampling writes nothing"

# ─── missing sessions.json is a clean no-op ───────────────
burn_sample_agent "$SANDBOX/openclaw/agents/ghost/sessions/sessions.json"
assert_exit_code "0" "$?" "missing sessions.json exits 0"

# ─── malformed sessions.json never fails the caller ───────
echo 'not json at all' > "$sjson"
burn_sample_agent "$sjson"
assert_exit_code "0" "$?" "malformed sessions.json exits 0"

echo "  burn: pruning"

# ─── prune drops only old records ─────────────────────────
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
old=$(( now - 10 * 86400 ))
cat > "$dir/test-agent.jsonl" <<EOF
{"ts":$old,"channel":"agent:test-agent:main","sid":"s1","tokens":10,"turns":1}
{"ts":$now,"channel":"agent:test-agent:main","sid":"s1","tokens":20,"turns":2}
EOF
burn_prune 8
assert_eq "1" "$(wc -l < "$dir/test-agent.jsonl" | tr -d ' ')" "prune drops records older than retention"
assert_eq "20" "$(jq -r '.tokens' "$dir/test-agent.jsonl")" "prune keeps recent records"

# ─── prune with no ledger dir is a clean no-op ────────────
rm -rf "$dir"
burn_prune 8
assert_exit_code "0" "$?" "prune without ledger dir exits 0"

teardown_sandbox

echo "  burn: report"

# ─── window consumption with growth and a rotation reset ──
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
# main: 100 -> 500 -> 900 (consumed 800), then rotation reset -> 50 (consumed +50) = 850
# side: single in-window record, no anchor -> consumed 0
# old:  only records before the window -> excluded entirely
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 7000 )),"channel":"agent:test-agent:old","sid":"s0","tokens":7777,"turns":70}
{"ts":$(( now - 3000 )),"channel":"agent:test-agent:main","sid":"s1","tokens":100,"turns":1}
{"ts":$(( now - 2000 )),"channel":"agent:test-agent:main","sid":"s1","tokens":500,"turns":3}
{"ts":$(( now - 1000 )),"channel":"agent:test-agent:main","sid":"s1","tokens":900,"turns":5}
{"ts":$(( now - 500  )),"channel":"agent:test-agent:main","sid":"s2","tokens":50,"turns":1}
{"ts":$(( now - 100  )),"channel":"agent:test-agent:side","sid":"s3","tokens":4000,"turns":9}
LEDGER

out=$(bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --json)
assert_eq "850" "$(echo "$out" | jq -r '.channels[] | select(.channel == "agent:test-agent:main") | .consumed')" "growth + rotation reset consumption"
assert_eq "0" "$(echo "$out" | jq -r '.channels[] | select(.channel == "agent:test-agent:side") | .consumed')" "single record without anchor consumes 0"
assert_empty "$(echo "$out" | jq -r '.channels[] | select(.channel == "agent:test-agent:old") | .channel')" "channels with no in-window records excluded"
assert_eq "850" "$(echo "$out" | jq -r '.total_consumed')" "total consumption sums channels"

# ─── anchor before window is used as the delta baseline ───
out=$(bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 1500 --json)
# window covers only ts=now-1000 (900) and ts=now-500 (50); anchor = 500 at now-2000
# consumed = (900-500) + 50 = 450
assert_eq "450" "$(echo "$out" | jq -r '.channels[] | select(.channel == "agent:test-agent:main") | .consumed')" "anchor record anchors the window delta"

# ─── table output + budget ────────────────────────────────
out=$(WARDEN_BURN_WINDOW_BUDGET=10000 bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600)
assert_contains "$out" "TOTAL" "table has totals row"
assert_contains "$out" "850" "table shows consumption"
assert_contains "$out" "8%" "budget percentage shown when budget set"

# ─── agent filter ─────────────────────────────────────────
cat > "$dir/other-agent.jsonl" <<LEDGER
{"ts":$(( now - 2000 )),"channel":"agent:other-agent:main","sid":"o1","tokens":10,"turns":1}
{"ts":$(( now - 1000 )),"channel":"agent:other-agent:main","sid":"o1","tokens":20,"turns":2}
LEDGER
out=$(bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --agent other-agent --json)
assert_eq "10" "$(echo "$out" | jq -r '.total_consumed')" "agent filter limits report"

# ─── empty state is friendly ──────────────────────────────
rm -rf "$dir"
out=$(bash "$REAL_WARDEN_HOME/bin/burn-report.sh" 2>&1)
rc=$?
assert_exit_code "0" "$rc" "no ledger exits 0"
assert_contains "$out" "No burn ledger yet" "no-ledger message shown"
out=$(bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --json)
assert_eq "[]" "$out" "no ledger --json emits empty array"

teardown_sandbox
