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
  # Generic alert for one-off subsystems (e.g. channel-parity self-heal).
  local title="$1" details="${2:-}"

  [ -z "${WARDEN_TELEGRAM_BOT_TOKEN:-}" ] && return 0
  [ -z "${WARDEN_TELEGRAM_CHAT_ID:-}" ] && return 0

  local msg="🚨 *session-warden:* ${title}
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

  local msg="🌙 *session-warden reflector* — $(date +%Y-%m-%d)

${summary}"

  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
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

  local msg="🧰 *session-warden skill harvester* — $(date +%Y-%m-%d)

${summary}"

  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${WARDEN_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${WARDEN_TELEGRAM_CHAT_ID}" \
    -d "parse_mode=Markdown" \
    --data-urlencode "text=${msg}" 2>/dev/null)
  echo "$resp" | grep -q "\"ok\":true"
}
