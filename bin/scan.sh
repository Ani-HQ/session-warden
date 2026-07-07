#!/usr/bin/env bash
# scan.sh — cron entry point, runs every 30 seconds
# Scans all OpenClaw sessions for problems, rotates, summarizes to memory,
# THEN restarts gateway so agents boot with full context.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/portable.sh"   # stat_mtime / stat_size
export WARDEN_DRY_RUN
source "${WARDEN_HOME}/lib/detect.sh"
source "${WARDEN_HOME}/lib/channel-history.sh"
source "${WARDEN_HOME}/lib/gbrain.sh"

LOG_FILE="${WARDEN_LOG_FILE}"
LOCKFILE="${WARDEN_HOME}/state/scan.lock"

log() {
  echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"
}

# Prevent overlapping scans
exec 199>"$LOCKFILE"
if ! flock -n 199; then
  exit 0  # another scan is running, skip silently
fi

mkdir -p "$(dirname "$LOG_FILE")"

# Heartbeat for doctor.sh — scan.log only gets written on events, so its mtime
# can't prove the loop is alive. This file can.
touch "${WARDEN_HOME}/state/.last-scan-ts"

rotated=0

# Scan agents (allowlist or all)
for sjson in "${WARDEN_OPENCLAW_HOME}"/agents/*/sessions/sessions.json; do
  [ -f "$sjson" ] || continue
  agent=$(agent_from_sessions_path "$sjson")

  if [ -n "${WARDEN_SCAN_AGENTS:-}" ]; then
    echo " ${WARDEN_SCAN_AGENTS} " | grep -q " ${agent} " || continue
  fi

  while IFS='|' read -r reason channel_key cli_session_id detail; do
    [ -z "$reason" ] && continue

    # Skip sessions with a recent recovered marker (prevents rotation loops
    # where warden keeps re-rotating idle-but-healthy agents after recovery)
    if [[ "$reason" =~ ^(FAILED|ZOMBIE)$ ]]; then
      recovered_file="${WARDEN_HOME}/state/cooldowns/${agent}-$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g').recovered"
      if [ -f "$recovered_file" ]; then
        recovered_at=$(cat "$recovered_file" 2>/dev/null || echo 0)
        now_check=$(date +%s)
        if [ $((now_check - recovered_at)) -lt 7200 ]; then
          continue
        fi
      fi
    fi

    if "${SCRIPT_DIR}/rotate.sh" "$agent" "$channel_key" "$cli_session_id" "$reason" "$detail"; then
      rotated=$((rotated + 1))
    fi
  done < <(detect_sessions_problems "$sjson")
done

# Summarize SYNCHRONOUSLY before gateway restart — agents must boot with memory
# Timeout at 90s to prevent a hung API call from blocking all scans
if ls "${WARDEN_HOME}/state/pending-summaries/"*.json 1>/dev/null 2>&1; then
  log "SUMMARY: processing synchronously before gateway restart"
  if timeout 90 "${SCRIPT_DIR}/summarize.sh" >> "$LOG_FILE" 2>&1; then
    log "SUMMARY: synchronous processing complete"
  else
    exit_code=$?
    if [ "$exit_code" -eq 124 ]; then
      log "WARN: summarize.sh timed out after 90s — gateway restart will proceed anyway"
    else
      log "WARN: summarize.sh exited with code $exit_code — gateway restart will proceed anyway"
    fi
  fi
fi

# NO gateway restart after rotation. The gateway re-reads sessions.json with a
# 45s mtime-checked cache (store-cache: DEFAULT_SESSION_STORE_TTL_MS), so the
# cleared bindings are picked up naturally. Restarting here killed in-flight
# turns for EVERY agent and triggered resume-on-boot broadcasts — the blast
# radius of one rotation was the whole fleet. The reaper keeps its own
# restart as a last-resort escalation for truly stuck states.
# Re-enable only if a gateway version without the stat-checked cache is in use:
if [ "$rotated" -gt 0 ] && [ "${WARDEN_RESTART_GATEWAY_AFTER_ROTATION:-0}" = "1" ] && command -v openclaw >/dev/null 2>&1; then
  restart_cooldown="${WARDEN_HOME}/state/.gateway-restart-ts"
  now=$(date +%s)
  last_restart=$(cat "$restart_cooldown" 2>/dev/null || echo 0)
  if [ $((now - last_restart)) -ge "${WARDEN_GATEWAY_RESTART_COOLDOWN_SECONDS:-60}" ]; then
    openclaw gateway restart >> "$LOG_FILE" 2>&1 && \
      date +%s > "$restart_cooldown" && \
      log "GATEWAY restarted after memory sync — agents will resume with context" || \
      log "WARN: gateway restart failed"
  fi
fi

# Send recovery messages for FAILED sessions (in background, non-blocking)
# Uses a lock so only one recovery batch runs at a time — prevents process pile-up.
recovery_dir="${WARDEN_HOME}/state/pending-recoveries"
recovery_lock="${WARDEN_HOME}/state/recovery.lock"
if [ -d "$recovery_dir" ] && ls "${recovery_dir}"/*.json 1>/dev/null 2>&1; then
  if ! flock -n 198 198>"$recovery_lock" 2>/dev/null; then
    log "RECOVERY: skipping — previous batch still running"
  else
    sending_dir="${recovery_dir}/.sending"
    mkdir -p "$sending_dir"
    for rfile in "${recovery_dir}"/*.json; do
      [ -f "$rfile" ] || continue
      mv "$rfile" "$sending_dir/" 2>/dev/null
    done
    (
      flock 198
      for rfile in "${sending_dir}"/*.json; do
        [ -f "$rfile" ] || continue
        ragent=$(jq -r '.agent' "$rfile")
        rchannel=$(jq -r '.channel_key' "$rfile")
        rreason=$(jq -r '.reason // ""' "$rfile")

        # A recovery prompt is only valuable fresh, once, and to a session
        # that needs it. Enforce all three here, at delivery time — the queue
        # can stall (stuck CLI, backlog), and delivering late or twice turns
        # recovery into noise that wakes agents for no reason.

        # Freshness: drop items older than the TTL instead of delivering.
        rfile_mtime=$(stat_mtime "$rfile")
        now_recovery=$(date +%s)
        if [ $((now_recovery - rfile_mtime)) -gt "${WARDEN_RECOVERY_TTL_SECONDS:-1800}" ]; then
          echo "[$(date -Iseconds)] RECOVERY: dropped stale request for $ragent/$rchannel ($((now_recovery - rfile_mtime))s old, TTL ${WARDEN_RECOVERY_TTL_SECONDS:-1800}s)" >> "$LOG_FILE"
          rm -f "$rfile"
          continue
        fi

        # Idempotency: if this channel already got a recovery recently
        # (.recovered marker is written on successful delivery), drop.
        dedup_file="${WARDEN_HOME}/state/cooldowns/${ragent}-$(echo "$rchannel" | sed 's/[^a-zA-Z0-9_-]/_/g').recovered"
        if [ -f "$dedup_file" ]; then
          dedup_at=$(cat "$dedup_file" 2>/dev/null || echo 0)
          if [ $((now_recovery - dedup_at)) -lt "${WARDEN_RECOVERY_DEDUP_SECONDS:-1800}" ]; then
            echo "[$(date -Iseconds)] RECOVERY: skipped duplicate for $ragent/$rchannel (recovered $((now_recovery - dedup_at))s ago)" >> "$LOG_FILE"
            rm -f "$rfile"
            continue
          fi
        fi

        # GBrain cross-session synthesis (bounded; empty on failure). Pulls a
        # cited briefing across ALL of this agent's recent sessions, not just
        # the last transcript — the recovery upgrade over flat CONTEXT.md.
        gbrain_brief=$(gbrain_query_context "$ragent" "$rchannel" 2>/dev/null)

        # Build recovery message with inlined context AND crash buffer
        context_file="${WARDEN_OPENCLAW_HOME}/agents/${ragent}/CONTEXT.md"
        recovery_msg=""

        # Read crash buffer (unprocessed messages from before the crash)
        crash_buf=""
        if type read_crash_buffer &>/dev/null; then
          crash_buf=$(read_crash_buffer "$ragent" "$rchannel")
        fi

        if [ -f "$context_file" ]; then
          context_content=$(cat "$context_file" 2>/dev/null)
          if [ -n "$context_content" ]; then
            if [ -n "$crash_buf" ]; then
              recovery_msg="You just came back from a session restart. Here is context from a PREVIOUS session, INCLUDING messages that were sent to you but never processed because you crashed:

${context_content}

The 'Unprocessed Messages' section above contains what team members said RIGHT BEFORE your crash. These are your TOP PRIORITY. Execute them immediately without asking anyone to repeat themselves. Send one short message confirming you're back and what you're about to do, then do it."
            else
              recovery_msg="You just came back from a session restart. Here is context from a PREVIOUS session (it may be stale or from a different task):

${context_content}

IMPORTANT: This context may NOT reflect what you were last asked to do. Before resuming, ALWAYS check the recent messages in this channel (scroll up or check Discord history) to find your actual current task. The most recent user message is your priority, not the context above. Send one short message saying you're back, then resume the actual pending work from the channel."
            fi
          fi
        fi
        if [ -z "$recovery_msg" ]; then
          if [ -n "$crash_buf" ]; then
            recovery_msg="You just came back from a session restart. Here are messages that were sent to you but never processed because you crashed:

${crash_buf}

Execute these immediately without asking anyone to repeat themselves. Send one short message confirming you're back, then do the work."
          else
            recovery_msg="You just came back from a session restart. Check the recent messages in this channel to find what you were working on. Your MEMORY.md may have older context but the channel messages are the source of truth for your current task. Send a short message saying you're back, then resume work."
          fi
        fi

        # Append GBrain cross-session synthesis to whichever message was built.
        if [ -n "$gbrain_brief" ]; then
          recovery_msg="${recovery_msg}

## Cross-session brief (synthesized from GBrain knowledge graph)
This is graph-wide context for you (${ragent}) across recent sessions. Use it to orient, but the channel's most recent messages remain the source of truth for your current task.

${gbrain_brief}"
        fi

        # ALL recoveries re-orient silently (owner preference, 2026-07-07):
        # no "I'm back" posts in channels. Restarts are visible on the health
        # dashboard and via Telegram alerts instead. If real user messages
        # arrived while the session was down (crash buffer), the agent should
        # answer THOSE through its normal channel tools — it just must not
        # announce the restart itself. Set WARDEN_ANNOUNCE_RECOVERIES=1 to
        # restore the old announce-on-crash behavior.
        deliver_flag=""
        if [ "${WARDEN_ANNOUNCE_RECOVERIES:-0}" = "1" ] && { [ -n "$crash_buf" ] || ! [[ "$rreason" =~ ^(TOKENS|TURNS|SIZE|COMPACTIONS)$ ]]; }; then
          deliver_flag="--deliver"
        fi
        if [ -z "$deliver_flag" ]; then
          if [ -n "$crash_buf" ]; then
            recovery_msg="${recovery_msg}

NOTE: do NOT announce that you're back and do NOT mention this restart. Messages arrived while you were down (see above) — respond to those directly in the channel as you normally would, then resume pending work."
          else
            recovery_msg="${recovery_msg}

NOTE: this restart is routine. Do NOT announce that you're back and do NOT message the user about it. Silently re-orient and resume any pending work; only contact the user if something genuinely needs them."
          fi
        fi

        # Channel-less sessions (explicit agent-to-agent sub-sessions, or
        # entries with no channel/provider binding in sessions.json) can't
        # take --deliver — there is no user-facing channel to post to. Send
        # without it; the message still reaches the agent session.
        sjson_path="${WARDEN_OPENCLAW_HOME}/agents/${ragent}/sessions/sessions.json"
        if [ -n "$deliver_flag" ]; then
          rchannel_binding=$(jq -r --arg key "$rchannel" '.[$key] | (.lastChannel // .channel // empty)' "$sjson_path" 2>/dev/null)
          case "$rchannel" in
            agent:*:explicit:*) rchannel_binding="" ;;
          esac
          if [ -z "$rchannel_binding" ]; then
            deliver_flag=""
            echo "[$(date -Iseconds)] RECOVERY: $ragent/$rchannel — no delivery channel, sent without --deliver" >> "$LOG_FILE"
          fi
        fi

        # -k 30: openclaw ignores SIGTERM, so without a KILL escalation a hung
        # delivery blocks the serial drain forever (observed: one delivery
        # stuck 90+ min holding 16 queued recoveries; another since Apr 30).
        # Keep stderr: silent delivery failures hid the #16 regression for
        # three weeks. On failure the tail of it goes in the log line.
        if delivery_err=$(timeout -k 30 180 openclaw agent \
          --agent "$ragent" \
          --channel last \
          --session-key "$rchannel" \
          --message "$recovery_msg" \
          --timeout 120 \
          ${deliver_flag} \
          2>&1 >/dev/null); then
          echo "[$(date -Iseconds)] RECOVERY: sent to $ragent/$rchannel" >> "$LOG_FILE"
          # Clear crash buffer after successful recovery delivery
          if type clear_crash_buffer &>/dev/null; then
            clear_crash_buffer "$ragent" "$rchannel"
          fi
          # Mark as recovered so zombie detection skips this session for 2 hours
          recovered_file="${WARDEN_HOME}/state/cooldowns/${ragent}-$(echo "$rchannel" | sed 's/[^a-zA-Z0-9_-]/_/g').recovered"
          date +%s > "$recovered_file"
          # Clear failure counter + backoff-alert marker on successful recovery
          fail_file="${WARDEN_HOME}/state/cooldowns/${ragent}-$(echo "$rchannel" | sed 's/[^a-zA-Z0-9_-]/_/g').failures"
          rm -f "$fail_file" "${fail_file%.failures}.backoff-alerted"
          # Clear status=failed in sessions.json so the gateway treats it as healthy
          if [ -f "$sjson_path" ]; then
            jq --arg key "$rchannel" '
              if has($key) and .[$key].status == "failed" then
                .[$key].status = null |
                .[$key].cliSessionIds = null |
                .[$key].claudeCliSessionId = null |
                .[$key].cliSessionBindings = null
              else . end
            ' "$sjson_path" > "${sjson_path}.tmp" && mv "${sjson_path}.tmp" "$sjson_path"
          fi
        else
          delivery_rc=$?
          delivery_err=$(echo "$delivery_err" | tr '\n' ' ' | head -c 200)
          echo "[$(date -Iseconds)] RECOVERY: failed to send to $ragent/$rchannel (exit ${delivery_rc}${delivery_err:+: ${delivery_err}}) — non-fatal" >> "$LOG_FILE"
        fi
        rm -f "$rfile"
      done
      flock -u 198
    ) 198>"$recovery_lock" &
  fi
fi

if [ "$rotated" -gt 0 ]; then
  log "SCAN complete: rotated $rotated sessions (summarized before restart)"
fi

# Cleanup expired crash buffers (runs every scan, lightweight)
if type cleanup_expired_crash_buffers &>/dev/null; then
  cleanup_expired_crash_buffers
fi

flock -u 199
