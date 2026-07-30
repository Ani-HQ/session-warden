#!/usr/bin/env bash
# lib/roster.sh — agent metadata from config/fleet-roster.tsv.
#
# The roster's team column is the single editorial source for which memory
# scope an agent's lessons and skills belong to. An agent that isn't listed
# falls back to "personal", the narrower scope, so a missing or stale roster
# can never widen where something gets written.

WARDEN_ROSTER_FILE="${WARDEN_FLEET_ROSTER:-${WARDEN_HOME}/config/fleet-roster.tsv}"

# roster_agents — echo every agent id in the roster, space-separated
roster_agents() {
  local agent
  [ -f "$WARDEN_ROSTER_FILE" ] || return 0
  while IFS=$'\t' read -r agent _rest; do
    case "$agent" in ''|'#'*) continue ;; esac
    printf '%s ' "$agent"
  done < "$WARDEN_ROSTER_FILE"
}

# team_for <agent> — echo the agent's team, or "personal" if unknown
team_for() {
  local want="$1" agent team
  [ -f "$WARDEN_ROSTER_FILE" ] || { echo "personal"; return; }
  while IFS=$'\t' read -r agent team _rest; do
    case "$agent" in ''|'#'*) continue ;; esac
    if [ "$agent" = "$want" ]; then
      echo "${team:-personal}"
      return
    fi
  done < "$WARDEN_ROSTER_FILE"
  echo "personal"
}
