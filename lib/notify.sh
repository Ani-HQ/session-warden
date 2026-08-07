#!/usr/bin/env bash
# notify.sh — send rotation alerts via Telegram

notify_rotation() {
  local agent="$1" channel="$2" reason="$3" details="$4"

  # Rotations are routine self-healing — operator-grade noise, not for the
  # user's chat. Opt back in with WARDEN_NOTIFY_ROTATIONS=1. Doctor UNHEALTHY
  # alerts (real failures) are unaffected. Rotations remain in the warden logs.
  [ "${WARDEN_NOTIFY_ROTATIONS:-0}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local ts
  ts=$(date '+%H:%M:%S %Z')

  local msg="🔄 *session-warden rotated* \`${agent}\`

*Channel:* \`${channel}\`
*Reason:* ${reason}
*Time:* ${ts}
${details:+
\`\`\`
${details}
\`\`\`}"

  curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" \
    > /dev/null 2>&1 || true
}

notify_doctor() {
  local summary="$1" details="$2"

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg="🚨 *session-warden doctor: UNHEALTHY*

${summary}
${details:+
\`\`\`
${details}
\`\`\`}"

  curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" \
    > /dev/null 2>&1 || true
}

notify_alert() {
  # Generic alert for one-off subsystems (e.g. channel-parity self-heal,
  # burn firewall). Called from the 30s scan loop, so the send is time-bounded:
  # a blackholed api.telegram.org must never stall scanning for the fleet.
  local title="$1" details="${2:-}"

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg="🚨 *session-warden:* ${title}
${details:+
\`\`\`
${details}
\`\`\`}"

  curl -s --connect-timeout 5 --max-time 15 \
    -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" \
    > /dev/null 2>&1 || true
}

_notify_applescript_string() {
  local text="$1"
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  printf '%s' "$text"
}

notify_desktop() {
  local title="$1" detail="${2:-}"
  local osascript_cmd title_escaped detail_escaped

  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
  osascript_cmd=$(command -v osascript 2>/dev/null) || return 0
  [ -n "$osascript_cmd" ] || return 0

  title_escaped=$(_notify_applescript_string "$title")
  detail_escaped=$(_notify_applescript_string "$detail")
  "$osascript_cmd" -e "display notification \"${detail_escaped}\" with title \"${title_escaped}\"" \
    > /dev/null 2>&1 || true
  return 0
}

notify_backoff() {
  # One-shot escalation when a session hits WARDEN_MAX_CONSECUTIVE_FAILURES and
  # enters BACKOFF (bin/rotate.sh). Sent once per backoff episode — the
  # .backoff-alerted marker gates repeats. Always sends (a wedged session is a
  # real failure, not routine rotation noise).
  local agent="$1" channel="$2" fail_count="$3"

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg="🛑 *session-warden BACKOFF* \`${agent}\`

*Channel:* \`${channel}\`
*Consecutive failures:* ${fail_count}

Rotation is suspended for this session until the failure counter clears. Inspect it with the CLI:
\`\`\`
session-warden status
session-warden logs
session-warden rotate ${agent} ${channel}
\`\`\`"

  curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" \
    > /dev/null 2>&1 || true
}

notify_test() {
  notify_rotation "test-agent" "test-channel" "Test alert" "session-warden online"
}

notify_reflector() {
  # Nightly reflector digest (bin/reflect.sh). Informational, one per run.
  # Returns non-zero if the send fails so the reflector can log it.
  local summary="$1"

  [ "${WARDEN_REFLECT_NOTIFY:-1}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg
  msg="🌙 *session-warden reflector* — $(date +%Y-%m-%d)

${summary}"

  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" 2>/dev/null)
  echo "$resp" | grep -q "\"ok\":true"
}

notify_burn_digest() {
  # Daily burn-firewall digest (lib/burn.sh burn_daily_digest). Informational,
  # one per day. Returns non-zero if the send fails so the caller can log it.
  # Sent as PLAIN TEXT deliberately: the body contains agent/channel names
  # (underscores etc.) that Telegram's Markdown parser rejects, and a parse
  # rejection would silently eat the digest. Time-bounded like notify_alert —
  # this runs inside the scan loop.
  local summary="$1"

  [ "${WARDEN_BURN_DIGEST_NOTIFY:-1}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg
  msg="🔥 session-warden burn report — $(date +%Y-%m-%d)

${summary}"

  local resp
  resp=$(curl -s --connect-timeout 5 --max-time 15 \
    -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${msg}" 2>/dev/null)
  echo "$resp" | grep -q "\"ok\":true"
}

notify_harvester() {
  # Weekly skill-harvester digest (bin/harvest-skills.sh). Informational, one per run.
  # Returns non-zero if the send fails so the harvester can log it.
  local summary="$1"

  [ "${WARDEN_HARVEST_NOTIFY:-1}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg
  msg="🧰 *session-warden skill harvester* — $(date +%Y-%m-%d)

${summary}"

  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" 2>/dev/null)
  echo "$resp" | grep -q "\"ok\":true"
}

notify_harvest_skill_discord() {
  # One interactive Discord message per staged skill proposal
  # (bin/harvest-skills.sh): Promote / Promote shared / Reject / View draft.
  #
  # Two delivery paths (first match wins):
  #   1. OpenClaw presentation — when WARDEN_HARVEST_DISCORD_ACCOUNT is set
  #      (preferred on fleets that already run Discord via OpenClaw). Posts via
  #      `openclaw message send --presentation`; clicks are handled by the
  #      harvest-skill-actions OpenClaw plugin (no second Discord gateway).
  #   2. Raw Discord bot REST — when WARDEN_DISCORD_BOT_TOKEN is set. Clicks
  #      are handled by contrib/discord-harvest-actions (bin/harvest-actions.sh).
  #
  # Silently no-ops when Discord isn't configured (returns 0 — "skipped" is
  # not a failure); returns non-zero only on a failed send so the harvester
  # can log it.
  local agent="$1" skill="$2" desc="${3:-}"

  [ "${WARDEN_HARVEST_NOTIFY_DISCORD:-1}" = "1" ] || return 0
  [ -z "${WARDEN_HARVEST_DISCORD_CHANNEL_ID:-}" ] && return 0
  command -v jq >/dev/null 2>&1 || return 1

  local content="🧰 **skill proposal** — \`${agent}\`: \`${skill}\`"
  [ -n "$desc" ] && content="${content}
${desc}"

  # --- Path 1: OpenClaw presentation (fleet-native) ------------------------
  if [ -n "${WARDEN_HARVEST_DISCORD_ACCOUNT:-}" ]; then
    local openclaw_bin presentation
    openclaw_bin=$(command -v openclaw 2>/dev/null || true)
    [ -z "$openclaw_bin" ] && [ -x "${HOME}/.npm-global/bin/openclaw" ] \
      && openclaw_bin="${HOME}/.npm-global/bin/openclaw"
    [ -n "$openclaw_bin" ] || return 1

    if [ $((${#agent} + ${#skill} + 24)) -le 100 ]; then
      presentation=$(jq -n --arg a "$agent" --arg s "$skill" '{
        blocks: [{
          type: "buttons",
          buttons: [
            {label: "Promote",        style: "success", action: {type: "callback", value: ("harvest:promote:" + $a + ":" + $s)}},
            {label: "Promote shared", style: "primary", action: {type: "callback", value: ("harvest:promote-shared:" + $a + ":" + $s)}},
            {label: "Reject",         style: "danger",  action: {type: "callback", value: ("harvest:reject:" + $a + ":" + $s)}},
            {label: "View draft",     style: "secondary", action: {type: "callback", value: ("harvest:view:" + $a + ":" + $s)}}
          ]
        }]
      }')
    else
      presentation='{"blocks":[]}'
    fi

    "$openclaw_bin" message send \
      --channel discord \
      --account "${WARDEN_HARVEST_DISCORD_ACCOUNT}" \
      --target "${WARDEN_HARVEST_DISCORD_CHANNEL_ID}" \
      --message "$content" \
      --presentation "$presentation" \
      --json >/dev/null 2>&1
    return $?
  fi

  # --- Path 2: dedicated Discord bot REST ----------------------------------
  [ -z "${WARDEN_DISCORD_BOT_TOKEN:-}" ] && return 0

  local payload
  if [ $((${#agent} + ${#skill} + 24)) -le 100 ]; then
    payload=$(jq -n --arg content "$content" --arg a "$agent" --arg s "$skill" '{
      content: $content,
      components: [{
        type: 1,
        components: [
          {type: 2, style: 3, label: "Promote",        custom_id: ("harvest:promote:" + $a + ":" + $s)},
          {type: 2, style: 1, label: "Promote shared", custom_id: ("harvest:promote-shared:" + $a + ":" + $s)},
          {type: 2, style: 4, label: "Reject",         custom_id: ("harvest:reject:" + $a + ":" + $s)},
          {type: 2, style: 2, label: "View draft",     custom_id: ("harvest:view:" + $a + ":" + $s)}
        ]
      }]
    }')
  else
    payload=$(jq -n --arg content "$content" '{content: $content}')
  fi

  local resp
  resp=$(curl -s --connect-timeout 5 --max-time 15 \
    -X POST "https://discord.com/api/v10/channels/${WARDEN_HARVEST_DISCORD_CHANNEL_ID}/messages" \
    -H "Authorization: Bot ${WARDEN_DISCORD_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)
  echo "$resp" | jq -e '.id' >/dev/null 2>&1
}

notify_scorecard() {
  # Weekly model-scorecard digest (bin/scorecard.sh). Informational, one per run.
  # Returns non-zero if the send fails so the scorecard can log it.
  local summary="$1"

  [ "${WARDEN_SCORECARD_NOTIFY:-1}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg
  msg="🏁 *session-warden model scorecard* — $(date +%Y-%m-%d)

${summary}"

  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" 2>/dev/null)
  echo "$resp" | grep -q "\"ok\":true"
}

notify_evals() {
  # Monthly memory-evals digest (bin/eval-memory.sh). Informational, one per run.
  # Returns non-zero if the send fails so the eval runner can log it.
  local summary="$1"

  [ "${WARDEN_EVAL_NOTIFY:-1}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg
  msg="🧪 *session-warden memory evals* — $(date +%Y-%m-%d)

${summary}"

  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" 2>/dev/null)
  echo "$resp" | grep -q "\"ok\":true"
}

notify_fleet() {
  # Weekly fleet-review digest (bin/fleet-review.sh). Informational, one per run.
  # Returns non-zero if the send fails so the reviewer can log it.
  local summary="$1"

  [ "${WARDEN_FLEET_NOTIFY:-1}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg
  msg="📋 *session-warden fleet review* — $(date +%Y-%m-%d)

${summary}"

  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" 2>/dev/null)
  echo "$resp" | grep -q "\"ok\":true"
}

notify_rate_limit() {
  # One-shot when rate-guard demotes a provider (bin/rate-guard.sh).
  # Plain text: provider/detail strings can break Telegram Markdown.
  # Time-bounded — the timer must never stall on a blackholed api.telegram.org.
  local provider="$1" detail="${2:-}" until="${3:-unknown}"

  [ "${WARDEN_RATE_GUARD_NOTIFY:-1}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg
  msg="⚠️ session-warden rate guard

${provider} hit a limit${detail:+ (${detail})}.
Demoted fleet-wide until ${until}.
Team channels stay quiet — this is the only alert."

  curl -s --connect-timeout 5 --max-time 15 \
    -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    > /dev/null 2>&1 || true
}

notify_rate_limit_cleared() {
  # One-shot when rate-guard restores baseline chains after resets_at.
  local provider="$1"

  [ "${WARDEN_RATE_GUARD_NOTIFY:-1}" = "1" ] || return 0

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg
  msg="✅ session-warden rate guard

${provider} is back. Restored baseline model chains."

  curl -s --connect-timeout 5 --max-time 15 \
    -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    > /dev/null 2>&1 || true
}
