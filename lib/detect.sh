#!/usr/bin/env bash
# detect.sh — find sessions that need rotation

# Check if a CLI process is alive for a given session ID
is_cli_process_alive() {
  local cli_session_id="$1"
  pgrep -f "claude.*${cli_session_id}" >/dev/null 2>&1
}

# Returns list of problematic channel keys for a given agent's sessions.json
# Output format: REASON|channel-key|cli-session-id|detail
detect_sessions_problems() {
  local sjson="$1"
  [ -f "$sjson" ] || return 1

  local agent
  agent=$(agent_from_sessions_path "$sjson")
  local jsonl_base="${WARDEN_CLAUDE_PROJECTS}/-home-$(whoami)--openclaw-agents-${agent}"

  # Pass 1: threshold-based detection (original logic)
  # Also catches status=failed with null cliSessionIds (use empty string for rotate)
  jq -r --argjson max_tokens "${WARDEN_MAX_TOKENS}" \
        --argjson max_turns "${WARDEN_MAX_TURNS}" \
        --argjson max_compactions "${WARDEN_MAX_COMPACTIONS}" '
    to_entries[] |
    if .value.status == "failed" then
      "FAILED|\(.key)|\(.value.cliSessionIds["claude-cli"] // "")|status=failed"
    elif (.value.cliSessionIds["claude-cli"] // "" | length > 0) then
      if .value.status == "running" then
        empty
      elif (.value.totalTokens // 0) > $max_tokens then
        "TOKENS|\(.key)|\(.value.cliSessionIds["claude-cli"])|tokens=\(.value.totalTokens)"
      elif (.value.numTurns // 0) > $max_turns then
        "TURNS|\(.key)|\(.value.cliSessionIds["claude-cli"])|turns=\(.value.numTurns)"
      elif (.value.compactionCount // 0) > $max_compactions then
        "COMPACTIONS|\(.key)|\(.value.cliSessionIds["claude-cli"])|compactions=\(.value.compactionCount)"
      else
        empty
      end
    else
      empty
    end
  ' "$sjson" 2>/dev/null

  # Pass 2: zombie detection — sessions with a CLI session ID but no live process
  # and a stale JSONL (not modified in 30+ minutes)
  local now_epoch
  now_epoch=$(date +%s)
  local stale_threshold=1800

  while IFS='|' read -r channel_key cli_session_id; do
    [ -z "$cli_session_id" ] && continue
    if ! is_cli_process_alive "$cli_session_id"; then
      local jsonl_file="${jsonl_base}/${cli_session_id}.jsonl"
      local is_stale=0
      if [ -f "$jsonl_file" ]; then
        local mtime
        mtime=$(stat -c%Y "$jsonl_file" 2>/dev/null || echo 0)
        [ $((now_epoch - mtime)) -gt "$stale_threshold" ] && is_stale=1
      else
        is_stale=1
      fi
      if [ "$is_stale" -eq 1 ]; then
        echo "ZOMBIE|${channel_key}|${cli_session_id}|process_dead+stale_jsonl"
      fi
    fi
  done < <(jq -r '
    to_entries[] |
    select(.value.cliSessionIds["claude-cli"] // "" | length > 0) |
    select(.value.status != "failed") |
    "\(.key)|\(.value.cliSessionIds["claude-cli"])"
  ' "$sjson" 2>/dev/null)
}

agent_from_sessions_path() {
  echo "$1" | sed -E 's|.*/agents/([^/]+)/sessions/.*|\1|'
}
