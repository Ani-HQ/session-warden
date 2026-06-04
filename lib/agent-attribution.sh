#!/usr/bin/env bash
# agent-attribution.sh — unified agent identity resolution.
#
# Two ways the warden figures out which agent a session belongs to:
#
#   agent_from_cwd()            — from a session's working directory. Used by
#                                 bin/snapshot.sh to attribute standalone Claude
#                                 Code sessions (absorbed from gbrain-snapshotter).
#   agent_from_sessions_path()  — from an OpenClaw sessions.json path. Used by
#                                 lib/detect.sh for rotation scanning.
#
# Both are consolidated here so the two ingestion paths share one source of
# truth for agent names.

# Resolve an agent name from a session's working directory.
#   ~/.openclaw/agents/<name>/...  -> <name>   (OpenClaw agents)
#   …/ai-holdingco/…/storybook     -> kai-adventuresof
#   …/ai-holdingco/…/yeet          -> kai-yeet
#   …/ai-holdingco/…               -> kai
#   …/crossval, cv-new/backend/website -> cv-special-ops
#   $HOME (bare)                   -> home
#   anything else                  -> unknown
agent_from_cwd() {
  local cwd="$1"
  case "$cwd" in
    *.openclaw/agents/*)        echo "$cwd" | sed -E 's#.*/\.openclaw/agents/([^/]+).*#\1#' ;;
    *ai-holdingco*storybook*)   echo "kai-adventuresof" ;;
    *ai-holdingco*yeet*)        echo "kai-yeet" ;;
    *ai-holdingco*)             echo "kai" ;;
    *cv-new*|*cv-backend*|*cv-website*|*crossval*) echo "cv-special-ops" ;;
    "$HOME"|"$HOME/")           echo "home" ;;
    *)                          echo "unknown" ;;
  esac
}

# Resolve an agent name from an OpenClaw sessions.json path.
#   .../agents/<name>/sessions/sessions.json -> <name>
agent_from_sessions_path() {
  echo "$1" | sed -E 's|.*/agents/([^/]+)/sessions/.*|\1|'
}

# Export so subshells (and `bash -c` invocations) inherit them.
export -f agent_from_cwd agent_from_sessions_path 2>/dev/null || true
