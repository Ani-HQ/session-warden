#!/usr/bin/env bash
# agent-attribution.sh — unified agent identity resolution.
#
# Two ways the warden figures out which agent a session belongs to:
#
#   agent_from_cwd()            — from a session's working directory. Used by
#                                 bin/snapshot.sh to attribute standalone Claude
#                                 Code sessions.
#   agent_from_sessions_path()  — from an OpenClaw sessions.json path. Used by
#                                 lib/detect.sh for rotation scanning.
#
# Both are consolidated here so the two ingestion paths share one source of
# truth for agent names.

# Resolve WARDEN_HOME even when the caller didn't export it.
_warden_attr_home() {
  if [ -n "${WARDEN_HOME:-}" ]; then
    printf '%s' "$WARDEN_HOME"
  else
    ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )
  fi
}

# Optional, user-defined path -> agent mappings for standalone (non-OpenClaw)
# sessions. A file of "<glob> = <agent name>" lines; first match wins. Lets you
# attribute your own repos/projects without hardcoding anything in this repo.
# See config/agent-paths.env.example. Override the path with WARDEN_AGENT_PATH_MAP.
_agent_from_path_map() {
  local cwd="$1" mapfile line pat name
  mapfile="${WARDEN_AGENT_PATH_MAP:-$(_warden_attr_home)/config/agent-paths.env}"
  [ -f "$mapfile" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                                       # strip comments
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac   # skip blank lines
    pat="${line%%=*}"; name="${line#*=}"
    pat="${pat#"${pat%%[![:space:]]*}"}";   pat="${pat%"${pat##*[![:space:]]}"}"     # trim
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    [ -n "$pat" ] && [ -n "$name" ] || continue
    # shellcheck disable=SC2254  -- $pat is an intentional glob
    case "$cwd" in
      $pat) printf '%s' "$name"; return 0 ;;
    esac
  done < "$mapfile"
  return 1
}

# Resolve an agent name from a session's working directory.
#   ~/.openclaw/agents/<name>/...        -> <name>     (OpenClaw agents)
#   <matches a rule in agent-paths.env>  -> that rule's agent name
#   $HOME (bare)                         -> home
#   anything else                        -> unknown
agent_from_cwd() {
  local cwd="$1" mapped
  case "$cwd" in
    *.openclaw/agents/*)
      echo "$cwd" | sed -E 's#.*/\.openclaw/agents/([^/]+).*#\1#'
      return ;;
  esac
  if mapped="$(_agent_from_path_map "$cwd")"; then
    printf '%s\n' "$mapped"
    return
  fi
  case "$cwd" in
    "$HOME"|"$HOME/") echo "home" ;;
    *)                echo "unknown" ;;
  esac
}

# Resolve an agent name from an OpenClaw sessions.json path.
#   .../agents/<name>/sessions/sessions.json -> <name>
agent_from_sessions_path() {
  echo "$1" | sed -E 's|.*/agents/([^/]+)/sessions/.*|\1|'
}

# Export so subshells (and `bash -c` invocations) inherit them.
export -f agent_from_cwd agent_from_sessions_path _agent_from_path_map _warden_attr_home 2>/dev/null || true
