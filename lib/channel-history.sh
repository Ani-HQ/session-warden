#!/usr/bin/env bash
# channel-history.sh — fetch recent messages from Discord/Telegram channels
# Used by crash-recovery buffer to capture unprocessed messages after agent failures.

OPENCLAW_JSON="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}/openclaw.json"
CRASH_BUFFER_DIR="${WARDEN_HOME:-$HOME/session-warden}/state/crash-buffers"
CRASH_BUFFER_TTL_SECONDS="${WARDEN_CRASH_BUFFER_TTL:-7200}"  # 2 hours

mkdir -p "$CRASH_BUFFER_DIR"

# Get Discord bot token for an agent from openclaw.json
_get_discord_token() {
  local agent="$1"
  python3 -c "
import json
with open('${OPENCLAW_JSON}') as f:
    d = json.load(f)
accounts = d.get('channels', {}).get('discord', {}).get('accounts', {})
acct = accounts.get('${agent}', accounts.get('default', {}))
print(acct.get('token', ''))
" 2>/dev/null
}

# Get Telegram bot token for an agent from openclaw.json
_get_telegram_token() {
  local agent="$1"
  python3 -c "
import json
with open('${OPENCLAW_JSON}') as f:
    d = json.load(f)
accounts = d.get('channels', {}).get('telegram', {}).get('accounts', {})
acct = accounts.get('${agent}', accounts.get('default', {}))
print(acct.get('token', ''))
" 2>/dev/null
}

# Resolve Discord channel ID for a session.
# For DMs (to=user:XXX), opens a DM channel first.
# For channels (to=channel:XXX), uses the channel ID directly.
_resolve_discord_channel_id() {
  local token="$1" delivery_to="$2"

  if [[ "$delivery_to" == channel:* ]]; then
    echo "${delivery_to#channel:}"
    return 0
  fi

  if [[ "$delivery_to" == user:* ]]; then
    local user_id="${delivery_to#user:}"
    local dm_channel
    dm_channel=$(curl -s -X POST "https://discord.com/api/v10/users/@me/channels" \
      -H "Authorization: Bot ${token}" \
      -H "Content-Type: application/json" \
      -d "{\"recipient_id\": \"${user_id}\"}" 2>/dev/null | \
      python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    echo "$dm_channel"
    return 0
  fi

  return 1
}

# Fetch last N messages from a Discord channel.
# Returns JSON array: [{timestamp, author, content, id}]
_fetch_discord_messages() {
  local token="$1" channel_id="$2" limit="${3:-10}"
  [ -z "$token" ] || [ -z "$channel_id" ] && return 1

  curl -s -H "Authorization: Bot ${token}" \
    "https://discord.com/api/v10/channels/${channel_id}/messages?limit=${limit}" 2>/dev/null | \
  python3 -c "
import json, sys
try:
    msgs = json.loads(sys.stdin.read())
    if not isinstance(msgs, list):
        sys.exit(0)
    result = []
    for msg in reversed(msgs):
        result.append({
            'id': msg.get('id', ''),
            'timestamp': msg.get('timestamp', ''),
            'author': msg.get('author', {}).get('username', '?'),
            'author_id': msg.get('author', {}).get('id', ''),
            'is_bot': msg.get('author', {}).get('bot', False),
            'content': msg.get('content', '')
        })
    print(json.dumps(result))
except Exception as e:
    print('[]')
" 2>/dev/null
}

# Fetch last N messages from a Telegram chat.
# Returns JSON array: [{timestamp, author, content, id}]
_fetch_telegram_messages() {
  local token="$1" chat_id="$2" limit="${3:-10}"
  [ -z "$token" ] || [ -z "$chat_id" ] && return 1

  # Telegram getUpdates doesn't support chat-specific history.
  # Use getChat + forwardMessage workaround, or just note that
  # Telegram doesn't expose chat history to bots natively.
  # For now, return empty — Telegram agents use offset-based polling
  # and the gateway has the messages in its own memory.
  echo "[]"
}

# Get session metadata from sessions.json.
# Returns: provider, delivery_to, updatedAt (pipe-separated)
_get_session_metadata() {
  local agent="$1" channel_key="$2"
  local sjson="${WARDEN_OPENCLAW_HOME}/agents/${agent}/sessions/sessions.json"
  [ -f "$sjson" ] || return 1

  jq -r --arg key "$channel_key" '
    .[$key] //empty |
    "\(.origin.provider // .deliveryContext.channel // "unknown")|\(.deliveryContext.to // "")|\(.updatedAt // 0)"
  ' "$sjson" 2>/dev/null
}

# Main entry: fetch recent messages for an agent/channel and identify unprocessed ones.
# Writes crash buffer to state/crash-buffers/{agent}-{safe_channel}.json
# Args: $1=agent, $2=channel_key, $3=session_updated_at (epoch ms)
# Returns: 0 if buffer written, 1 if no unprocessed messages found
capture_crash_buffer() {
  local agent="$1" channel_key="$2" session_updated_at="${3:-0}"
  local safe_channel
  safe_channel=$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g')
  local buffer_file="${CRASH_BUFFER_DIR}/${agent}-${safe_channel}.json"

  # Get session metadata
  local metadata
  metadata=$(_get_session_metadata "$agent" "$channel_key")
  [ -z "$metadata" ] && return 1

  local provider delivery_to updated_at
  # shellcheck disable=SC2034  # updated_at is a placeholder for the trailing field
  IFS='|' read -r provider delivery_to updated_at <<< "$metadata"

  local messages="[]"

  if [ "$provider" = "discord" ]; then
    local token
    token=$(_get_discord_token "$agent")
    [ -z "$token" ] && { log "CRASH-BUFFER: no Discord token for $agent"; return 1; }

    local channel_id
    channel_id=$(_resolve_discord_channel_id "$token" "$delivery_to")
    [ -z "$channel_id" ] && { log "CRASH-BUFFER: could not resolve Discord channel for $delivery_to"; return 1; }

    messages=$(_fetch_discord_messages "$token" "$channel_id" 15)

  elif [ "$provider" = "telegram" ]; then
    log "CRASH-BUFFER: Telegram history not yet supported — skipping"
    return 1
  else
    log "CRASH-BUFFER: unknown provider $provider for $agent/$channel_key"
    return 1
  fi

  # Detect unprocessed messages using standalone Python script
  local _cb_msgs_file _cb_result_file
  _cb_msgs_file=$(mktemp /tmp/crash-buffer-msgs-XXXXXX.json)
  _cb_result_file=$(mktemp /tmp/crash-buffer-result-XXXXXX.json)
  echo "$messages" > "$_cb_msgs_file"

  local _cb_lib_dir="${WARDEN_HOME}/lib"
  python3 "${_cb_lib_dir}/detect-unprocessed.py" "$_cb_msgs_file" > "$_cb_result_file" 2>/dev/null
  rm -f "$_cb_msgs_file"

  local unprocessed_count
  unprocessed_count=$(jq '.unprocessed | length' "$_cb_result_file" 2>/dev/null)

  if [ "${unprocessed_count:-0}" -eq 0 ]; then
    rm -f "$_cb_result_file"
    log "CRASH-BUFFER: no unprocessed messages found for $agent/$channel_key"
    return 1
  fi

  # Write crash buffer using standalone Python script
  local now_epoch
  now_epoch=$(date +%s)
  python3 "${_cb_lib_dir}/write-crash-buffer.py" \
    "$_cb_result_file" "$buffer_file" \
    "$agent" "$channel_key" "$provider" \
    "$now_epoch" "$session_updated_at" 2>/dev/null

  rm -f "$_cb_result_file"

  log "CRASH-BUFFER: captured ${unprocessed_count} unprocessed message(s) for $agent/$channel_key → $buffer_file"
  return 0
}

# Read crash buffer and return formatted text for inclusion in CONTEXT.md
# Args: $1=agent, $2=channel_key
# Returns: formatted text on stdout, empty if no buffer exists or expired
read_crash_buffer() {
  local agent="$1" channel_key="$2"
  local safe_channel
  safe_channel=$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g')
  local buffer_file="${CRASH_BUFFER_DIR}/${agent}-${safe_channel}.json"

  [ -f "$buffer_file" ] || return 0

  # Check TTL
  local now_epoch captured_at
  now_epoch=$(date +%s)
  captured_at=$(jq -r '.captured_at // 0' "$buffer_file" 2>/dev/null)
  if [ $((now_epoch - captured_at)) -gt "$CRASH_BUFFER_TTL_SECONDS" ]; then
    rm -f "$buffer_file"
    return 0
  fi

  python3 -c "
import json

with open('${buffer_file}') as f:
    buf = json.load(f)

unprocessed = buf.get('unprocessed_messages', [])
last_bot = buf.get('last_bot_message')

if not unprocessed:
    exit(0)

lines = []
lines.append('## Unprocessed Messages (recovered from channel after crash)')
lines.append('')
lines.append('These messages were sent by team members but you crashed before processing them.')
lines.append('**Execute these instructions immediately without asking anyone to repeat themselves.**')
lines.append('')

if last_bot:
    lines.append('### Your last response before crash:')
    content = last_bot.get('content', '(empty)')
    if len(content) > 500:
        content = content[:500] + '...'
    lines.append(f'> {content}')
    lines.append('')

lines.append('### Messages you need to act on:')
for msg in unprocessed:
    author = msg.get('author', '?')
    content = msg.get('content', '')
    ts = msg.get('timestamp', '')
    lines.append(f'**{author}** ({ts}):')
    lines.append(f'> {content}')
    lines.append('')

print('\n'.join(lines))
" 2>/dev/null
}

# Clear crash buffer for an agent/channel (call after successful recovery)
# Args: $1=agent, $2=channel_key
clear_crash_buffer() {
  local agent="$1" channel_key="$2"
  local safe_channel
  safe_channel=$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g')
  local buffer_file="${CRASH_BUFFER_DIR}/${agent}-${safe_channel}.json"
  if [ -f "$buffer_file" ]; then
    rm -f "$buffer_file"
    log "CRASH-BUFFER: cleared for $agent/$channel_key"
  fi
}

# Cleanup expired crash buffers (run periodically)
cleanup_expired_crash_buffers() {
  local now_epoch
  now_epoch=$(date +%s)
  for bf in "${CRASH_BUFFER_DIR}"/*.json; do
    [ -f "$bf" ] || continue
    local captured_at
    captured_at=$(jq -r '.captured_at // 0' "$bf" 2>/dev/null)
    if [ $((now_epoch - captured_at)) -gt "$CRASH_BUFFER_TTL_SECONDS" ]; then
      rm -f "$bf"
    fi
  done
}
