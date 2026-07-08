#!/usr/bin/env bash
# burn.sh — subscription-usage ledger for the burn firewall
#
# Samples per-channel token counters from an agent's sessions.json into an
# append-only ledger at state/burn/<agent>.jsonl. One JSON record per change:
#   {"ts":<epoch>,"channel":"...","sid":"...","tokens":N,"turns":N}
# Records are cumulative snapshots (not deltas) — deltas are computed at read
# time by the reporting layer, so a missed sample never corrupts the ledger.
#
# Session Warden's job here is protecting a Claude *subscription* window:
# the ledger is the ground truth for "what ate my usage" and for the
# BURN/LOOP/BUDGET detection built on top of it.

_BURN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_BURN_LIB_DIR}/agent-attribution.sh"
source "${_BURN_LIB_DIR}/notify.sh"
source "${_BURN_LIB_DIR}/portable.sh"
source "${_BURN_LIB_DIR}/reap.sh"

burn_ledger_dir() {
  echo "${WARDEN_HOME:-$HOME/session-warden}/state/burn"
}

# burn_channel_report <ledger> <since-epoch>
# Per-channel consumption since <since>, one line per active channel:
#   channel|consumed|turns|tokens_now|last_ts
# Counters are cumulative per CLI session. A rotation is detected by EITHER a
# sid change or a counter drop between consecutive records; a rotated pair
# contributes the new session's running total instead of a same-session delta.
# A channel whose first in-window record has no earlier anchor consumes 0
# (undercount, never overcount). Lines are parsed tolerantly (fromjson?), so
# one torn append never silently disables the whole report for an agent.
burn_channel_report() {
  local ledger="$1" since="$2"
  [ -f "$ledger" ] || return 0
  jq -rRn --argjson since "$since" '
    [inputs | fromjson? // empty] |
    group_by(.channel)[] |
    sort_by(.ts) as $r |
    ([$r[] | select(.ts < $since)] | last) as $anchor |
    [$r[] | select(.ts >= $since)] as $win |
    select(($win | length) > 0) |
    ((if $anchor == null then [] else [$anchor] end) + $win) as $s |
    (reduce range(1; $s | length) as $i (0;
      . + (if ($s[$i].sid // "") != ($s[$i-1].sid // "")
           then $s[$i].tokens
           elif $s[$i].tokens >= $s[$i-1].tokens
           then $s[$i].tokens - $s[$i-1].tokens
           else $s[$i].tokens end))) as $consumed |
    (reduce range(1; $s | length) as $i (0;
      . + (if ($s[$i].sid // "") != ($s[$i-1].sid // "")
           then $s[$i].turns
           elif $s[$i].turns >= $s[$i-1].turns
           then $s[$i].turns - $s[$i-1].turns
           else $s[$i].turns end))) as $turns |
    "\($r[0].channel)|\($consumed)|\($turns)|\($win | last | .tokens)|\($win | last | .ts)"
  ' "$ledger" 2>/dev/null
}

# burn_sample_agent <sessions.json path>
# Appends one ledger record per channel whose token count changed since the
# last sample. No-op when WARDEN_BURN_ENABLED=0. Never fails the caller.
burn_sample_agent() {
  [ "${WARDEN_BURN_ENABLED:-1}" = "1" ] || return 0

  local sjson="$1"
  [ -f "$sjson" ] || return 0

  local agent ledger dir now
  agent=$(agent_from_sessions_path "$sjson")
  dir=$(burn_ledger_dir)
  ledger="${dir}/${agent}.jsonl"
  mkdir -p "$dir"
  now=$(date +%s)

  # channel|sid|tokens|turns for every channel bound to a claude-cli session
  while IFS='|' read -r channel sid tokens turns; do
    [ -z "$channel" ] && continue

    # Skip when the token counter hasn't moved since the last record for
    # this channel — keeps the ledger tiny on idle fleets.
    local last_tokens=""
    if [ -f "$ledger" ]; then
      last_tokens=$(jq -r --arg ch "$channel" \
        'select(.channel == $ch) | .tokens' "$ledger" 2>/dev/null | tail -1)
    fi
    [ "$last_tokens" = "$tokens" ] && continue

    jq -cn --argjson ts "$now" --arg channel "$channel" --arg sid "$sid" \
           --argjson tokens "${tokens:-0}" --argjson turns "${turns:-0}" \
           '{ts:$ts, channel:$channel, sid:$sid, tokens:$tokens, turns:$turns}' \
      >> "$ledger" 2>/dev/null || true
  done < <(jq -r '
    to_entries[] |
    select(.value.cliSessionIds["claude-cli"] // "" | length > 0) |
    "\(.key)|\(.value.cliSessionIds["claude-cli"])|\(.value.totalTokens // 0)|\(.value.numTurns // 0)"
  ' "$sjson" 2>/dev/null)

  return 0
}

# ─── M3: detection ────────────────────────────────────────

# burn_event <agent> <channel> <kind> <detail>
# Appends an alert event to state/burn/events.jsonl. Events are emitted only
# when their alert throttle window is open (see burn_alert), so the file is
# an alert log, not a per-scan sample stream.
burn_event() {
  local agent="$1" channel="$2" kind="$3" detail="$4"
  local dir
  dir=$(burn_ledger_dir)
  mkdir -p "$dir"
  jq -cn --argjson ts "$(date +%s)" --arg agent "$agent" --arg channel "$channel" \
         --arg kind "$kind" --arg detail "$detail" \
         '{ts:$ts, agent:$agent, channel:$channel, kind:$kind, detail:$detail}' \
    >> "${dir}/events.jsonl" 2>/dev/null || true
}

# burn_alert <throttle-key> <agent> <channel> <kind> <title> <detail>
# Event + Telegram alert, throttled per key (default 1h, doctor-style).
# Returns 0 if the alert fired, 1 if throttled.
burn_alert() {
  local key="$1" agent="$2" channel="$3" kind="$4" title="$5" detail="$6"
  local dir marker now last cooldown
  dir=$(burn_ledger_dir)
  mkdir -p "$dir"
  marker="${dir}/.alert-$(echo "$key" | sed 's/[^a-zA-Z0-9_-]/_/g')"
  now=$(date +%s)
  cooldown="${WARDEN_BURN_ALERT_COOLDOWN_SECONDS:-3600}"

  if [ -f "$marker" ]; then
    last=$(cat "$marker" 2>/dev/null || echo 0)
    [ $(( now - last )) -lt "$cooldown" ] && return 1
  fi

  echo "$now" > "$marker"
  burn_event "$agent" "$channel" "$kind" "$detail"
  notify_alert "$title" "$detail"
  return 0
}

# burn_detect_loop <jsonl> [repeats]
# Retry-loop signature: the last N tool calls in the transcript tail are the
# same tool with identical input. Prints LOOP and returns 0 when detected.
burn_detect_loop() {
  local jsonl="$1" repeats="${2:-${WARDEN_LOOP_REPEATS:-6}}"
  [ -f "$jsonl" ] || return 1

  local verdict
  verdict=$(tail -n 300 "$jsonl" 2>/dev/null | jq -Rrs --argjson n "$repeats" '
    [split("\n")[] | select(length > 0) | (fromjson? // empty) |
     select(.type == "assistant") | .message.content[]? |
     select(.type == "tool_use") | {name: .name, input: .input} | tojson] |
    if (length >= $n) and ((.[length - $n:] | unique | length) == 1)
    then "LOOP" else "OK" end
  ' 2>/dev/null)

  [ "$verdict" = "LOOP" ] && { echo "LOOP"; return 0; }
  return 1
}

# ─── M4: enforcement ─────────────────────────────────────
# Everything here is inert unless WARDEN_BURN_ENFORCE=1 (default 0, warn-only).
# The escalation contract:
#   BUDGET breach  -> PAUSE: marker until the window resets; while paused, only
#                     IDLE CLI processes are killed (JSONL stale — never a turn
#                     that is actively writing its transcript).
#   LOOP signature -> KILL: the one deliberate mid-turn exception. A retry loop
#                     keeps its transcript fresh (every retry appends), which is
#                     exactly why it burns silently. The kill is precisely
#                     scoped: env-matched pid (never a human's claude), status
#                     "running", one kill per channel per cooldown. Recovery
#                     rides the existing pipeline (FAILED -> rotate + summary).

burn_pause_file() {
  echo "$(burn_ledger_dir)/paused/$(echo "$1" | sed 's/[^a-zA-Z0-9_-]/_/g')"
}

# burn_pause_agent <agent> <until-epoch>
burn_pause_agent() {
  local f
  f=$(burn_pause_file "$1")
  mkdir -p "$(dirname "$f")"
  echo "$2" > "$f"
}

# burn_is_paused <agent> — 0 when paused; clears expired markers.
burn_is_paused() {
  local f until
  f=$(burn_pause_file "$1")
  [ -f "$f" ] || return 1
  until=$(cat "$f" 2>/dev/null || echo 0)
  if [ "$(date +%s)" -ge "${until:-0}" ]; then
    rm -f "$f"
    return 1
  fi
  return 0
}

# burn_enforce_verdict <enforce-flag> <kind> <status>
# Pure decision: "" (do nothing) | PAUSE | KILL.
burn_enforce_verdict() {
  local enforce="$1" kind="$2" status="$3"
  [ "$enforce" = "1" ] || { echo ""; return 0; }
  case "$kind" in
    BUDGET) echo "PAUSE" ;;
    LOOP)   if [ "$status" = "running" ]; then echo "KILL"; else echo ""; fi ;;
    *)      echo "" ;;
  esac
}

# burn_kill_channel <agent> <channel> <why>
# Env-matched TERM->KILL of the channel's CLI child, with a per-channel kill
# cooldown so a respawning loop is not killed in a loop. Honors WARDEN_DRY_RUN.
burn_kill_channel() {
  local agent="$1" channel="$2" why="$3"
  local dir marker now last cooldown pid
  dir=$(burn_ledger_dir)
  marker="${dir}/.killed-$(echo "${agent}-${channel}" | sed 's/[^a-zA-Z0-9_-]/_/g')"
  now=$(date +%s)
  cooldown="${WARDEN_BURN_KILL_COOLDOWN_SECONDS:-3600}"
  if [ -f "$marker" ]; then
    last=$(cat "$marker" 2>/dev/null || echo 0)
    [ $(( now - last )) -lt "$cooldown" ] && return 1
  fi

  pid=$(reap_find_agent_pid "$channel" "$agent")
  [ -n "$pid" ] || return 1

  echo "$now" > "$marker"
  if reap_kill_pid "$pid" "${WARDEN_STALL_KILL_GRACE_SECONDS:-10}"; then
    burn_event "$agent" "$channel" "LOOPKILL" "$why (pid ${pid})"
    notify_alert "burn firewall: killed looping turn for ${agent}" "${channel}: ${why}"
    return 0
  fi
  burn_event "$agent" "$channel" "KILLFAIL" "$why (pid ${pid} survived TERM+KILL)"
  return 1
}

# burn_enforce_pause <sessions.json> <agent>
# While paused (enforce on): stop only IDLE CLI children. A session is idle
# only when ALL of these hold — the gateway does not think a turn is running
# (status != "running"), its transcript exists (a missing JSONL means a
# just-rotated session we know nothing about — leave it alone), and neither
# the transcript nor updatedAt has advanced within WARDEN_ACTIVE_THRESHOLD_SECS.
# An in-flight turn always finishes; pause only prevents idle sessions from
# picking up new work while the window budget is exhausted.
burn_enforce_pause() {
  local sjson="$1" agent="$2"
  local jsonl_base now threshold
  jsonl_base=$(agent_jsonl_dir "$agent")
  now=$(date +%s)
  threshold="${WARDEN_ACTIVE_THRESHOLD_SECS:-60}"

  while IFS='|' read -r channel sid status updated_at_ms; do
    [ -z "$channel" ] && continue
    # The gateway says a turn is in flight -> never touch it.
    [ "$status" = "running" ] && continue
    local jsonl="${jsonl_base}/${sid}.jsonl"
    # Unknown/new session (no transcript yet) -> leave it alone.
    [ -f "$jsonl" ] || continue
    local progress
    progress=$(reap_last_progress_epoch "$updated_at_ms" "$(stat_mtime "$jsonl")")
    # Recent progress on either signal -> not idle.
    [ $(( now - progress )) -lt "$threshold" ] && continue
    local pid
    pid=$(reap_find_agent_pid "$channel" "$agent")
    [ -n "$pid" ] || continue
    if reap_kill_pid "$pid" "${WARDEN_STALL_KILL_GRACE_SECONDS:-10}"; then
      burn_event "$agent" "$channel" "PAUSEKILL" "idle CLI stopped while window budget is exhausted (pid ${pid})"
    fi
  done < <(jq -r '
    to_entries[] |
    select(.value.cliSessionIds["claude-cli"] // "" | length > 0) |
    "\(.key)|\(.value.cliSessionIds["claude-cli"])|\(.value.status // "")|\(.value.updatedAt // 0)"
  ' "$sjson" 2>/dev/null)
}

# burn_check_agent <sessions.json path>
# Runs BURN (spike) / BUDGET (window ceiling) / LOOP (retry signature) checks
# against the agent's ledger and recent transcripts. Alerts always; the
# enforcement ladder above engages only when WARDEN_BURN_ENFORCE=1.
# Never fails the caller.
burn_check_agent() {
  [ "${WARDEN_BURN_ENABLED:-1}" = "1" ] || return 0

  local sjson="$1"
  [ -f "$sjson" ] || return 0

  local agent ledger now window
  agent=$(agent_from_sessions_path "$sjson")
  ledger="$(burn_ledger_dir)/${agent}.jsonl"
  [ -f "$ledger" ] || return 0
  now=$(date +%s)
  window="${WARDEN_BURN_WINDOW_SECONDS:-18000}"
  local enforce="${WARDEN_BURN_ENFORCE:-0}"

  # Paused agent (enforce on): keep idle CLIs down until the marker expires.
  if [ "$enforce" = "1" ] && burn_is_paused "$agent"; then
    burn_enforce_pause "$sjson" "$agent"
  fi

  # BUDGET: agent's total window consumption vs the per-window budget
  local budget="${WARDEN_BURN_WINDOW_BUDGET:-0}"
  if [ "$budget" -gt 0 ] 2>/dev/null; then
    local total pct warn_pct
    total=$(burn_channel_report "$ledger" $(( now - window )) | awk -F'|' '{s+=$2} END {print s+0}')
    pct=$(( total * 100 / budget ))
    warn_pct="${WARDEN_BURN_WARN_PCT:-70}"
    if [ "$pct" -ge 100 ]; then
      burn_alert "budget-${agent}" "$agent" "-" "BUDGET" \
        "burn firewall: ${agent} EXCEEDED window budget" \
        "consumed ${total} of ${budget} tokens (${pct}%) in the current $(( window / 3600 ))h window" || true
      if [ "$(burn_enforce_verdict "$enforce" "BUDGET" "-")" = "PAUSE" ] && ! burn_is_paused "$agent"; then
        burn_pause_agent "$agent" $(( now + window ))
        burn_event "$agent" "-" "PAUSE" "window budget exhausted; paused until $(( now + window ))"
        burn_enforce_pause "$sjson" "$agent"
      fi
    elif [ "$pct" -ge "$warn_pct" ]; then
      burn_alert "warn-${agent}" "$agent" "-" "WARN" \
        "burn firewall: ${agent} at ${pct}% of window budget" \
        "consumed ${total} of ${budget} tokens in the current $(( window / 3600 ))h window" || true
    fi
  fi

  # BURN (spike) + LOOP: only channels active in the last 5 minutes
  local spike="${WARDEN_BURN_SPIKE_TOKENS_5M:-150000}"
  local jsonl_base
  jsonl_base=$(agent_jsonl_dir "$agent")
  while IFS='|' read -r channel consumed turns tokens_now last_ts; do
    [ -z "$channel" ] && continue

    if [ "$consumed" -gt "$spike" ] 2>/dev/null; then
      burn_alert "spike-${agent}-${channel}" "$agent" "$channel" "BURN" \
        "burn firewall: ${agent} burning fast" \
        "${channel}: ${consumed} tokens in 5 minutes (threshold ${spike})" || true
    fi

    # LOOP evidence gates (both alert and kill):
    # 1. The ledger's evidence sid must be the channel's CURRENT session —
    #    after rotation the ledger lags, and a dead session's transcript must
    #    never condemn its healthy replacement.
    # 2. The transcript must be actively being written (mtime within the
    #    active threshold). A live retry loop appends on every retry; a stale
    #    signature left behind by a finished turn must never fire.
    local sid cur_sid jsonl
    sid=$(jq -Rr --arg ch "$channel" 'fromjson? // empty | select(.channel == $ch) | .sid' "$ledger" 2>/dev/null | tail -1)
    cur_sid=$(jq -r --arg ch "$channel" '.[$ch].cliSessionIds["claude-cli"] // ""' "$sjson" 2>/dev/null)
    jsonl="${jsonl_base}/${sid}.jsonl"
    if [ -n "$sid" ] && [ "$sid" = "$cur_sid" ] && [ -f "$jsonl" ]; then
      local jsonl_mtime
      jsonl_mtime=$(stat_mtime "$jsonl")
      if [ $(( now - jsonl_mtime )) -le "${WARDEN_ACTIVE_THRESHOLD_SECS:-60}" ] \
         && burn_detect_loop "$jsonl" >/dev/null; then
        burn_alert "loop-${agent}-${channel}" "$agent" "$channel" "LOOP" \
          "burn firewall: ${agent} looks stuck in a retry loop" \
          "${channel}: last ${WARDEN_LOOP_REPEATS:-6} tool calls are identical (session ${sid:0:12})" || true
        local status
        status=$(jq -r --arg ch "$channel" '.[$ch].status // ""' "$sjson" 2>/dev/null)
        if [ "$(burn_enforce_verdict "$enforce" "LOOP" "$status")" = "KILL" ]; then
          burn_kill_channel "$agent" "$channel" \
            "retry loop: last ${WARDEN_LOOP_REPEATS:-6} tool calls identical" || true
        fi
      fi
    fi
  done < <(burn_channel_report "$ledger" $(( now - 300 )))

  return 0
}

# ─── M5: daily digest ─────────────────────────────────────

# burn_daily_digest
# One Telegram digest per day after WARDEN_BURN_DIGEST_HOUR (local time):
# last-24h consumption per agent plus firewall event counts. The dated marker
# file (which also stores the summary for inspection) gates repeats; it is
# written before sending so a failed send degrades to a quiet no-op, never a
# repeat storm. Blank WARDEN_BURN_DIGEST_HOUR disables the digest.
burn_daily_digest() {
  [ "${WARDEN_BURN_ENABLED:-1}" = "1" ] || return 0

  local hour="${WARDEN_BURN_DIGEST_HOUR-21}"
  [ -n "$hour" ] || return 0
  local hour_now
  hour_now=$(( 10#$(date +%H) ))
  [ "$hour_now" -ge "$hour" ] || return 0

  local dir marker
  dir=$(burn_ledger_dir)
  marker="${dir}/.digest-$(date +%Y-%m-%d)"
  [ -f "$marker" ] && return 0
  mkdir -p "$dir"

  local since total=0 summary="" ledger agent t
  since=$(( $(date +%s) - 86400 ))
  for ledger in "$dir"/*.jsonl; do
    [ -f "$ledger" ] || continue
    agent=$(basename "$ledger" .jsonl)
    [ "$agent" = "events" ] && continue
    t=$(burn_channel_report "$ledger" "$since" | awk -F'|' '{s+=$2} END {print s+0}')
    [ "${t:-0}" -gt 0 ] || continue
    summary="${summary}• ${agent}: ${t} tokens
"
    total=$(( total + t ))
  done

  local events=""
  if [ -f "${dir}/events.jsonl" ]; then
    events=$(jq -r --argjson since "$since" 'select(.ts >= $since) | .kind' \
      "${dir}/events.jsonl" 2>/dev/null | sort | uniq -c | awk '{print "• " $2 ": " $1}')
  fi

  local body="Last 24h: ${total} tokens across the fleet
${summary}${events:+
Firewall events:
${events}}"

  printf '%s\n' "$body" > "$marker"
  notify_burn_digest "$body" || true
  return 0
}

# burn_prune [days]
# Drops ledger records older than N days (default WARDEN_BURN_RETENTION_DAYS,
# default 8 — a full week of windows plus slack). Called from cleanup.
# Rewrites serialize against the scan loop via the scan lock (an append that
# landed between read and rename would otherwise be silently destroyed);
# tolerant per-line parsing means pruning also self-heals a torn append.
burn_prune() {
  local days="${1:-${WARDEN_BURN_RETENTION_DAYS:-8}}"
  local dir cutoff f tmp
  dir=$(burn_ledger_dir)
  [ -d "$dir" ] || return 0
  cutoff=$(( $(date +%s) - days * 86400 ))

  local locked=0
  if command -v flock >/dev/null 2>&1; then
    exec 198>"${WARDEN_HOME:-$HOME/session-warden}/state/scan.lock"
    if flock -w 30 198; then
      locked=1
    else
      exec 198>&-
      return 0   # scan loop busy past the wait — prune next run instead of racing
    fi
  fi

  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    tmp="${f}.tmp.$$"
    if jq -cR --argjson cutoff "$cutoff" 'fromjson? // empty | select(.ts >= $cutoff)' "$f" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  done

  [ "$locked" -eq 1 ] && exec 198>&-
  return 0
}
