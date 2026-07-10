#!/usr/bin/env bash
# burn-solo.sh — standalone Claude Code usage sampler for the burn ledger
#
# Samples plain Claude Code JSONL transcripts directly, excluding OpenClaw
# agent project directories that are already covered by lib/burn.sh.

_BURN_SOLO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null  # Resolved relative to this library at runtime.
source "${_BURN_SOLO_LIB_DIR}/burn.sh"

burn_solo_ledger() {
  echo "$(burn_ledger_dir)/solo.jsonl"
}

burn_solo_state() {
  echo "$(burn_ledger_dir)/solo-state.json"
}

_burn_solo_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
  return 0
}

_burn_solo_read_state() {
  local state="$1"
  local data

  [ -f "$state" ] || { echo "{}"; return 0; }
  if data=$(jq -c 'if type == "object" then . else {} end' "$state" 2>/dev/null); then
    [ -n "$data" ] && { echo "$data"; return 0; }
  fi
  echo "{}"
  return 0
}

_burn_solo_state_row() {
  local state_json="$1" key="$2"
  local row

  if row=$(printf '%s\n' "$state_json" | jq -r --arg k "$key" '
    if has($k) then
      .[$k] |
      [1, (.off // 0), (.["in"] // 0), (.out // 0), (.cc // 0), (.cr // 0), (.turns // 0)] |
      @tsv
    else
      "0\t0\t0\t0\t0\t0\t0"
    end
  ' 2>/dev/null); then
    printf '%s\n' "$row"
  else
    printf '0\t0\t0\t0\t0\t0\t0\n'
  fi
  return 0
}

_burn_solo_put_state() {
  local state_json="$1" key="$2" off="$3" input_tokens="$4" output_tokens="$5"
  local cache_creation="$6" cache_read="$7" turns="$8" ts="$9"
  local updated

  if updated=$(printf '%s\n' "$state_json" | jq -c \
    --arg k "$key" \
    --argjson off "$off" \
    --argjson input_tokens "$input_tokens" \
    --argjson output_tokens "$output_tokens" \
    --argjson cache_creation "$cache_creation" \
    --argjson cache_read "$cache_read" \
    --argjson turns "$turns" \
    --argjson ts "$ts" \
    '.[$k] = {
      off: $off,
      "in": $input_tokens,
      out: $output_tokens,
      cc: $cache_creation,
      cr: $cache_read,
      turns: $turns,
      ts: $ts
    }' 2>/dev/null); then
    printf '%s\n' "$updated"
  else
    printf '%s\n' "$state_json"
  fi
  return 0
}

_burn_solo_parse_chunk() {
  local chunk="$1"
  local row

  if row=$(jq -rRn '
    reduce (inputs | fromjson? // empty | select(.type == "assistant")) as $m
      ({i:0,o:0,cc:0,cr:0,t:0};
       .i += (($m.message.usage.input_tokens // 0) | tonumber? // 0) |
       .o += (($m.message.usage.output_tokens // 0) | tonumber? // 0) |
       .cc += (($m.message.usage.cache_creation_input_tokens // 0) | tonumber? // 0) |
       .cr += (($m.message.usage.cache_read_input_tokens // 0) | tonumber? // 0) |
       .t += 1) |
    [.i, .o, .cc, .cr, .t] | @tsv
  ' "$chunk" 2>/dev/null); then
    printf '%s\n' "$row"
  else
    printf '0\t0\t0\t0\t0\n'
  fi
  return 0
}

# burn_solo_sample
# Samples recent standalone Claude Code transcripts into state/burn/solo.jsonl.
# No-op when WARDEN_BURN_ENABLED=0. Never fails the caller.
burn_solo_sample() {
  [ "${WARDEN_BURN_ENABLED:-1}" = "1" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local claude_projects="${WARDEN_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
  [ -d "$claude_projects" ] || return 0

  local dir ledger state now window cutoff
  dir=$(burn_ledger_dir)
  ledger=$(burn_solo_ledger)
  state=$(burn_solo_state)
  mkdir -p "$dir" 2>/dev/null || return 0

  now=$(date +%s)
  window=$(_burn_solo_uint "${WARDEN_SOLO_WINDOW_MINUTES:-15}")
  [ "$window" -gt 0 ] 2>/dev/null || window=15
  cutoff=$(( now - window * 60 ))

  local state_json state_changed
  state_json=$(_burn_solo_read_state "$state")
  state_changed=0

  local chunk=""
  trap 'rm -f "$chunk"' RETURN

  local jsonl
  for jsonl in "$claude_projects"/*/*.jsonl; do
    [ -f "$jsonl" ] || continue

    local project_dir project sid key mtime size row
    project_dir=$(dirname "$jsonl")
    project=$(basename "$project_dir")
    case "$project" in
      *--openclaw-agents-*) continue ;;
    esac

    mtime=$(stat_mtime "$jsonl")
    size=$(stat_size "$jsonl")
    sid=$(basename "$jsonl" .jsonl)
    key="${project}/${sid}"

    row=$(_burn_solo_state_row "$state_json" "$key")
    local known off input_tokens output_tokens cache_creation cache_read turns
    IFS=$'\t' read -r known off input_tokens output_tokens cache_creation cache_read turns <<< "$row"
    known=$(_burn_solo_uint "$known")
    off=$(_burn_solo_uint "$off")
    input_tokens=$(_burn_solo_uint "$input_tokens")
    output_tokens=$(_burn_solo_uint "$output_tokens")
    cache_creation=$(_burn_solo_uint "$cache_creation")
    cache_read=$(_burn_solo_uint "$cache_read")
    turns=$(_burn_solo_uint "$turns")

    local recent progressed truncated
    recent=0
    progressed=0
    truncated=0
    [ "$mtime" -ge "$cutoff" ] 2>/dev/null && recent=1
    if [ "$known" -eq 1 ] && [ "$size" -gt "$off" ] 2>/dev/null; then
      progressed=1
    fi
    if [ "$known" -eq 1 ] && [ "$size" -lt "$off" ] 2>/dev/null; then
      truncated=1
    fi

    [ "$known" -eq 0 ] && [ "$recent" -eq 0 ] && continue
    [ "$known" -eq 1 ] && [ "$recent" -eq 0 ] && [ "$progressed" -eq 0 ] && [ "$truncated" -eq 0 ] && continue

    if [ "$known" -eq 0 ]; then
      if jq -cn \
        --argjson ts "$now" \
        --arg channel "${project}:${sid}" \
        --arg sid "$sid" \
        '{ts:$ts, channel:$channel, sid:$sid, tokens:0, turns:0,
          "in":0, out:0, cc:0, cr:0}' \
        >> "$ledger" 2>/dev/null; then
        state_json=$(_burn_solo_put_state "$state_json" "$key" "$size" 0 0 0 0 0 "$now")
        state_changed=1
      fi
      continue
    fi

    local reset
    reset=0
    if [ "$truncated" -eq 1 ]; then
      off=0
      input_tokens=0
      output_tokens=0
      cache_creation=0
      cache_read=0
      turns=0
      reset=1
    fi

    if [ "$size" -le "$off" ] 2>/dev/null; then
      if [ "$reset" -eq 1 ]; then
        state_json=$(_burn_solo_put_state "$state_json" "$key" "$off" "$input_tokens" \
          "$output_tokens" "$cache_creation" "$cache_read" "$turns" "$now")
        state_changed=1
      fi
      continue
    fi

    local start processed line line_bytes
    if ! chunk=$(mktemp "${dir}/solo-chunk.XXXXXX" 2>/dev/null); then
      chunk="${dir}/solo-chunk.$$"
      : > "$chunk" 2>/dev/null || { rm -f "$chunk"; chunk=""; continue; }
    fi
    : > "$chunk" 2>/dev/null || { rm -f "$chunk"; chunk=""; continue; }

    start=$(( off + 1 ))
    processed=0
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "$chunk" 2>/dev/null || true
      line_bytes=$(printf '%s\n' "$line" | LC_ALL=C wc -c | tr -d ' ')
      line_bytes=$(_burn_solo_uint "$line_bytes")
      processed=$(( processed + line_bytes ))
    done < <(tail -c +"$start" "$jsonl" 2>/dev/null)

    if [ "$processed" -eq 0 ]; then
      rm -f "$chunk"
      chunk=""
      if [ "$reset" -eq 1 ]; then
        state_json=$(_burn_solo_put_state "$state_json" "$key" "$off" "$input_tokens" \
          "$output_tokens" "$cache_creation" "$cache_read" "$turns" "$now")
        state_changed=1
      fi
      continue
    fi

    local sums delta_input delta_output delta_cc delta_cr delta_turns
    sums=$(_burn_solo_parse_chunk "$chunk")
    rm -f "$chunk"
    chunk=""
    IFS=$'\t' read -r delta_input delta_output delta_cc delta_cr delta_turns <<< "$sums"
    delta_input=$(_burn_solo_uint "$delta_input")
    delta_output=$(_burn_solo_uint "$delta_output")
    delta_cc=$(_burn_solo_uint "$delta_cc")
    delta_cr=$(_burn_solo_uint "$delta_cr")
    delta_turns=$(_burn_solo_uint "$delta_turns")

    input_tokens=$(( input_tokens + delta_input ))
    output_tokens=$(( output_tokens + delta_output ))
    cache_creation=$(( cache_creation + delta_cc ))
    cache_read=$(( cache_read + delta_cr ))
    turns=$(( turns + delta_turns ))
    off=$(( off + processed ))

    if [ $(( delta_input + delta_output )) -gt 0 ]; then
      local total_tokens
      total_tokens=$(( input_tokens + output_tokens ))
      jq -cn \
        --argjson ts "$now" \
        --arg channel "${project}:${sid}" \
        --arg sid "$sid" \
        --argjson tokens "$total_tokens" \
        --argjson turns "$turns" \
        --argjson input_tokens "$input_tokens" \
        --argjson output_tokens "$output_tokens" \
        --argjson cache_creation "$cache_creation" \
        --argjson cache_read "$cache_read" \
        '{ts:$ts, channel:$channel, sid:$sid, tokens:$tokens, turns:$turns,
          "in":$input_tokens, out:$output_tokens, cc:$cache_creation, cr:$cache_read}' \
        >> "$ledger" 2>/dev/null || continue
    fi

    state_json=$(_burn_solo_put_state "$state_json" "$key" "$off" "$input_tokens" \
      "$output_tokens" "$cache_creation" "$cache_read" "$turns" "$now")
    state_changed=1
  done

  trap - RETURN

  if [ "$state_changed" -eq 1 ]; then
    local tmp
    tmp="${state}.tmp.$$"
    if printf '%s\n' "$state_json" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi

  return 0
}

# burn_solo_check
# Alert-only spike detection for standalone human-owned Claude Code sessions.
# HARD RULE: this path must never pause, kill, or signal a process; humans run
# these sessions, so solo burn firewall behavior is reporting and notification only.
burn_solo_check() {
  [ "${WARDEN_BURN_ENABLED:-1}" = "1" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local ledger
  ledger=$(burn_solo_ledger)
  [ -f "$ledger" ] || return 0

  local now spike
  now=$(date +%s)
  spike="${WARDEN_BURN_SPIKE_TOKENS_5M:-150000}"
  local since
  since=$(( now - 300 ))

  while IFS='|' read -r channel consumed _turns _tokens_now _last_ts; do
    [ -z "$channel" ] && continue
    if [ "$consumed" -gt "$spike" ] 2>/dev/null; then
      local title detail
      title="burn firewall: standalone Claude Code burning fast"
      detail="${channel}: ${consumed} tokens in 5 minutes (threshold ${spike})"
      if burn_alert "solo-${channel}" "solo" "$channel" "BURN" "$title" "$detail"; then
        [ "${WARDEN_BURN_DESKTOP_NOTIFY:-1}" = "1" ] && notify_desktop "$title" "$detail"
      fi
    fi
  done < <(jq -rRn --argjson since "$since" '
    [inputs | fromjson? // empty | select((.ts // 0) >= $since)] |
    group_by(.channel)[] |
    sort_by(.ts) as $s |
    select(($s | length) >= 2) |
    (reduce range(1; $s | length) as $i (0;
      . + (if ($s[$i].sid // "") != ($s[$i-1].sid // "")
           then ($s[$i].tokens // 0)
           elif ($s[$i].tokens // 0) >= ($s[$i-1].tokens // 0)
           then ($s[$i].tokens // 0) - ($s[$i-1].tokens // 0)
           else ($s[$i].tokens // 0) end))) as $consumed |
    (reduce range(1; $s | length) as $i (0;
      . + (if ($s[$i].sid // "") != ($s[$i-1].sid // "")
           then ($s[$i].turns // 0)
           elif ($s[$i].turns // 0) >= ($s[$i-1].turns // 0)
           then ($s[$i].turns // 0) - ($s[$i-1].turns // 0)
           else ($s[$i].turns // 0) end))) as $turns |
    "\($s[0].channel)|\($consumed)|\($turns)|\($s[-1].tokens // 0)|\($s[-1].ts // 0)"
  ' "$ledger" 2>/dev/null)

  return 0
}

# burn_solo_prune_state [days]
# Drops stale solo state entries only when their last write is older than the
# retention window and the backing transcript is gone or no longer matches the
# stored offset. Live quiet sessions keep their baseline.
burn_solo_prune_state() {
  command -v jq >/dev/null 2>&1 || return 0

  local days="${1:-${WARDEN_BURN_RETENTION_DAYS:-8}}"
  days=$(_burn_solo_uint "$days")
  [ "$days" -gt 0 ] 2>/dev/null || days=8

  local state claude_projects cutoff state_json changed
  state=$(burn_solo_state)
  [ -f "$state" ] || return 0
  claude_projects="${WARDEN_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
  cutoff=$(( $(date +%s) - days * 86400 ))
  state_json=$(_burn_solo_read_state "$state")
  changed=0

  local key ts off project sid file size updated
  while IFS=$'\t' read -r key ts off; do
    [ -n "$key" ] || continue
    ts=$(_burn_solo_uint "$ts")
    off=$(_burn_solo_uint "$off")
    [ "$ts" -lt "$cutoff" ] 2>/dev/null || continue

    project=${key%/*}
    sid=${key#*/}
    file="${claude_projects}/${project}/${sid}.jsonl"
    if [ ! -f "$file" ]; then
      size=0
    else
      size=$(stat_size "$file")
    fi

    if [ ! -f "$file" ] || [ "$size" -lt "$off" ] 2>/dev/null; then
      if updated=$(printf '%s\n' "$state_json" | jq -c --arg k "$key" 'del(.[$k])' 2>/dev/null); then
        state_json="$updated"
        changed=1
      fi
    fi
  done < <(printf '%s\n' "$state_json" | jq -r 'to_entries[] | [.key, (.value.ts // 0), (.value.off // 0)] | @tsv' 2>/dev/null)

  if [ "$changed" -eq 1 ]; then
    local tmp
    tmp="${state}.tmp.$$"
    if printf '%s\n' "$state_json" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi

  return 0
}
