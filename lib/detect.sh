#!/usr/bin/env bash
# detect.sh — find sessions that need rotation

# Returns list of problematic channel keys for a given agent's sessions.json
# Output format: REASON|channel-key|cli-session-id|detail
detect_sessions_problems() {
  local sjson="$1"
  [ -f "$sjson" ] || return 1

  jq -r --argjson max_tokens "${WARDEN_MAX_TOKENS}" \
        --argjson max_compactions "${WARDEN_MAX_COMPACTIONS}" '
    to_entries[] |
    select(.value.cliSessionIds["claude-cli"]) |
    if .value.status == "failed" then
      "FAILED|\(.key)|\(.value.cliSessionIds["claude-cli"])|status=failed"
    elif (.value.totalTokens // 0) > $max_tokens then
      "TOKENS|\(.key)|\(.value.cliSessionIds["claude-cli"])|tokens=\(.value.totalTokens)"
    elif (.value.compactionCount // 0) > $max_compactions then
      "COMPACTIONS|\(.key)|\(.value.cliSessionIds["claude-cli"])|compactions=\(.value.compactionCount)"
    else
      empty
    end
  ' "$sjson" 2>/dev/null
}

agent_from_sessions_path() {
  echo "$1" | sed -E 's|.*/agents/([^/]+)/sessions/.*|\1|'
}
