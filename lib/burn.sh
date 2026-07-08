#!/usr/bin/env bash
# burn.sh — subscription-usage ledger for the burn firewall
#
# Samples per-channel token counters from an agent's sessions.json into an
# append-only ledger at state/burn/<agent>.jsonl. One JSON record per change:
#   {"ts":<epoch>,"channel":"...","sid":"...","tokens":N,"turns":N}
# Records are cumulative snapshots (not deltas) — deltas are computed at read
# time by the reporting layer, so a missed sample never corrupts the ledger.
#
# Session Warden's job here is protecting a Claude *subscription* window:
# the ledger is the ground truth for "what ate my usage" and for the
# BURN/LOOP/BUDGET detection built on top of it.

_BURN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_BURN_LIB_DIR}/agent-attribution.sh"

burn_ledger_dir() {
  echo "${WARDEN_HOME:-$HOME/session-warden}/state/burn"
}

# burn_sample_agent <sessions.json path>
# Appends one ledger record per channel whose token count changed since the
# last sample. No-op when WARDEN_BURN_ENABLED=0. Never fails the caller.
burn_sample_agent() {
  [ "${WARDEN_BURN_ENABLED:-1}" = "1" ] || return 0

  local sjson="$1"
  [ -f "$sjson" ] || return 0

  local agent ledger dir now
  agent=$(agent_from_sessions_path "$sjson")
  dir=$(burn_ledger_dir)
  ledger="${dir}/${agent}.jsonl"
  mkdir -p "$dir"
  now=$(date +%s)

  # channel|sid|tokens|turns for every channel bound to a claude-cli session
  while IFS='|' read -r channel sid tokens turns; do
    [ -z "$channel" ] && continue

    # Skip when the token counter hasn't moved since the last record for
    # this channel — keeps the ledger tiny on idle fleets.
    local last_tokens=""
    if [ -f "$ledger" ]; then
      last_tokens=$(jq -r --arg ch "$channel" \
        'select(.channel == $ch) | .tokens' "$ledger" 2>/dev/null | tail -1)
    fi
    [ "$last_tokens" = "$tokens" ] && continue

    jq -cn --argjson ts "$now" --arg channel "$channel" --arg sid "$sid" \
           --argjson tokens "${tokens:-0}" --argjson turns "${turns:-0}" \
           '{ts:$ts, channel:$channel, sid:$sid, tokens:$tokens, turns:$turns}' \
      >> "$ledger" 2>/dev/null || true
  done < <(jq -r '
    to_entries[] |
    select(.value.cliSessionIds["claude-cli"] // "" | length > 0) |
    "\(.key)|\(.value.cliSessionIds["claude-cli"])|\(.value.totalTokens // 0)|\(.value.numTurns // 0)"
  ' "$sjson" 2>/dev/null)

  return 0
}

# burn_prune [days]
# Drops ledger records older than N days (default WARDEN_BURN_RETENTION_DAYS,
# default 8 — a full week of windows plus slack). Called from cleanup.
burn_prune() {
  local days="${1:-${WARDEN_BURN_RETENTION_DAYS:-8}}"
  local dir cutoff f tmp
  dir=$(burn_ledger_dir)
  [ -d "$dir" ] || return 0
  cutoff=$(( $(date +%s) - days * 86400 ))

  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    tmp="${f}.tmp.$$"
    if jq -c --argjson cutoff "$cutoff" 'select(.ts >= $cutoff)' "$f" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  done
  return 0
}
