#!/usr/bin/env bash
# reap-stalls.sh — independent backstop that kills stalled agent turns.
#
# Runs on its own fast cron tick (every ~30s), separate from scan.sh. Reads
# gateway state from disk + /proc only (no RPC), so it keeps working even when
# the gateway's own event loop is wedged or the in-process watchdog patch has
# been wiped by an `npm update`. See lib/reap.sh for the detection rationale.
#
# Pipeline per stuck turn:
#   1. detect  — status=="running" on disk + live agent CLI pid + no progress
#                past WARDEN_STALL_HARD_CAP_SECONDS
#   2. kill    — SIGTERM -> SIGKILL the wedged CLI child (kill(2), independent)
#   3. recover — mark the session failed on disk + enqueue a pending-recovery so
#                scan.sh delivers the contextual "you're back" message
#   4. escalate— if a session is STILL stuck on the next tick after we killed it,
#                the gateway isn't reacting to the child's death -> restart it
#                (shared cooldown with scan.sh)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

source "${WARDEN_HOME}/config/thresholds.env"
export WARDEN_DRY_RUN
source "${WARDEN_HOME}/lib/detect.sh"   # agent_from_sessions_path
source "${WARDEN_HOME}/lib/reap.sh"
source "${WARDEN_HOME}/lib/notify.sh"

# ─── Config knobs (with defaults) ────────────────────────
REAP_ENABLED="${WARDEN_REAP_ENABLED:-1}"
HARD_CAP="${WARDEN_STALL_HARD_CAP_SECONDS:-900}"        # 15 min backstop
KILL_GRACE="${WARDEN_STALL_KILL_GRACE_SECONDS:-10}"     # TERM->KILL grace
RESTART_COOLDOWN="${WARDEN_GATEWAY_RESTART_COOLDOWN_SECONDS:-300}"

LOG_FILE="${WARDEN_LOG_FILE:-$HOME/session-warden/state/scan.log}"
STATE_DIR="${WARDEN_HOME}/state"
REAP_STATE="${STATE_DIR}/reap"
RECOVERY_DIR="${STATE_DIR}/pending-recoveries"
LOCKFILE="${STATE_DIR}/reap.lock"

log() { echo "[$(date -Iseconds)] [reap] $*" >> "$LOG_FILE"; }

[ "$REAP_ENABLED" = "1" ] || exit 0

mkdir -p "$(dirname "$LOG_FILE")" "$REAP_STATE" "$RECOVERY_DIR"

# Prevent overlapping reaps (a kill grace can take a few seconds).
exec 197>"$LOCKFILE"
flock -n 197 || exit 0

now=$(date +%s)
jsonl_whoami="$(whoami)"

# sanitize a session key into a filename-safe token
keytok() { echo "$1" | sed 's/[^a-zA-Z0-9_-]/_/g'; }

# Drop a recovery request that scan.sh's drainer will deliver (it runs every
# tick regardless of whether scan.sh rotated anything).
enqueue_recovery() {
  local agent="$1" channel_key="$2" reason="$3"
  local tmp="${RECOVERY_DIR}/.$(keytok "${agent}-${channel_key}").tmp"
  local dst="${RECOVERY_DIR}/$(keytok "${agent}-${channel_key}").json"
  jq -n --arg agent "$agent" --arg ck "$channel_key" --arg r "$reason" \
    '{agent:$agent, channel_key:$ck, reason:$r}' > "$tmp" 2>/dev/null && mv "$tmp" "$dst"
}

# Mark a running session failed on disk + null its dead CLI bindings, so the
# gateway and scan.sh's recovery both treat it as a clean restart. Mirrors the
# clearing the recovery delivery does for status=="failed".
mark_failed() {
  local sjson="$1" channel_key="$2"
  [ "${WARDEN_DRY_RUN:-0}" = "1" ] && return 0
  [ -f "$sjson" ] || return 0
  jq --arg key "$channel_key" '
    if has($key) then
      .[$key].status = "failed" |
      .[$key].cliSessionIds = null |
      .[$key].claudeCliSessionId = null |
      .[$key].cliSessionBindings = null
    else . end
  ' "$sjson" > "${sjson}.reap.tmp" 2>/dev/null && mv "${sjson}.reap.tmp" "$sjson"
}

restart_gateway_if_due() {
  command -v openclaw >/dev/null 2>&1 || return 0
  local ts_file="${STATE_DIR}/.gateway-restart-ts"
  local last; last=$(cat "$ts_file" 2>/dev/null || echo 0)
  if [ $(( now - last )) -ge "$RESTART_COOLDOWN" ]; then
    if [ "${WARDEN_DRY_RUN:-0}" = "1" ]; then
      log "ESCALATE [dry-run] would restart gateway"
      return 0
    fi
    if openclaw gateway restart >> "$LOG_FILE" 2>&1; then
      date +%s > "$ts_file"
      log "ESCALATE: gateway restarted (a session stayed stuck after kill)"
    else
      log "WARN: gateway restart failed during escalation"
    fi
  else
    log "ESCALATE: gateway restart suppressed (cooldown ${RESTART_COOLDOWN}s)"
  fi
}

reaped=0
escalated=0

for sjson in "${WARDEN_OPENCLAW_HOME}"/agents/*/sessions/sessions.json; do
  [ -f "$sjson" ] || continue
  agent=$(agent_from_sessions_path "$sjson")

  if [ -n "${WARDEN_SCAN_AGENTS:-}" ]; then
    echo " ${WARDEN_SCAN_AGENTS} " | grep -q " ${agent} " || continue
  fi

  jsonl_base="${WARDEN_CLAUDE_PROJECTS}/-home-${jsonl_whoami}--openclaw-agents-${agent}"

  while IFS='|' read -r channel_key cli_session_id updated_at_ms; do
    [ -z "$cli_session_id" ] && continue

    # Forward-progress timestamp: newest of updatedAt and the JSONL mtime.
    jsonl_file="${jsonl_base}/${cli_session_id}.jsonl"
    jsonl_mtime=0
    [ -f "$jsonl_file" ] && jsonl_mtime=$(stat -c%Y "$jsonl_file" 2>/dev/null || echo 0)
    last_progress=$(reap_last_progress_epoch "$updated_at_ms" "$jsonl_mtime")

    verdict=$(reap_stall_verdict "running" "$now" "$last_progress" "$HARD_CAP")
    [ "$verdict" = "STUCK" ] || continue

    idle=$(( now - last_progress ))
    pid=$(reap_find_agent_pid "$cli_session_id" "$agent")
    wchan="-"; [ -n "$pid" ] && wchan=$(reap_proc_wchan "$pid")
    tok=$(keytok "${agent}-${channel_key}")
    killed_marker="${REAP_STATE}/${tok}.killed"

    # ESCALATION: we already acted on this session on a recent tick and it's
    # STILL running+stale. Disk clearing + child kill didn't take, so the
    # gateway's own event loop isn't reacting. Restart it (shared cooldown).
    if [ -f "$killed_marker" ]; then
      prev=$(cat "$killed_marker" 2>/dev/null || echo 0)
      if [ $(( now - prev )) -lt $(( HARD_CAP + 120 )) ]; then
        log "STILL STUCK after action: ${agent}/${channel_key} pid=${pid:-none} idle=${idle}s wchan=${wchan} — escalating to gateway restart"
        restart_gateway_if_due
        escalated=$(( escalated + 1 ))
        rm -f "$killed_marker"
        continue
      fi
    fi

    log "STUCK: ${agent}/${channel_key} pid=${pid:-none} idle=${idle}s (cap=${HARD_CAP}s) wchan=${wchan} cli=${cli_session_id}"

    if [ -n "$pid" ]; then
      # A live wedged child — kill it directly (independent of gateway health).
      if reap_kill_pid "$pid" "$KILL_GRACE"; then
        log "REAPED: killed pid ${pid} for ${agent}/${channel_key}"
        date +%s > "$killed_marker"
        mark_failed "$sjson" "$channel_key"
        enqueue_recovery "$agent" "$channel_key" "STALL_REAPED"
        notify_rotation "$agent" "$channel_key" "Stall reaped" "pid=${pid} idle=${idle}s wchan=${wchan} (no progress past ${HARD_CAP}s hard cap)"
        reaped=$(( reaped + 1 ))
      else
        log "WARN: pid ${pid} survived SIGKILL for ${agent}/${channel_key} — escalating"
        date +%s > "$killed_marker"
        restart_gateway_if_due
        escalated=$(( escalated + 1 ))
      fi
    else
      # status=running but no live child for it — the turn already died and the
      # gateway never cleared the bookkeeping. Nothing to kill; clear the stale
      # state on disk and hand off to recovery so this one session restarts
      # clean, WITHOUT restarting all the other agents.
      log "STALE-RUNNING (no live child): ${agent}/${channel_key} idle=${idle}s — clearing + recovering"
      date +%s > "$killed_marker"
      mark_failed "$sjson" "$channel_key"
      enqueue_recovery "$agent" "$channel_key" "STALL_CLEARED"
      notify_rotation "$agent" "$channel_key" "Stale turn cleared" "no live child; status stuck at running for ${idle}s"
      reaped=$(( reaped + 1 ))
    fi
  done < <(reap_list_running "$sjson")
done

# Clear stale killed-markers so they don't linger and falsely escalate later.
find "$REAP_STATE" -name '*.killed' -type f -mmin +30 -delete 2>/dev/null || true

if [ "$reaped" -gt 0 ] || [ "$escalated" -gt 0 ]; then
  log "REAP complete: reaped ${reaped}, escalated ${escalated}"
fi

flock -u 197
