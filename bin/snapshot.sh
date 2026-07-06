#!/usr/bin/env bash
# snapshot.sh — capture standalone (non-OpenClaw) Claude Code sessions into GBrain.
#
# Absorbs the old gbrain-snapshotter as a first-class warden module. Every run:
#   1. Scan ~/.claude/projects/**/*.jsonl modified in the last N minutes
#   2. Skip OpenClaw agent sessions (path matches *-openclaw-agents-*) — those
#      are handled by context-sync (live) and summarize (rotation)
#   3. For each qualifying session: extract transcript (lib/extract.sh),
#      summarize via Haiku, write a typed+linked GBrain page (lib/gbrain.sh)
#   4. Track {last_mtime, last_turn_count} per session in state/snapshot/state.json;
#      re-summarize only when mtime changed AND >= MIN_TURNS new turns since the
#      last snapshot (cheap no-op on most runs)
#
# GBrain degrades gracefully: if the CLI is missing or the brain isn't
# answering (gbrain_healthy), the run is skipped cleanly with exit 0 — a down
# brain must never turn a scheduled snapshot into an error.
#
# Runs every WARDEN_SNAPSHOT_INTERVAL_MINUTES via cron or systemd timer.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/extract.sh"
source "${WARDEN_HOME}/lib/gbrain.sh"
source "${WARDEN_HOME}/lib/agent-attribution.sh"

LOG_FILE="${WARDEN_LOG_FILE}"
log() { echo "[$(date -Iseconds)] SNAPSHOT: $*" >> "$LOG_FILE"; }

# ─── Config ───────────────────────────────────────────────
WINDOW_MINUTES="${WARDEN_SNAPSHOT_WINDOW_MINUTES:-120}"
MIN_TURNS="${WARDEN_SNAPSHOT_MIN_TURNS:-4}"
MAX_TURNS="${WARDEN_SNAPSHOT_MAX_TURNS:-40}"
MODEL="${WARDEN_SUMMARY_MODEL:-claude-haiku-4-5-20251001}"
CLAUDE_PROJECTS="${WARDEN_CLAUDE_PROJECTS:-$HOME/.claude/projects}"

# ─── Dependencies ─────────────────────────────────────────
# GBrain is the whole point of this module, so probe it FIRST and skip the run
# cleanly when it's down — never error a scheduled unit over a sick brain.
if ! gbrain_healthy; then
  log "GBRAIN UNAVAILABLE — skipping gbrain work"
  exit 0
fi
for cmd in claude jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: required command '$cmd' not found on PATH — aborting"
    echo "snapshot: required command '$cmd' not found" >&2
    exit 1
  fi
done

# ─── State ────────────────────────────────────────────────
STATE_DIR="${WARDEN_HOME}/state/snapshot"
STATE_FILE="${STATE_DIR}/state.json"
mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

get_state_field() {  # $1=session_id $2=field (last_mtime|last_turn_count)
  jq -r --arg id "$1" --arg f "$2" '.[$id][$f] // "0"' "$STATE_FILE" 2>/dev/null || echo "0"
}
set_state() {  # $1=session_id $2=mtime $3=turn_count
  local tmp
  tmp=$(mktemp)
  jq --arg id "$1" --arg mt "$2" --argjson tc "$3" \
    '.[$id] = {last_mtime: $mt, last_turn_count: $tc}' "$STATE_FILE" > "$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

count_turns() {  # $1=jsonl
  jq -c 'select(.type == "user" or .type == "assistant")' "$1" 2>/dev/null | wc -l
}
session_cwd() {  # $1=jsonl
  jq -r 'select(.cwd) | .cwd' "$1" 2>/dev/null | head -1
}

summarize() {  # transcript on stdin -> summary on stdout
  local prompt
  prompt=$(cat <<'PROMPT_EOF'
You are summarizing a Claude Code coding session for persistent memory (GBrain). Produce a structured summary that another session can use to pick up where this one left off.

Output ONLY the summary, no preamble. Format:

## What was worked on
One paragraph naming the feature/bug/task and which files/services were touched.

## Decisions made
Bullet list of architectural or implementation decisions. Be specific.

## Files changed or created
Bullet list with brief note on what each change does.

## Commands run
Only notable ones: deploys, migrations, tests. Skip routine ls/cd.

## Open threads
What's unfinished, what failed, what needs verification next session.

## Key context to remember
Gotchas, non-obvious findings, API quirks, credentials/env vars used.

## Entities
Wikilinks to the named projects, repos, companies, or people this session touched, for the knowledge graph. One per line, [[type/slug]] form with a lowercase-kebab slug. Allowed types: project, company, person, repo. e.g. [[project/session-warden]], [[company/acme]], [[repo/billing-service]]. Only real named entities, max 8. Omit if none.

Keep it under 400 words. Skip sections that don't apply.
PROMPT_EOF
)
  claude -p --model "$MODEL" "$prompt" 2>>"$LOG_FILE"
}

# ─── Concurrency guard ────────────────────────────────────
LOCKFILE="${STATE_DIR}/snapshot.lock"
exec 195>"$LOCKFILE"
if ! flock -n 195; then
  log "another snapshot run is in progress — skipping"
  exit 0
fi

log "=== snapshot run started (window=${WINDOW_MINUTES}m) ==="

if [ ! -d "$CLAUDE_PROJECTS" ]; then
  log "claude projects dir not found ($CLAUDE_PROJECTS) — nothing to do"
  exit 0
fi

active=$(find "$CLAUDE_PROJECTS" -type f -name "*.jsonl" -mmin "-${WINDOW_MINUTES}" 2>/dev/null)
if [ -z "$active" ]; then
  log "no sessions modified in last ${WINDOW_MINUTES}m"
  log "=== snapshot run complete ==="
  exit 0
fi

processed=0 skipped=0 failed=0

while IFS= read -r jsonl; do
  [ -z "$jsonl" ] && continue

  # OpenClaw sessions are handled by context-sync + rotation — never here.
  case "$jsonl" in
    *-openclaw-agents-*) skipped=$((skipped + 1)); continue ;;
  esac

  session_id=$(basename "$jsonl" .jsonl)
  # Only real Claude Code session files (UUID-named).
  if ! [[ "$session_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
    continue
  fi

  current_mtime=$(stat -c %Y "$jsonl" 2>/dev/null || stat -f %m "$jsonl" 2>/dev/null || echo 0)
  last_mtime=$(get_state_field "$session_id" "last_mtime")
  last_turns=$(get_state_field "$session_id" "last_turn_count")

  # Unchanged since last look — cheap skip, no jq turn count.
  if [ "$current_mtime" = "$last_mtime" ]; then
    skipped=$((skipped + 1)); continue
  fi

  turns=$(count_turns "$jsonl")
  new_turns=$((turns - last_turns))

  # Re-summarize only if at least MIN_TURNS new turns accrued since last snapshot.
  # (For a never-seen session last_turns=0, so this is the absolute MIN_TURNS gate.)
  if [ "$new_turns" -lt "$MIN_TURNS" ]; then
    log "skip $session_id: only $new_turns new turns (< $MIN_TURNS)"
    # Record mtime so we don't recount until the file changes again; keep the
    # turn count anchored at the last summarized value so deltas accumulate.
    set_state "$session_id" "$current_mtime" "$last_turns"
    skipped=$((skipped + 1)); continue
  fi

  cwd=$(session_cwd "$jsonl")
  agent=$(agent_from_cwd "$cwd")
  log "processing $session_id ($agent, $turns turns, +$new_turns, cwd=$cwd)"

  # Extract transcript via the shared lib, bounded to a sane size for the
  # summarizer (MAX_TURNS as an approximate line budget — extract emits a few
  # lines per turn including tool actions).
  transcript=$(extract_session_transcript "$jsonl" 2>/dev/null | tail -n "$((MAX_TURNS * 4))")
  if [ -z "$transcript" ]; then
    log "  skip: empty transcript after extraction"
    set_state "$session_id" "$current_mtime" "$turns"
    skipped=$((skipped + 1)); continue
  fi

  summary_file=$(mktemp "${STATE_DIR}/summary-XXXXXX")
  printf '%s\n\n--- SESSION TRANSCRIPT ---\n%s\n' \
    "(summarizing session ${session_id})" "$transcript" | summarize > "$summary_file"

  if [ ! -s "$summary_file" ]; then
    log "  FAIL: summarizer returned empty for $session_id"
    rm -f "$summary_file"
    failed=$((failed + 1)); continue
  fi

  if gbrain_ingest_snapshot "$agent" "$session_id" "$summary_file" "$cwd" "$turns" >> "$LOG_FILE" 2>&1; then
    log "  wrote snapshot for $session_id ($agent)"
    set_state "$session_id" "$current_mtime" "$turns"
    processed=$((processed + 1))
  else
    log "  FAIL: gbrain ingest failed for $session_id"
    failed=$((failed + 1))
  fi
  rm -f "$summary_file"

done <<< "$active"

log "=== snapshot run complete: $processed processed, $skipped skipped, $failed failed ==="
flock -u 195
