#!/usr/bin/env bash
# test-dream-cycle.sh — nightly GBrain maintenance, including scoped transcript ingest

DREAM_CALLS="$SANDBOX/gbrain-calls.log"
: > "$DREAM_CALLS"
mock_bin="$SANDBOX/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/gbrain" <<MOCK
#!/usr/bin/env bash
echo "\$*" >> "$DREAM_CALLS"
case "\$1" in
  put) cat >/dev/null 2>&1; echo '{"status":"ok"}' ;;
  get) exit 1 ;;
  transcripts)
    if [ "\${MOCK_NO_TRANSCRIPTS:-}" = "1" ]; then
      echo "unknown command" >&2
      exit 1
    fi
    if [ "\$2" = "status" ]; then
      echo "ok"
    else
      echo "sessions: 0 imported"
    fi
    ;;
  doctor) echo '{"status":"ok"}' ;;
  *) echo ok ;;
esac
MOCK
chmod +x "$mock_bin/gbrain"

mkdir -p "$SANDBOX/.hermes-carolyn"
export HOME="$SANDBOX"

run_dream() {
  : > "$DREAM_CALLS"
  : > "$WARDEN_LOG_FILE"
  HOME="$SANDBOX" PATH="$mock_bin:$PATH" \
    "$WARDEN_HOME/bin/dream-cycle.sh" 2>/dev/null
}

echo "  dream-cycle: ingests OpenClaw + Hermes with --since last, never --all"

run_dream
calls=$(cat "$DREAM_CALLS")
log=$(cat "$WARDEN_LOG_FILE")

assert_contains "$calls" "transcripts ingest --format openclaw --since last" \
  "ingests OpenClaw transcripts incrementally"
assert_contains "$calls" "transcripts ingest --format hermes --since last" \
  "ingests Hermes homes incrementally"
assert_contains "$calls" "$SANDBOX/openclaw/agents" \
  "OpenClaw ingest is scoped to the agent tree"
assert_contains "$calls" "$SANDBOX/.hermes-carolyn" \
  "Hermes ingest includes discovered ~/.hermes-* homes"
assert_not_contains "$calls" "ingest --all" \
  "does not pass ingest --all (would vacuum Claude Code history)"
assert_contains "$calls" "embed --stale" "still refreshes stale embeddings"
assert_contains "$calls" "doctor --json" "still runs doctor"
assert_contains "$log" "dream-cycle complete" "run finishes"

echo "  dream-cycle: WARDEN_GBRAIN_INGEST=0 skips ingest"

WARDEN_GBRAIN_INGEST=0 run_dream
calls=$(cat "$DREAM_CALLS")
log=$(cat "$WARDEN_LOG_FILE")
assert_not_contains "$calls" "transcripts ingest" "ingest skipped when disabled"
assert_contains "$calls" "embed --stale" "embed still runs when ingest is disabled"
assert_contains "$log" "transcripts ingest disabled" "disable is logged"
unset WARDEN_GBRAIN_INGEST

echo "  dream-cycle: older gbrain without transcripts is a clean skip"

MOCK_NO_TRANSCRIPTS=1 run_dream
calls=$(cat "$DREAM_CALLS")
log=$(cat "$WARDEN_LOG_FILE")
assert_not_contains "$calls" "transcripts ingest --format" \
  "no ingest attempted when transcripts command is missing"
assert_contains "$log" "transcripts ingest unavailable" "old CLI skip is logged"
assert_contains "$calls" "embed --stale" "embed still runs on old CLI"
unset MOCK_NO_TRANSCRIPTS
