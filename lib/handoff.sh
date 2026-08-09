#!/usr/bin/env bash
# handoff.sh — checkpoint live agent work before model switches / rate-guard rewrites.
#
# Public API:
#   handoff_agent <agent> <reason> [--force]
#     reason: model-switch | rate-guard-demote | rate-guard-restore | manual
#   handoff_detect_runtime <agent>  → echoes openclaw|hermes|unknown
#
# Exit codes:
#   0  handoff written (memory and/or gbrain)
#   1  hard failure / refused (empty extract without --force)
#   2  agent/runtime not found

: "${WARDEN_HOME:?WARDEN_HOME must be set}"

# shellcheck source=portable.sh
source "${WARDEN_HOME}/lib/portable.sh"
# shellcheck source=extract.sh
source "${WARDEN_HOME}/lib/extract.sh"
# shellcheck source=memory.sh
source "${WARDEN_HOME}/lib/memory.sh"
# shellcheck source=gbrain.sh
source "${WARDEN_HOME}/lib/gbrain.sh"

HANDOFF_TIMEOUT="${WARDEN_HANDOFF_TIMEOUT:-45}"
HANDOFF_GRACEFUL_TIMEOUT="${WARDEN_HANDOFF_GRACEFUL_TIMEOUT:-${WARDEN_GRACEFUL_TIMEOUT:-20}}"
HANDOFF_MIDTURN_WAIT="${WARDEN_HANDOFF_MIDTURN_WAIT:-60}"
HANDOFF_LOG="${WARDEN_LOG_FILE:-${WARDEN_HOME}/state/scan.log}"
OPENCLAW_HOME="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
CLAUDE_PROJECTS="${WARDEN_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
HERMES_BIN="${WARDEN_HERMES_BIN:-$HOME/hermes-agent/venv/bin/hermes}"

_handoff_log() {
  local line="[$(date -Iseconds)] HANDOFF: $*"
  echo "$line" >> "$HANDOFF_LOG" 2>/dev/null || true
  echo "$line" >&2
}

# memory.sh / extract callers expect `log`
log() {
  _handoff_log "$*"
}

handoff_detect_runtime() {
  local agent="$1"
  if [ -d "${OPENCLAW_HOME}/agents/${agent}" ]; then
    echo "openclaw"
    return 0
  fi
  if [ -d "${HOME}/.hermes-${agent}" ]; then
    echo "hermes"
    return 0
  fi
  echo "unknown"
  return 1
}

hermes_home_for() {
  echo "${HOME}/.hermes-$1"
}

# Wait until OpenClaw JSONL is not mid-turn (mtime older than 60s), up to HANDOFF_MIDTURN_WAIT.
_handoff_wait_openclaw_idle() {
  local jsonl="$1"
  [ -f "$jsonl" ] || return 0
  local waited=0 age
  while [ "$waited" -lt "$HANDOFF_MIDTURN_WAIT" ]; do
    age=$(( $(date +%s) - $(stat_mtime "$jsonl") ))
    if [ "$age" -ge 60 ]; then
      return 0
    fi
    _handoff_log "mid-turn detected on $(basename "$jsonl") (${age}s old) — waiting"
    sleep 5
    waited=$((waited + 5))
  done
  _handoff_log "WARN: still mid-turn after ${HANDOFF_MIDTURN_WAIT}s — best-effort extract"
  return 0
}

# Wait for Hermes gateway active_agents to drop to 0 (or timeout).
_handoff_wait_hermes_idle() {
  local hermes_home="$1"
  local gs="${hermes_home}/gateway_state.json"
  [ -f "$gs" ] || return 0
  local waited=0 active
  while [ "$waited" -lt 30 ]; do
    active=$(jq -r '.active_agents // 0' "$gs" 2>/dev/null || echo 0)
    if [ "${active:-0}" -le 0 ]; then
      return 0
    fi
    _handoff_log "hermes active_agents=${active} — waiting"
    sleep 3
    waited=$((waited + 3))
  done
  _handoff_log "WARN: hermes still busy after 30s — best-effort extract"
  return 0
}

_handoff_openclaw() {
  local agent="$1" reason="$2" force="$3"
  local sjson="${OPENCLAW_HOME}/agents/${agent}/sessions/sessions.json"
  local jsonl_base="${CLAUDE_PROJECTS}/-home-$(whoami)--openclaw-agents-${agent}"
  local captured=0 last_slug="" channel_key cli_session_id jsonl_file transcript_file mem_dir live_mem

  if [ ! -f "$sjson" ]; then
    _handoff_log "no sessions.json for openclaw agent $agent"
    [ "$force" = "1" ] && return 0
    return 1
  fi

  mkdir -p "${WARDEN_HOME}/state/handoff"
  transcript_file="${WARDEN_HOME}/state/handoff/${agent}.transcript"

  while IFS='|' read -r channel_key cli_session_id; do
    [ -z "$cli_session_id" ] && continue
    jsonl_file="${jsonl_base}/${cli_session_id}.jsonl"
    [ -f "$jsonl_file" ] || continue

    _handoff_wait_openclaw_idle "$jsonl_file"

    if [[ "$reason" =~ ^(model-switch|rate-guard-demote|rate-guard-restore)$ ]] \
       && command -v openclaw >/dev/null 2>&1; then
      _handoff_log "graceful flush $agent/$channel_key (${HANDOFF_GRACEFUL_TIMEOUT}s)"
      timeout "$HANDOFF_GRACEFUL_TIMEOUT" openclaw agent \
        --agent "$agent" \
        --channel last \
        --session-key "$channel_key" \
        --message "MODEL SWITCH / PROVIDER HANDOFF IMMINENT (${reason}): Your model chain is about to change. Write all pending work, decisions, and context to your memory files NOW. Be specific: paths, branches, what's left to do. Then acknowledge." \
        --timeout "$((HANDOFF_GRACEFUL_TIMEOUT - 5))" \
        --json >/dev/null 2>&1 \
        && _handoff_log "graceful flush ok for $agent/$channel_key" \
        || _handoff_log "graceful flush no-ack for $agent/$channel_key (non-fatal)"
    fi

    : > "$transcript_file"
    extract_session_transcript "$jsonl_file" > "$transcript_file" || true
    local tbytes
    tbytes=$(stat_size "$transcript_file")
    if [ "$tbytes" -lt 20 ]; then
      _handoff_log "empty extract for $agent/$channel_key"
      continue
    fi

    if write_session_memory "$agent" "$channel_key" "$cli_session_id" "$transcript_file"; then
      captured=$((captured + 1))
      mem_dir=$(claude_memory_dir "$agent")
      live_mem="${mem_dir}/session_$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g').md"
      local gb_out
      gb_out=$(gbrain_ingest_session "$agent" "$channel_key" "$cli_session_id" "$live_mem" "handoff" 2>&1 || true)
      echo "$gb_out" >> "$HANDOFF_LOG" 2>/dev/null || true
      last_slug=$(echo "$gb_out" | sed -n 's/^GBRAIN_SLUG=//p' | tail -1)
      # Persist slug for recovery / model-switch wake
      printf '%s\n' "$last_slug" > "${WARDEN_HOME}/state/handoff/${agent}.$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g').slug"
      _handoff_log "captured openclaw $agent/$channel_key → ${last_slug:-no-gbrain}"
    else
      _handoff_log "write_session_memory failed for $agent/$channel_key"
    fi
  done < <(jq -r '
    to_entries[] |
    select(.value.cliSessionIds["claude-cli"] // "" | length > 0) |
    "\(.key)|\(.value.cliSessionIds["claude-cli"])"
  ' "$sjson" 2>/dev/null)

  rm -f "$transcript_file"

  if [ "$captured" -eq 0 ]; then
    _handoff_log "no openclaw sessions captured for $agent"
    [ "$force" = "1" ] && return 0
    return 1
  fi
  return 0
}

_handoff_hermes() {
  local agent="$1" reason="$2" force="$3"
  local hermes_home session_id transcript_file channel_key handoff_file captured=0
  hermes_home=$(hermes_home_for "$agent")
  if [ ! -d "$hermes_home" ]; then
    _handoff_log "no hermes home at $hermes_home"
    return 2
  fi
  if [ ! -f "${hermes_home}/state.db" ]; then
    _handoff_log "no state.db for hermes $agent"
    [ "$force" = "1" ] && return 0
    return 1
  fi

  _handoff_wait_hermes_idle "$hermes_home"

  mkdir -p "${WARDEN_HOME}/state/handoff"
  transcript_file="${WARDEN_HOME}/state/handoff/${agent}.hermes.transcript"
  : > "$transcript_file"

  # Capture session id from stderr of extractor
  local sid_err
  sid_err=$(mktemp)
  if ! python3 "${WARDEN_HOME}/lib/extract-hermes.py" "$hermes_home" --print-session-id \
        > "$transcript_file" 2>"$sid_err"; then
    local rc=$?
    _handoff_log "hermes extract failed (rc=$rc) for $agent"
    rm -f "$sid_err" "$transcript_file"
    [ "$force" = "1" ] && return 0
    return 1
  fi
  session_id=$(head -1 "$sid_err" | tr -d '[:space:]')
  rm -f "$sid_err"
  [ -n "$session_id" ] || session_id="unknown"

  local tbytes
  tbytes=$(stat_size "$transcript_file")
  if [ "$tbytes" -lt 20 ]; then
    _handoff_log "empty hermes transcript for $agent"
    rm -f "$transcript_file"
    [ "$force" = "1" ] && return 0
    return 1
  fi

  channel_key="hermes:${agent}:main"
  if write_hermes_memory "$agent" "$channel_key" "$session_id" "$transcript_file" "$hermes_home"; then
    captured=1
    handoff_file="${hermes_home}/memories/HANDOFF.md"
    local gb_out last_slug
    gb_out=$(gbrain_ingest_session "$agent" "$channel_key" "$session_id" "$handoff_file" "handoff" 2>&1 || true)
    echo "$gb_out" >> "$HANDOFF_LOG" 2>/dev/null || true
    last_slug=$(echo "$gb_out" | sed -n 's/^GBRAIN_SLUG=//p' | tail -1)
    printf '%s\n' "$last_slug" > "${WARDEN_HOME}/state/handoff/${agent}.hermes.slug"
    # Also stash reason for wake messages
    printf 'reason=%s\nsession=%s\nslug=%s\n' "$reason" "$session_id" "$last_slug" \
      > "${WARDEN_HOME}/state/handoff/${agent}.meta"
    _handoff_log "captured hermes $agent session=${session_id} → ${last_slug:-no-gbrain}"
  else
    _handoff_log "write_hermes_memory failed for $agent"
  fi
  rm -f "$transcript_file"

  if [ "$captured" -eq 0 ]; then
    [ "$force" = "1" ] && return 0
    return 1
  fi
  return 0
}

# handoff_agent <agent> <reason> [--force]
handoff_agent() {
  local agent="$1" reason="${2:-manual}" force=0
  shift 2 || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$agent" ] || {
    _handoff_log "agent required"
    return 2
  }

  # Allow env override (rate-guard)
  if [ "${WARDEN_HANDOFF_FORCE:-0}" = "1" ]; then
    force=1
  fi

  local runtime
  runtime=$(handoff_detect_runtime "$agent") || true
  _handoff_log "start agent=$agent runtime=$runtime reason=$reason force=$force"

  case "$runtime" in
    openclaw) _handoff_openclaw "$agent" "$reason" "$force" ;;
    hermes)   _handoff_hermes "$agent" "$reason" "$force" ;;
    *)
      _handoff_log "unknown runtime for $agent"
      return 2
      ;;
  esac
}
