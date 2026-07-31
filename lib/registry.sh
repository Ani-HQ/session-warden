#!/usr/bin/env bash
# lib/registry.sh — which agents openclaw itself says exist.
#
# Warden used to discover agents by globbing agents/*/sessions/sessions.json,
# which made retirement something it could not observe: a retired agent keeps
# its directory, so warden kept rotating it, and every rotation ends in a
# recovery message that wakes the agent again. Four agents stayed alive that
# way for two days after being retired.
#
# openclaw.json's agents.list is the runtime's own declaration of which agents
# exist, and removing an agent from it is already part of retiring one, so it
# is the authority warden should follow.

WARDEN_OPENCLAW_CONFIG="${WARDEN_OPENCLAW_CONFIG:-${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}/openclaw.json}"

# Session directories openclaw creates for its own use rather than for a
# declared agent — subagent spawn pools, mostly. They have never been rotated
# and must not be reported as strays. Override if your install adds others.
WARDEN_UNMANAGED_AGENTS="${WARDEN_UNMANAGED_AGENTS:-claude claude-code main}"

# declared_agents — echo every agent id in openclaw.json, space-separated.
# Empty output means "no opinion" (missing or unreadable config), and every
# caller must fall back to scanning everything rather than nothing: a config
# that fails to parse must never silently switch supervision off.
declared_agents() {
  [ -f "$WARDEN_OPENCLAW_CONFIG" ] || return 0
  jq -r '
    (.agents.list // [])
    | map(if type == "string" then . else (.id // .name // empty) end)
    | .[]
  ' "$WARDEN_OPENCLAW_CONFIG" 2>/dev/null | tr '\n' ' '
}

# agent_is_pool <agent> — 0 if this directory belongs to openclaw rather than
# to an agent. Kept separate from declaration so callers can tell the two
# reasons apart: a pool is skipped in silence, while an undeclared agent that
# is still running is a leak someone needs to hear about.
agent_is_pool() {
  local want="$1" a
  for a in $WARDEN_UNMANAGED_AGENTS; do
    [ "$a" = "$want" ] && return 0
  done
  return 1
}

# agent_is_declared <agent> [declared] — 0 if openclaw declares this agent.
# An empty declaration list means "no opinion" and answers yes, so a missing or
# unparseable config can never switch supervision off for the whole fleet.
# Pass the pre-resolved list as $2 to avoid re-reading the config per agent.
agent_is_declared() {
  local want="$1" declared="${2:-$(declared_agents)}"
  [ -n "$declared" ] || return 0
  case " $declared " in *" $want "*) return 0 ;; esac
  return 1
}

# agent_is_managed <agent> [declared] — 0 if warden should supervise this agent.
agent_is_managed() {
  agent_is_pool "$1" && return 1
  agent_is_declared "$1" "${2:-}"
}
