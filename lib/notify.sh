#!/usr/bin/env bash
# notify.sh — send rotation alerts via Telegram

notify_rotation() {
  local agent="$1" channel="$2" reason="$3" details="$4"

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
