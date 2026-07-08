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
