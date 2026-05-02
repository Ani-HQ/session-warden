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

  # Pass 1: threshold-based detection
  # For status=failed: only flag if updatedAt is stale (>1 hour old).
  # A recent updatedAt means a turn happened after the failure — the session
  # recovered but the gateway didn't clear the status. Don't re-rotate it.
  local now_ms
  now_ms=$(date +%s)000  # epoch milliseconds (updatedAt is ms)
  local failed_stale_ms=120000  # 2 minutes — capture crash context quickly

  jq -r --argjson max_tokens "${WARDEN_MAX_TOKENS}" \
        --argjson max_turns "${WARDEN_MAX_TURNS}" \
        --argjson max_compactions "${WARDEN_MAX_COMPACTIONS}" \
        --argjson now_ms "${now_ms}" \
        --argjson failed_stale_ms "${failed_stale_ms}" '
    to_entries[] |
    if .value.status == "failed" then
      if ($now_ms - (.value.updatedAt // 0)) > $failed_stale_ms then
        "FAILED|\(.key)|\(.value.cliSessionIds["claude-cli"] // "")|status=failed"
      else
        empty
      end
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
  # and a stale JSONL (not modified in 30+ minutes).
  # Skip sessions that were recently recovered to prevent rotation loops where
  # the warden keeps rotating idle-but-healthy agents.
  local now_epoch
  now_epoch=$(date +%s)
  local stale_threshold=1800
  local recovery_grace=7200  # 2 hours: don't re-zombie a recently recovered session

  while IFS='|' read -r channel_key cli_session_id; do
    [ -z "$cli_session_id" ] && continue

    # Check if this session was recently recovered — skip if so
    local recovered_file="${WARDEN_HOME:-$HOME/session-warden}/state/cooldowns/${agent}-$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g').recovered"
    if [ -f "$recovered_file" ]; then
      local recovered_at
      recovered_at=$(cat "$recovered_file" 2>/dev/null || echo 0)
      if [ $((now_epoch - recovered_at)) -lt "$recovery_grace" ]; then
        continue
      fi
    fi

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
