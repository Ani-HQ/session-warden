#!/usr/bin/env bash
# test-snapshot.sh — tests for bin/snapshot.sh
#
# snapshot.sh treats gbrain/claude as hard dependencies, so we run it with
# HOME pointed at the sandbox. That neutralizes lib/gbrain.sh's PATH prepend
# ($HOME/.bun/bin etc.) so our mock gbrain/claude win over any real binaries
# and no real brain is touched.

create_mock_claude

# Mock gbrain: log every call, consume stdin on `put`, report `get` as not-found
# so ensure_page creates anchors.
SNAP_CALLS="$SANDBOX/gbrain-calls.log"
: > "$SNAP_CALLS"
mock_bin="$SANDBOX/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/gbrain" <<MOCK
#!/usr/bin/env bash
echo "\$*" >> "$SNAP_CALLS"
case "\$1" in
  put) cat >/dev/null 2>&1; echo '{"status":"ok"}' ;;
  get) exit 1 ;;
  *)   echo ok ;;
esac
MOCK
chmod +x "$mock_bin/gbrain"

# Helper: a non-openclaw project dir with a UUID-named session jsonl
make_session() {  # $1=project-dirname $2=uuid $3=cwd $4=num_turn_pairs
  local dir="$SANDBOX/claude-projects/$1"
  mkdir -p "$dir"
  local f="$dir/$2.jsonl"
  : > "$f"
  local i
  for ((i=0; i<$4; i++)); do
    echo "{\"type\":\"user\",\"cwd\":\"$3\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"question $i in $3\"}]}}" >> "$f"
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"answer $i\"}]}}" >> "$f"
  done
  echo "$f"
}

run_snapshot() {
  HOME="$SANDBOX" PATH="$mock_bin:$PATH" "$WARDEN_HOME/bin/snapshot.sh" 2>/dev/null
}

echo "  snapshot: ingests a standalone session"

uuid_a="aaaaaaaa-1111-2222-3333-444444444444"
make_session "-home-user-myproject" "$uuid_a" "/home/user/myproject" 4 >/dev/null

: > "$SNAP_CALLS"
run_snapshot
calls=$(cat "$SNAP_CALLS")
date_str=$(date +%Y-%m-%d)
assert_contains "$calls" "put sessions/${date_str}/unknown-aaaaaaaa" "wrote snapshot page with sessions/ slug"
assert_contains "$calls" "performed_by" "created performed_by edge to agent"

state_file="$WARDEN_HOME/state/snapshot/state.json"
assert_file_exists "$state_file" "snapshot state.json created"
assert_contains "$(cat "$state_file" 2>/dev/null)" "$uuid_a" "state records the processed session"

echo "  snapshot: skips OpenClaw sessions"

uuid_oc="bbbbbbbb-1111-2222-3333-555555555555"
make_session "-home-user--openclaw-agents-kai" "$uuid_oc" "$HOME/.openclaw/agents/kai" 4 >/dev/null

: > "$SNAP_CALLS"
run_snapshot
calls=$(cat "$SNAP_CALLS")
assert_not_contains "$calls" "bbbbbbbb" "OpenClaw session (path *-openclaw-agents-*) not ingested"

echo "  snapshot: skips sessions below MIN_TURNS"

uuid_tiny="cccccccc-1111-2222-3333-666666666666"
make_session "-home-user-tinyproj" "$uuid_tiny" "/home/user/tinyproj" 1 >/dev/null  # 1 pair = 2 turns < 4

: > "$SNAP_CALLS"
run_snapshot
calls=$(cat "$SNAP_CALLS")
assert_not_contains "$calls" "cccccccc" "session with <MIN_TURNS turns not summarized"

echo "  snapshot: skips unmodified session on re-run"

# First session already ingested above; re-run without touching it -> no new put
: > "$SNAP_CALLS"
run_snapshot
calls=$(cat "$SNAP_CALLS")
assert_not_contains "$calls" "put sessions/${date_str}/unknown-aaaaaaaa" "unmodified session not re-ingested"

echo "  snapshot: graceful skip when gbrain unavailable"

# Run with a PATH that has no gbrain (HOME=sandbox so lib prepend can't find it
# either). Graceful degradation: skip cleanly with exit 0, log the skip.
HOME="$SANDBOX" PATH="/usr/bin:/bin" "$WARDEN_HOME/bin/snapshot.sh" >/dev/null 2>&1
assert_eq "0" "$?" "exits zero (clean skip) when gbrain is unavailable"
assert_contains "$(cat "$WARDEN_LOG_FILE")" "GBRAIN UNAVAILABLE — skipping gbrain work" "skip is logged"

echo "  snapshot: clean run with no sessions"

rm -rf "$SANDBOX/claude-projects/"*
: > "$SNAP_CALLS"
run_snapshot
assert_eq "0" "$?" "no sessions exits cleanly"
