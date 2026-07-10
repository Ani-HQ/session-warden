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
  local cache_creation="$6" cache_read="$7" turns="$8"
  local updated

  if updated=$(printf '%s\n' "$state_json" | jq -c \
    --arg k "$key" \
    --argjson off "$off" \
    --argjson input_tokens "$input_tokens" \
    --argjson output_tokens "$output_tokens" \
    --argjson cache_creation "$cache_creation" \
    --argjson cache_read "$cache_read" \
    --argjson turns "$turns" \
    '.[$k] = {
      off: $off,
      "in": $input_tokens,
      out: $output_tokens,
      cc: $cache_creation,
      cr: $cache_read,
      turns: $turns
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

  local jsonl
  for jsonl in "$claude_projects"/*/*.jsonl; do
    [ -f "$jsonl" ] || continue

    local project_dir project sid key mtime size row
    project_dir=$(dirname "$jsonl")
    project=$(basename "$project_dir")
    case "$project" in
      *-openclaw-agents-*) continue ;;
    esac

    mtime=$(stat_mtime "$jsonl")
    [ "$mtime" -ge "$cutoff" ] 2>/dev/null || continue

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

    if [ "$known" -eq 0 ]; then
      state_json=$(_burn_solo_put_state "$state_json" "$key" "$size" 0 0 0 0 0)
      state_changed=1
      continue
    fi

    local reset
    reset=0
    if [ "$size" -lt "$off" ] 2>/dev/null; then
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
          "$output_tokens" "$cache_creation" "$cache_read" "$turns")
        state_changed=1
      fi
      continue
    fi

    local chunk start processed line line_bytes
    if ! chunk=$(mktemp "${dir}/solo-chunk.XXXXXX" 2>/dev/null); then
      chunk="${dir}/solo-chunk.$$"
      : > "$chunk" 2>/dev/null || continue
    fi
    : > "$chunk" 2>/dev/null || { rm -f "$chunk"; continue; }

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
      if [ "$reset" -eq 1 ]; then
        state_json=$(_burn_solo_put_state "$state_json" "$key" "$off" "$input_tokens" \
          "$output_tokens" "$cache_creation" "$cache_read" "$turns")
        state_changed=1
      fi
      continue
    fi

    local sums delta_input delta_output delta_cc delta_cr delta_turns
    sums=$(_burn_solo_parse_chunk "$chunk")
    rm -f "$chunk"
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
      "$output_tokens" "$cache_creation" "$cache_read" "$turns")
    state_changed=1
  done

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
