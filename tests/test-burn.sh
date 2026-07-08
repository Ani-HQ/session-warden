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

echo "  burn: detection"

# ─── loop signature detection ─────────────────────────────
setup_sandbox
loop_jsonl=""
for _ in 1 2 3 4 5 6; do
  loop_jsonl="${loop_jsonl}{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"npm test\"}}]}}
"
done
f=$(create_mock_jsonl "test-agent" "sess-loop" "$loop_jsonl")
assert_eq "LOOP" "$(burn_detect_loop "$f" 6)" "six identical tool calls detected as loop"

varied_jsonl='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'
f=$(create_mock_jsonl "test-agent" "sess-varied" "$varied_jsonl")
burn_detect_loop "$f" 6 >/dev/null
assert_exit_code "1" "$?" "varied tool calls not a loop"

short_jsonl='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'
f=$(create_mock_jsonl "test-agent" "sess-short" "$short_jsonl")
burn_detect_loop "$f" 6 >/dev/null
assert_exit_code "1" "$?" "fewer than N calls not a loop"

burn_detect_loop "/nonexistent/x.jsonl" 6 >/dev/null
assert_exit_code "1" "$?" "missing jsonl not a loop"

# ─── budget + warn detection ──────────────────────────────
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 3000 )),"channel":"agent:test-agent:main","sid":"sess-budget","tokens":100,"turns":1}
{"ts":$(( now - 1000 )),"channel":"agent:test-agent:main","sid":"sess-budget","tokens":900,"turns":5}
LEDGER
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"idle","totalTokens":900,"numTurns":5,"updatedAt":'"$(now_ms)"',"cliSessionIds":{"claude-cli":"sess-budget"}}}'
sjson="$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json"

# consumed 800 of budget 1000 = 80% >= 70% -> WARN
WARDEN_BURN_WINDOW_BUDGET=1000 burn_check_agent "$sjson"
events="$dir/events.jsonl"
assert_file_exists "$events" "warn event written"
assert_eq "WARN" "$(jq -r '.kind' "$events" | tail -1)" "80% of budget emits WARN"

# consumed 800 of budget 700 -> 114% -> BUDGET
rm -f "$events" "$dir"/.alert-*
WARDEN_BURN_WINDOW_BUDGET=700 burn_check_agent "$sjson"
assert_eq "BUDGET" "$(jq -r '.kind' "$events" | tail -1)" "over budget emits BUDGET"

# budget 0 (default): no budget events
rm -f "$events" "$dir"/.alert-*
burn_check_agent "$sjson"
if [ -f "$events" ]; then
  assert_empty "$(jq -r 'select(.kind == "WARN" or .kind == "BUDGET") | .kind' "$events")" "no budget events when budget unset"
else
  assert_file_not_exists "$events" "no budget events when budget unset"
fi

# ─── spike detection (recent 5-min consumption) ───────────
rm -f "$events" "$dir"/.alert-*
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 200 )),"channel":"agent:test-agent:main","sid":"sess-budget","tokens":1000,"turns":1}
{"ts":$(( now - 100 )),"channel":"agent:test-agent:main","sid":"sess-budget","tokens":9000,"turns":2}
LEDGER
WARDEN_BURN_SPIKE_TOKENS_5M=5000 burn_check_agent "$sjson"
assert_eq "BURN" "$(jq -r 'select(.kind == "BURN") | .kind' "$events" | tail -1)" "5-minute spike emits BURN"

# ─── alert throttling ─────────────────────────────────────
count_before=$(jq -r 'select(.kind == "BURN")' "$events" | grep -c kind)
WARDEN_BURN_SPIKE_TOKENS_5M=5000 burn_check_agent "$sjson"
count_after=$(jq -r 'select(.kind == "BURN")' "$events" | grep -c kind)
assert_eq "$count_before" "$count_after" "second check within cooldown emits nothing"

rm -f "$dir"/.alert-*
WARDEN_BURN_SPIKE_TOKENS_5M=5000 WARDEN_BURN_ALERT_COOLDOWN_SECONDS=0 burn_check_agent "$sjson"
count_final=$(jq -r 'select(.kind == "BURN")' "$events" | grep -c kind)
assert_gt "$count_final" "$count_after" "cleared throttle emits again"

# ─── loop detection end-to-end via burn_check_agent ───────
rm -f "$events" "$dir"/.alert-*
loop_jsonl=""
for _ in 1 2 3 4 5 6 7 8; do
  loop_jsonl="${loop_jsonl}{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"retry me\"}}]}}
"
done
create_mock_jsonl "test-agent" "sess-budget" "$loop_jsonl" >/dev/null
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 100 )),"channel":"agent:test-agent:main","sid":"sess-budget","tokens":500,"turns":3}
{"ts":$(( now - 50 )),"channel":"agent:test-agent:main","sid":"sess-budget","tokens":600,"turns":4}
LEDGER
burn_check_agent "$sjson"
assert_eq "LOOP" "$(jq -r 'select(.kind == "LOOP") | .kind' "$events" | tail -1)" "retry loop emits LOOP via check"

# ─── disabled flag skips checks ───────────────────────────
rm -f "$events" "$dir"/.alert-*
WARDEN_BURN_ENABLED=0 WARDEN_BURN_WINDOW_BUDGET=100 burn_check_agent "$sjson"
assert_file_not_exists "$events" "disabled firewall emits no events"

teardown_sandbox

echo "  burn: enforcement"

# ─── pure verdict ─────────────────────────────────────────
setup_sandbox
assert_eq ""      "$(burn_enforce_verdict 0 BUDGET running)" "enforce off: budget -> nothing"
assert_eq ""      "$(burn_enforce_verdict 0 LOOP running)"   "enforce off: loop -> nothing"
assert_eq "PAUSE" "$(burn_enforce_verdict 1 BUDGET -)"       "enforce on: budget -> pause"
assert_eq "KILL"  "$(burn_enforce_verdict 1 LOOP running)"   "enforce on: running loop -> kill"
assert_eq ""      "$(burn_enforce_verdict 1 LOOP idle)"      "enforce on: idle loop -> nothing"
assert_eq ""      "$(burn_enforce_verdict 1 BURN running)"   "spike alone never enforces"

# ─── pause marker lifecycle ───────────────────────────────
now=$(date +%s)
burn_pause_agent "test-agent" $(( now + 60 ))
burn_is_paused "test-agent"
assert_exit_code "0" "$?" "fresh pause marker reports paused"
burn_pause_agent "test-agent" $(( now - 5 ))
burn_is_paused "test-agent"
assert_exit_code "1" "$?" "expired pause marker reports not paused"
assert_file_not_exists "$(burn_pause_file test-agent)" "expired marker is cleared"

# ─── budget breach with enforce=1 pauses the agent ────────
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 3000 )),"channel":"agent:test-agent:main","sid":"sess-enf","tokens":100,"turns":1}
{"ts":$(( now - 1000 )),"channel":"agent:test-agent:main","sid":"sess-enf","tokens":900,"turns":5}
LEDGER
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"idle","totalTokens":900,"numTurns":5,"updatedAt":'"$(now_ms)"',"cliSessionIds":{"claude-cli":"sess-enf"}}}'
sjson="$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json"

WARDEN_BURN_ENFORCE=1 WARDEN_BURN_WINDOW_BUDGET=700 WARDEN_DRY_RUN=1 burn_check_agent "$sjson"
burn_is_paused "test-agent"
assert_exit_code "0" "$?" "budget breach with enforce pauses agent"
assert_eq "PAUSE" "$(jq -r 'select(.kind == "PAUSE") | .kind' "$dir/events.jsonl" | tail -1)" "PAUSE event recorded"

# enforce=0: same breach, no pause
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 3000 )),"channel":"agent:test-agent:main","sid":"sess-enf","tokens":100,"turns":1}
{"ts":$(( now - 1000 )),"channel":"agent:test-agent:main","sid":"sess-enf","tokens":900,"turns":5}
LEDGER
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"idle","totalTokens":900,"numTurns":5,"updatedAt":'"$(now_ms)"',"cliSessionIds":{"claude-cli":"sess-enf"}}}'
sjson="$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json"
WARDEN_BURN_WINDOW_BUDGET=700 burn_check_agent "$sjson"
burn_is_paused "test-agent"
assert_exit_code "1" "$?" "default warn-only never pauses"

# ─── loop-kill: env-matched pid, dry-run, kill cooldown ───
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)

# mock pgrep so reap_find_agent_pid sees one claude pid; mock procfs environ
mkdir -p "$SANDBOX/bin" "$SANDBOX/proc/4242"
cat > "$SANDBOX/bin/pgrep" <<'MOCK'
#!/usr/bin/env bash
echo 4242
MOCK
chmod +x "$SANDBOX/bin/pgrep"
export PATH="$SANDBOX/bin:$PATH"
printf 'OPENCLAW_MCP_SESSION_KEY=agent:test-agent:main\0OPENCLAW_MCP_AGENT_ID=test-agent\0' > "$SANDBOX/proc/4242/environ"
export WARDEN_PROC="$SANDBOX/proc"

loop_jsonl=""
for _ in 1 2 3 4 5 6 7 8; do
  loop_jsonl="${loop_jsonl}{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"retry me\"}}]}}
"
done
create_mock_jsonl "test-agent" "sess-kill" "$loop_jsonl" >/dev/null
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 100 )),"channel":"agent:test-agent:main","sid":"sess-kill","tokens":500,"turns":3}
{"ts":$(( now - 50 )),"channel":"agent:test-agent:main","sid":"sess-kill","tokens":700,"turns":4}
LEDGER
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"running","totalTokens":700,"numTurns":4,"updatedAt":'"$(now_ms)"',"cliSessionIds":{"claude-cli":"sess-kill"}}}'
sjson="$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json"

WARDEN_BURN_ENFORCE=1 WARDEN_DRY_RUN=1 burn_check_agent "$sjson"
assert_eq "LOOPKILL" "$(jq -r 'select(.kind == "LOOPKILL") | .kind' "$dir/events.jsonl" | tail -1)" "running loop with enforce kills (dry-run)"

# second check inside kill cooldown: no second LOOPKILL
kills_before=$(jq -r 'select(.kind == "LOOPKILL")' "$dir/events.jsonl" | grep -c kind)
rm -f "$dir"/.alert-*   # clear alert throttle; kill cooldown must gate on its own
WARDEN_BURN_ENFORCE=1 WARDEN_DRY_RUN=1 burn_check_agent "$sjson"
kills_after=$(jq -r 'select(.kind == "LOOPKILL")' "$dir/events.jsonl" | grep -c kind)
assert_eq "$kills_before" "$kills_after" "kill cooldown prevents repeat kills"

# idle status: loop signature alerts but never kills
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
mkdir -p "$SANDBOX/bin" "$SANDBOX/proc/4242"
cat > "$SANDBOX/bin/pgrep" <<'MOCK'
#!/usr/bin/env bash
echo 4242
MOCK
chmod +x "$SANDBOX/bin/pgrep"
export PATH="$SANDBOX/bin:$PATH"
printf 'OPENCLAW_MCP_SESSION_KEY=agent:test-agent:main\0OPENCLAW_MCP_AGENT_ID=test-agent\0' > "$SANDBOX/proc/4242/environ"
export WARDEN_PROC="$SANDBOX/proc"
create_mock_jsonl "test-agent" "sess-kill" "$loop_jsonl" >/dev/null
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 100 )),"channel":"agent:test-agent:main","sid":"sess-kill","tokens":500,"turns":3}
{"ts":$(( now - 50 )),"channel":"agent:test-agent:main","sid":"sess-kill","tokens":700,"turns":4}
LEDGER
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"idle","totalTokens":700,"numTurns":4,"updatedAt":'"$(now_ms)"',"cliSessionIds":{"claude-cli":"sess-kill"}}}'
sjson="$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json"
WARDEN_BURN_ENFORCE=1 WARDEN_DRY_RUN=1 burn_check_agent "$sjson"
if [ -f "$dir/events.jsonl" ]; then
  assert_empty "$(jq -r 'select(.kind == "LOOPKILL") | .kind' "$dir/events.jsonl")" "idle loop signature never kills"
else
  assert_file_not_exists "$dir/events.jsonl.never" "idle loop signature never kills"
fi

unset WARDEN_PROC

teardown_sandbox

echo "  burn: daily digest"

# ─── digest fires once per day, stores summary in marker ──
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 4000 )),"channel":"agent:test-agent:main","sid":"sd","tokens":100,"turns":1}
{"ts":$(( now - 2000 )),"channel":"agent:test-agent:main","sid":"sd","tokens":600,"turns":4}
LEDGER
cat > "$dir/events.jsonl" <<LEDGER
{"ts":$(( now - 3000 )),"agent":"test-agent","channel":"agent:test-agent:main","kind":"BURN","detail":"x"}
LEDGER

WARDEN_BURN_DIGEST_HOUR=0 burn_daily_digest
marker="$dir/.digest-$(date +%Y-%m-%d)"
assert_file_exists "$marker" "digest marker written"
assert_contains "$(cat "$marker")" "test-agent: 500 tokens" "digest summary has per-agent consumption"
assert_contains "$(cat "$marker")" "BURN: 1" "digest summary has event counts"

mtime_before=$(stat_mtime "$marker")
sleep 1
WARDEN_BURN_DIGEST_HOUR=0 burn_daily_digest
assert_eq "$mtime_before" "$(stat_mtime "$marker")" "second call same day is a no-op"

# ─── blank hour disables; future hour defers ──────────────
rm -f "$marker"
WARDEN_BURN_DIGEST_HOUR="" burn_daily_digest
assert_file_not_exists "$marker" "blank digest hour disables digest"

hour_now=$(( 10#$(date +%H) ))
if [ "$hour_now" -lt 23 ]; then
  WARDEN_BURN_DIGEST_HOUR=23 burn_daily_digest
  assert_file_not_exists "$marker" "digest defers until configured hour"
else
  skip_test "digest defer case (host clock at 23:00)"
fi

teardown_sandbox

echo "  burn: review fixes"

# ─── corrupt ledger line is tolerated, not fatal ──────────
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 2000 )),"channel":"agent:test-agent:main","sid":"s1","tokens":100,"turns":1}
{"ts":$(( now - 1500 )),"channel":"agent:test-agent:main","sid":"s1","tokens":300,"tur
{"ts":$(( now - 1000 )),"channel":"agent:test-agent:main","sid":"s1","tokens":600,"turns":3}
LEDGER
out=$(burn_channel_report "$dir/test-agent.jsonl" $(( now - 3600 )))
assert_not_empty "$out" "corrupt line does not blank the report"
assert_eq "500" "$(echo "$out" | awk -F'|' '{print $2}')" "consumption computed from surviving records"

# ─── sid change counts as rotation even when tokens rise ──
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 3000 )),"channel":"agent:test-agent:main","sid":"s1","tokens":100,"turns":1}
{"ts":$(( now - 2000 )),"channel":"agent:test-agent:main","sid":"s1","tokens":400,"turns":3}
{"ts":$(( now - 1000 )),"channel":"agent:test-agent:main","sid":"s2","tokens":550,"turns":2}
LEDGER
out=$(burn_channel_report "$dir/test-agent.jsonl" $(( now - 3600 )))
# s1: 100->400 = 300, rotation to s2 with higher count: +550 = 850 (not 150)
assert_eq "850" "$(echo "$out" | awk -F'|' '{print $2}')" "sid change with rising tokens counts new session total"

# ─── prune self-heals corrupt lines ───────────────────────
cat > "$dir/test-agent.jsonl" <<LEDGER
not json
{"ts":$now,"channel":"agent:test-agent:main","sid":"s1","tokens":20,"turns":2}
LEDGER
burn_prune 8
assert_eq "1" "$(wc -l < "$dir/test-agent.jsonl" | tr -d ' ')" "prune drops corrupt lines"

# ─── stale loop signature never alerts or kills ───────────
setup_sandbox
dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
mkdir -p "$SANDBOX/bin" "$SANDBOX/proc/4242"
cat > "$SANDBOX/bin/pgrep" <<'MOCK'
#!/usr/bin/env bash
echo 4242
MOCK
chmod +x "$SANDBOX/bin/pgrep"
export PATH="$SANDBOX/bin:$PATH"
printf 'OPENCLAW_MCP_SESSION_KEY=agent:test-agent:main\0OPENCLAW_MCP_AGENT_ID=test-agent\0' > "$SANDBOX/proc/4242/environ"
export WARDEN_PROC="$SANDBOX/proc"

loop_jsonl=""
for _ in 1 2 3 4 5 6 7 8; do
  loop_jsonl="${loop_jsonl}{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"retry me\"}}]}}
"
done
f=$(create_mock_jsonl "test-agent" "sess-stale" "$loop_jsonl")
touch -t 202601010000 "$f"   # signature is old news: transcript not being written
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 100 )),"channel":"agent:test-agent:main","sid":"sess-stale","tokens":500,"turns":3}
{"ts":$(( now - 50 )),"channel":"agent:test-agent:main","sid":"sess-stale","tokens":600,"turns":4}
LEDGER
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"running","totalTokens":600,"numTurns":4,"updatedAt":'"$(now_ms)"',"cliSessionIds":{"claude-cli":"sess-stale"}}}'
sjson="$SANDBOX/openclaw/agents/test-agent/sessions/sessions.json"
WARDEN_BURN_ENFORCE=1 WARDEN_DRY_RUN=1 burn_check_agent "$sjson"
if [ -f "$dir/events.jsonl" ]; then
  assert_empty "$(jq -r 'select(.kind == "LOOP" or .kind == "LOOPKILL") | .kind' "$dir/events.jsonl")" "stale transcript never fires LOOP"
else
  assert_file_not_exists "$dir/events.jsonl.never" "stale transcript never fires LOOP"
fi

# ─── sid mismatch (rotation lag) never kills ──────────────
rm -f "$dir"/events.jsonl "$dir"/.alert-* "$dir"/.killed-*
create_mock_jsonl "test-agent" "sess-old" "$loop_jsonl" >/dev/null   # fresh mtime, loop signature
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 100 )),"channel":"agent:test-agent:main","sid":"sess-old","tokens":500,"turns":3}
{"ts":$(( now - 50 )),"channel":"agent:test-agent:main","sid":"sess-old","tokens":600,"turns":4}
LEDGER
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"running","totalTokens":50,"numTurns":1,"updatedAt":'"$(now_ms)"',"cliSessionIds":{"claude-cli":"sess-new"}}}'
WARDEN_BURN_ENFORCE=1 WARDEN_DRY_RUN=1 burn_check_agent "$sjson"
if [ -f "$dir/events.jsonl" ]; then
  assert_empty "$(jq -r 'select(.kind == "LOOPKILL") | .kind' "$dir/events.jsonl")" "evidence from a rotated-away sid never kills the new session"
else
  assert_file_not_exists "$dir/events.jsonl.never" "evidence from a rotated-away sid never kills the new session"
fi

# ─── pause never touches a running or unknown session ─────
rm -f "$dir"/events.jsonl "$dir"/.alert-* "$dir"/.killed-*
# running status, stale-looking jsonl: must be skipped
f=$(create_mock_jsonl "test-agent" "sess-run" "")
touch -t 202601010000 "$f"
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"running","totalTokens":10,"numTurns":1,"updatedAt":0,"cliSessionIds":{"claude-cli":"sess-run"}}}'
WARDEN_DRY_RUN=1 burn_enforce_pause "$sjson" "test-agent"
if [ -f "$dir/events.jsonl" ]; then
  assert_empty "$(jq -r 'select(.kind == "PAUSEKILL") | .kind' "$dir/events.jsonl")" "pause never kills a running session"
else
  assert_file_not_exists "$dir/events.jsonl.never" "pause never kills a running session"
fi
# missing jsonl: must be skipped
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"idle","totalTokens":10,"numTurns":1,"updatedAt":0,"cliSessionIds":{"claude-cli":"sess-ghost"}}}'
WARDEN_DRY_RUN=1 burn_enforce_pause "$sjson" "test-agent"
if [ -f "$dir/events.jsonl" ]; then
  assert_empty "$(jq -r 'select(.kind == "PAUSEKILL") | .kind' "$dir/events.jsonl")" "pause never kills a session with no transcript"
else
  assert_file_not_exists "$dir/events.jsonl.never" "pause never kills a session with no transcript"
fi
# idle + stale on both signals: killed (dry-run)
f=$(create_mock_jsonl "test-agent" "sess-idle" "")
touch -t 202601010000 "$f"
create_sessions_json "test-agent" '{"agent:test-agent:main":{"status":"idle","totalTokens":10,"numTurns":1,"updatedAt":1000,"cliSessionIds":{"claude-cli":"sess-idle"}}}'
printf 'OPENCLAW_MCP_SESSION_KEY=agent:test-agent:main\0OPENCLAW_MCP_AGENT_ID=test-agent\0' > "$SANDBOX/proc/4242/environ"
WARDEN_DRY_RUN=1 burn_enforce_pause "$sjson" "test-agent"
assert_eq "PAUSEKILL" "$(jq -r 'select(.kind == "PAUSEKILL") | .kind' "$dir/events.jsonl" | tail -1)" "pause stops a truly idle session"

unset WARDEN_PROC
teardown_sandbox
