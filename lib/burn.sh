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

burn_ledger_dir() {
  echo "${WARDEN_HOME:-$HOME/session-warden}/state/burn"
}

# burn_channel_report <ledger> <since-epoch>
# Per-channel consumption since <since>, one line per active channel:
#   channel|consumed|turns|tokens_now|last_ts
# Counters are cumulative per CLI session; a drop between consecutive records
# means the session rotated, so that pair contributes the new session's
# running total instead of a negative delta. A channel whose first in-window
# record has no earlier anchor consumes 0 (undercount, never overcount).
burn_channel_report() {
  local ledger="$1" since="$2"
  [ -f "$ledger" ] || return 0
  jq -rs --argjson since "$since" '
    group_by(.channel)[] |
    sort_by(.ts) as $r |
    ([$r[] | select(.ts < $since)] | last) as $anchor |
    [$r[] | select(.ts >= $since)] as $win |
    select(($win | length) > 0) |
    ((if $anchor == null then [] else [$anchor] end) + $win) as $s |
    (reduce range(1; $s | length) as $i (0;
      . + (if $s[$i].tokens >= $s[$i-1].tokens
           then $s[$i].tokens - $s[$i-1].tokens
           else $s[$i].tokens end))) as $consumed |
    (reduce range(1; $s | length) as $i (0;
      . + (if $s[$i].turns >= $s[$i-1].turns
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

# burn_check_agent <sessions.json path>
# Runs BURN (spike) / BUDGET (window ceiling) / LOOP (retry signature) checks
# against the agent's ledger and recent transcripts. Alert-only in M3:
# enforcement hooks onto the emitted events in M4. Never fails the caller.
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
    elif [ "$pct" -ge "$warn_pct" ]; then
      burn_alert "warn-${agent}" "$agent" "-" "WARN" \
        "burn firewall: ${agent} at ${pct}% of window budget" \
        "consumed ${total} of ${budget} tokens in the current $(( window / 3600 ))h window" || true
    fi
  fi

  # BURN (spike) + LOOP: only channels active in the last 5 minutes
  local spike="${WARDEN_BURN_SPIKE_TOKENS_5M:-150000}"
  local jsonl_base="${WARDEN_CLAUDE_PROJECTS}/-home-$(whoami)--openclaw-agents-${agent}"
  while IFS='|' read -r channel consumed turns tokens_now last_ts; do
    [ -z "$channel" ] && continue

    if [ "$consumed" -gt "$spike" ] 2>/dev/null; then
      burn_alert "spike-${agent}-${channel}" "$agent" "$channel" "BURN" \
        "burn firewall: ${agent} burning fast" \
        "${channel}: ${consumed} tokens in 5 minutes (threshold ${spike})" || true
    fi

    local sid jsonl
    sid=$(jq -r --arg ch "$channel" 'select(.channel == $ch) | .sid' "$ledger" 2>/dev/null | tail -1)
    jsonl="${jsonl_base}/${sid}.jsonl"
    if [ -n "$sid" ] && burn_detect_loop "$jsonl" >/dev/null; then
      burn_alert "loop-${agent}-${channel}" "$agent" "$channel" "LOOP" \
        "burn firewall: ${agent} looks stuck in a retry loop" \
        "${channel}: last ${WARDEN_LOOP_REPEATS:-6} tool calls are identical (session ${sid:0:12})" || true
    fi
  done < <(burn_channel_report "$ledger" $(( now - 300 )))

  return 0
}

# burn_prune [days]
# Drops ledger records older than N days (default WARDEN_BURN_RETENTION_DAYS,
# default 8 — a full week of windows plus slack). Called from cleanup.
burn_prune() {
  local days="${1:-${WARDEN_BURN_RETENTION_DAYS:-8}}"
  local dir cutoff f tmp
  dir=$(burn_ledger_dir)
  [ -d "$dir" ] || return 0
  cutoff=$(( $(date +%s) - days * 86400 ))

  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    tmp="${f}.tmp.$$"
    if jq -c --argjson cutoff "$cutoff" 'select(.ts >= $cutoff)' "$f" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  done
  return 0
}
