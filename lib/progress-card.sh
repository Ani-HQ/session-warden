#!/usr/bin/env bash
# progress-card.sh — one live long-task card on Discord and Telegram.
#
# Post once, edit in place. The helper owns the bar so agents do not invent
# a new "running…" message every tick. A sheet URL is an optional button,
# not the live indicator.

progress_card_bar_width() {
  local n="${WARDEN_PROGRESS_BAR_WIDTH:-14}"
  case "$n" in
    ''|*[!0-9]*) n=14 ;;
  esac
  [ "$n" -lt 4 ] && n=4
  [ "$n" -gt 40 ] && n=40
  printf '%s' "$n"
}

progress_card_throttle_seconds() {
  local n="${WARDEN_PROGRESS_THROTTLE_SECONDS:-45}"
  case "$n" in
    ''|*[!0-9]*) n=45 ;;
  esac
  printf '%s' "$n"
}

progress_card_every_n() {
  local n="${WARDEN_PROGRESS_EVERY_N:-5}"
  case "$n" in
    ''|*[!0-9]*) n=5 ;;
  esac
  [ "$n" -lt 1 ] && n=1
  printf '%s' "$n"
}

progress_card_int() {
  local n="${1:-0}"
  case "$n" in
    ''|*[!0-9]*) n=0 ;;
  esac
  printf '%s' "$n"
}

# progress_card_bar <n_done> <total> [width]
progress_card_bar() {
  local n_done total width filled i
  n_done="$(progress_card_int "${1:-0}")"
  total="$(progress_card_int "${2:-0}")"
  width="$(progress_card_int "${3:-$(progress_card_bar_width)}")"
  [ "$width" -lt 4 ] && width=4
  [ "$total" -lt 1 ] && total=1
  [ "$n_done" -gt "$total" ] && n_done="$total"
  filled=$((n_done * width / total))
  [ "$filled" -gt "$width" ] && filled="$width"
  for ((i = 0; i < filled; i++)); do printf '█'; done
  for ((i = filled; i < width; i++)); do printf '░'; done
}

progress_card_percent() {
  local n_done total
  n_done="$(progress_card_int "${1:-0}")"
  total="$(progress_card_int "${2:-0}")"
  [ "$total" -lt 1 ] && { printf '0'; return; }
  [ "$n_done" -gt "$total" ] && n_done="$total"
  printf '%s' $((n_done * 100 / total))
}

progress_card_tone() {
  case "${1:-update}" in
    done) printf 'success' ;;
    blocked) printf 'danger' ;;
    start|update|*) printf 'info' ;;
  esac
}

# progress_card_body <title> <n_done> <total> <now> [last]
progress_card_body() {
  local title="$1" n_done="$2" total="$3" now="$4" last="${5:-}"
  local bar pct
  bar="$(progress_card_bar "$n_done" "$total")"
  pct="$(progress_card_percent "$n_done" "$total")"
  printf '%s  %s/%s\n%s  %s%%' "$title" "$(progress_card_int "$n_done")" "$(progress_card_int "$total")" "$bar" "$pct"
  if [ -n "$now" ]; then
    printf '\nnow  %s' "$now"
  fi
  if [ -n "$last" ]; then
    printf '\nlast %s' "$last"
  fi
}

# progress_card_presentation <title> <tone> <text> [sheet_url]
progress_card_presentation() {
  local title="$1" tone="$2" text="$3" sheet="${4:-}"
  if [ -n "$sheet" ]; then
    jq -n --arg title "$title" --arg tone "$tone" --arg text "$text" --arg url "$sheet" '{
      title: $title,
      tone: $tone,
      blocks: [
        {type: "text", text: $text},
        {type: "buttons", buttons: [
          {label: "Open sheet", action: {type: "url", url: $url}}
        ]}
      ]
    }'
  else
    jq -n --arg title "$title" --arg tone "$tone" --arg text "$text" '{
      title: $title,
      tone: $tone,
      blocks: [{type: "text", text: $text}]
    }'
  fi
}

progress_card_slug() {
  local agent="${1:-agent}" channel="${2:-channel}"
  printf '%s-%s' "$agent" "$(printf '%s' "$channel" | sed 's/[^a-zA-Z0-9_-]/_/g')"
}

progress_card_state_path() {
  local slug="$1"
  local dir="${WARDEN_HOME:-$HOME/session-warden}/state/progress"
  mkdir -p "$dir"
  printf '%s/%s.json' "$dir" "$slug"
}

progress_card_normalize_discord_target() {
  local t="$1"
  [ -z "$t" ] && return
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    printf 'channel:%s' "$t"
  else
    printf '%s' "$t"
  fi
}

progress_card_infer_discord() {
  local channel="$1"
  local id=""
  case "$channel" in
    *discord*channel:*)
      id=$(printf '%s' "$channel" | sed -n 's/.*channel:\([0-9][0-9]*\).*/\1/p')
      ;;
    *discord*)
      id=$(printf '%s' "$channel" | grep -oE '[0-9]{10,}' | head -1)
      ;;
  esac
  [ -n "$id" ] && progress_card_normalize_discord_target "$id"
}

progress_card_infer_telegram() {
  local channel="$1"
  case "$channel" in
    *telegram*)
      printf '%s' "$channel" | sed -n 's/.*telegram[:]*//p' | awk -F: '{print $NF}'
      ;;
  esac
}

# Prints "kind target" lines. Honors explicit env overrides, then --channel.
progress_card_collect_targets() {
  local channel="$1"
  local discord telegram
  discord="${PROGRESS_CARD_DISCORD_TARGET:-${WARDEN_PROGRESS_DISCORD_TARGET:-}}"
  telegram="${PROGRESS_CARD_TELEGRAM_TARGET:-${WARDEN_PROGRESS_TELEGRAM_TARGET:-}}"
  if [ -z "$discord" ]; then
    discord="$(progress_card_infer_discord "$channel")"
  fi
  if [ -z "$telegram" ]; then
    telegram="$(progress_card_infer_telegram "$channel")"
  fi
  [ -n "$discord" ] && printf 'discord %s\n' "$(progress_card_normalize_discord_target "$discord")"
  [ -n "$telegram" ] && printf 'telegram %s\n' "$telegram"
}

# progress_card_should_emit <action> <n_done> <now> <state_json>
# 0 = send/edit, 1 = skip (throttled / unchanged).
progress_card_should_emit() {
  local action="$1" n_done="$2" now="$3" state="${4:-}"
  local prev_done last_sent age every throttle now_prev
  case "$action" in
    start|done|blocked) return 0 ;;
  esac
  [ "${PROGRESS_CARD_FORCE:-0}" = "1" ] && return 0
  if [ -z "$state" ] || [ "$state" = "null" ]; then
    return 0
  fi
  prev_done="$(printf '%s' "$state" | jq -r '.done // 0')"
  last_sent="$(printf '%s' "$state" | jq -r '.last_sent_at // 0')"
  now_prev="$(printf '%s' "$state" | jq -r '.now // ""')"
  n_done="$(progress_card_int "$n_done")"
  prev_done="$(progress_card_int "$prev_done")"
  last_sent="$(progress_card_int "$last_sent")"
  age=$(( $(date +%s) - last_sent ))
  every="$(progress_card_every_n)"
  throttle="$(progress_card_throttle_seconds)"
  if [ $((n_done - prev_done)) -ge "$every" ]; then
    return 0
  fi
  if [ "$n_done" != "$prev_done" ] || [ "$now" != "$now_prev" ]; then
    [ "$age" -ge "$throttle" ] && return 0
    return 1
  fi
  return 1
}

progress_card_parse_message_id() {
  local raw="$1"
  printf '%s' "$raw" | jq -r '
    .messageId // .message_id // .id //
    (.message.id // .result.messageId // .result.id // .data.id // empty)
  ' 2>/dev/null | awk 'NF && $0 != "null" {print; exit}'
}

progress_card_openclaw_bin() {
  if command -v openclaw >/dev/null 2>&1; then
    command -v openclaw
    return
  fi
  if [ -x "${HOME}/.npm-global/bin/openclaw" ]; then
    printf '%s' "${HOME}/.npm-global/bin/openclaw"
  fi
}

progress_card_existing_id() {
  local state="$1" kind="$2" target="$3"
  [ -z "$state" ] && return
  printf '%s' "$state" | jq -r --arg k "$kind" --arg t "$target" '
    (.messages // [])[] | select(.channel == $k and .target == $t) | .message_id // empty
  ' | head -1
}

# progress_card_deliver_one <kind> <target> <message> <presentation> <existing_id>
# Prints the message id (existing, newly parsed, or empty).
progress_card_deliver_one() {
  local kind="$1" target="$2" message="$3" presentation="$4" existing="${5:-}"
  local bin extra=() out pin_args=()
  if [ "${WARDEN_DRY_RUN:-0}" = "1" ]; then
    printf 'dry-run %s %s %s\n' "$kind" "$target" "$([ -n "$existing" ] && echo edit || echo send)" >&2
    printf '%s' "${existing:-dry-run}"
    return 0
  fi
  bin="$(progress_card_openclaw_bin)"
  if [ -z "$bin" ]; then
    echo "progress-card: openclaw not on PATH" >&2
    return 1
  fi
  extra=(--channel "$kind" --target "$target" --message "$message" --presentation "$presentation" --json)
  if [ "$kind" = "discord" ] && [ -n "${WARDEN_PROGRESS_DISCORD_ACCOUNT:-}" ]; then
    extra+=(--account "${WARDEN_PROGRESS_DISCORD_ACCOUNT}")
  fi
  if [ "$kind" = "telegram" ] && [ -n "${WARDEN_PROGRESS_TELEGRAM_ACCOUNT:-}" ]; then
    extra+=(--account "${WARDEN_PROGRESS_TELEGRAM_ACCOUNT}")
  fi
  if [ -n "$existing" ]; then
    "$bin" message edit --message-id "$existing" "${extra[@]}" >/dev/null 2>&1 || true
    printf '%s' "$existing"
    return 0
  fi
  if [ "${WARDEN_PROGRESS_PIN:-0}" = "1" ]; then
    pin_args+=(--pin)
  fi
  out=$("$bin" message send "${extra[@]}" "${pin_args[@]}" 2>/dev/null) || true
  progress_card_parse_message_id "$out"
}

progress_card_merge_message() {
  local state="$1" kind="$2" target="$3" mid="$4"
  printf '%s' "${state:-{\}}" | jq --arg k "$kind" --arg t "$target" --arg id "$mid" '
    .messages = ((.messages // []) | map(select(.channel != $k or .target != $t)))
    | if ($id | length) > 0 then .messages += [{channel: $k, target: $t, message_id: $id}] else . end
  '
}

# progress_card_run <action> — reads PROGRESS_CARD_* env vars set by the CLI.
progress_card_run() {
  local action="$1"
  local agent="${PROGRESS_CARD_AGENT:-}"
  local channel="${PROGRESS_CARD_CHANNEL:-}"
  local title="${PROGRESS_CARD_TITLE:-}"
  local n_done="${PROGRESS_CARD_DONE:-}"
  local total="${PROGRESS_CARD_TOTAL:-}"
  local now="${PROGRESS_CARD_NOW:-}"
  local last="${PROGRESS_CARD_LAST:-}"
  local sheet="${PROGRESS_CARD_SHEET_URL:-}"
  local slug path state body presentation tone targets kind target mid existing new_state sent=0

  if [ -z "$agent" ] || [ -z "$channel" ]; then
    echo "progress-card: --agent and --channel are required" >&2
    return 2
  fi

  slug="$(progress_card_slug "$agent" "$channel")"
  path="$(progress_card_state_path "$slug")"
  state=""
  [ -f "$path" ] && state=$(cat "$path")

  if [ -z "$title" ] && [ -n "$state" ]; then
    title=$(printf '%s' "$state" | jq -r '.title // empty')
  fi
  if [ -z "$total" ] && [ -n "$state" ]; then
    total=$(printf '%s' "$state" | jq -r '.total // empty')
  fi
  if [ -z "$sheet" ] && [ -n "$state" ]; then
    sheet=$(printf '%s' "$state" | jq -r '.sheet_url // empty')
  fi
  [ -z "$title" ] && title="long task"
  [ -z "$n_done" ] && n_done=0
  [ -z "$total" ] && total=0
  if [ "$action" = "done" ] && [ "$(progress_card_int "$n_done")" -eq 0 ] && [ "$(progress_card_int "$total")" -gt 0 ]; then
    n_done="$total"
  fi

  if ! progress_card_should_emit "$action" "$n_done" "$now" "$state"; then
    echo "skipped throttle"
    return 0
  fi

  targets="$(progress_card_collect_targets "$channel")"
  if [ -z "$targets" ]; then
    echo "progress-card: no discord/telegram target (set --discord-target, --telegram-target, or a discord channel key)" >&2
    return 2
  fi

  tone="$(progress_card_tone "$action")"
  body="$(progress_card_body "$title" "$n_done" "$total" "$now" "$last")"
  presentation="$(progress_card_presentation "$title" "$tone" "$body" "$sheet")"

  new_state=$(jq -n \
    --arg agent "$agent" --arg channel "$channel" --arg title "$title" \
    --arg now "$now" --arg last "$last" --arg sheet "$sheet" \
    --argjson n_done "$(progress_card_int "$n_done")" \
    --argjson total "$(progress_card_int "$total")" \
    --argjson ts "$(date +%s)" \
    '{
      agent: $agent, channel: $channel, title: $title,
      done: $n_done, total: $total, now: $now, last: $last,
      sheet_url: $sheet, last_sent_at: $ts, messages: []
    }')
  if [ -n "$state" ]; then
    new_state=$(printf '%s\n%s' "$state" "$new_state" | jq -s '
      .[1] + {messages: (.[0].messages // [])}
    ')
  fi

  while read -r kind target; do
    [ -z "$kind" ] && continue
    existing="$(progress_card_existing_id "$new_state" "$kind" "$target")"
    mid="$(progress_card_deliver_one "$kind" "$target" "$body" "$presentation" "$existing" || true)"
    if [ -n "$mid" ]; then
      new_state="$(progress_card_merge_message "$new_state" "$kind" "$target" "$mid")"
      sent=$((sent + 1))
    else
      echo "progress-card: $kind $target delivered without a message id" >&2
    fi
  done <<< "$targets"

  printf '%s\n' "$new_state" > "$path"
  echo "sent $sent"
}
