#!/usr/bin/env bash
# reap-worktrees.sh — session-warden GC for ephemeral agent worktrees.
#
# Agents create per-task worktrees with `wt` (bin/wt) under ~/.openclaw/worktrees.
# Crash-prone agents leave them behind. Native Claude Code cleanup does NOT cover
# our case (headless `claude -p` runs are never swept), so this cron reaps them.
#
# Safety ladder per worktree (conservative — never destroys unsaved work):
#   REMOVE  if the branch is merged into the repo's default remote branch
#           (work landed → the worktree is disposable).
#   REMOVE  if it is clean (no uncommitted/untracked) AND fully pushed AND older
#           than CLEAN_TTL_HOURS (everything is safe on the remote, just idle).
#   ALERT   if it is older than HARD_TTL_DAYS AND still dirty/unpushed
#           (possible data loss — a human decides, we do NOT delete).
#   KEEP    otherwise, and always skip anything touched within ACTIVE_MINUTES
#           (an agent may be mid-task).
#
# Always runs `git worktree prune` on each repo to clear stale admin entries.
# Idempotent, disk+git only, no RPC — safe to run every few minutes from cron.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"

WT_ROOT="${WT_ROOT:-$HOME/.openclaw/worktrees}"
REGISTRY="$WT_ROOT/.registry"
LOG_FILE="${WARDEN_WT_LOG_FILE:-$WARDEN_HOME/state/worktree-gc.log}"
ALERT_FILE="$WARDEN_HOME/state/.worktree-alerts"

CLEAN_TTL_HOURS="${WT_CLEAN_TTL_HOURS:-6}"     # pushed+clean+idle → remove
HARD_TTL_DAYS="${WT_HARD_TTL_DAYS:-7}"         # dirty/unpushed past this → alert
ACTIVE_MINUTES="${WT_ACTIVE_MINUTES:-20}"      # recently touched → never touch
DRY_RUN="${WT_GC_DRY_RUN:-0}"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG_FILE"; }

[[ -d "$WT_ROOT" ]] || exit 0
mkdir -p "$(dirname "$LOG_FILE")"
: > "$ALERT_FILE"

# newest mtime anywhere in the tree, in epoch seconds (activity probe)
newest_mtime() {
  find "$1" -type f -not -path '*/.git/*' -printf '%T@\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d. -f1
}

now="$(date +%s)"
clean_ttl=$(( CLEAN_TTL_HOURS * 3600 ))
hard_ttl=$(( HARD_TTL_DAYS * 86400 ))
active_ttl=$(( ACTIVE_MINUTES * 60 ))

shopt -s nullglob
removed=0 alerted=0 kept=0
declare -A pruned_repos=()

for d in "$WT_ROOT"/*/*/; do
  d="${d%/}"
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue

  # Resolve the primary checkout correctly for normal repos AND submodules.
  # (dirname of --git-common-dir breaks on .git/modules/... paths.)
  main_root="$(git -C "$d" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  [[ -n "$main_root" ]] || continue
  # If porcelain's first entry is a bare git dir (submodule quirk), prefer the
  # registered repo path from the wt registry or the worktree's own toplevel of peers.
  if [[ ! -d "$main_root/.git" && ! -f "$main_root/.git" ]]; then
    # fall back: run remove from inside the linked worktree itself
    main_root="$d"
  fi
  branch="$(git -C "$d" branch --show-current 2>/dev/null)"

  # skip if an agent may be actively working in it
  mt="$(newest_mtime "$d")"; mt="${mt:-0}"
  if (( now - mt < active_ttl )); then kept=$((kept+1)); continue; fi

  # age from registry `created`, fallback to newest mtime
  meta="$REGISTRY/$(basename "$(dirname "$d")")--$(basename "$d").env"
  created="$(sed -n 's/^created=//p' "$meta" 2>/dev/null)"; created="${created:-$mt}"
  age=$(( now - created ))

  dirty=0; [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] && dirty=1
  unpushed=0
  if git -C "$d" rev-parse --verify --quiet "@{upstream}" >/dev/null 2>&1; then
    [[ -n "$(git -C "$d" log --oneline "@{upstream}..HEAD" 2>/dev/null)" ]] && unpushed=1
  else
    unpushed=1   # never pushed
  fi

  # is the branch merged into the repo's default remote branch?
  merged=0
  defref="$(git -C "$main_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -n "$defref" ]] && [[ -n "$branch" ]]; then
    if git -C "$main_root" merge-base --is-ancestor "$branch" "refs/remotes/${defref#refs/remotes/}" 2>/dev/null; then
      merged=1
    fi
  fi

  # A dirty worktree is NEVER auto-removed — uncommitted/untracked work is
  # unsaved, so it can only ever fall through to the alert path below.
  reason=""
  if (( !dirty && merged )); then
    reason="merged into default branch"
  elif (( !dirty && !unpushed && age > clean_ttl )); then
    reason="clean+pushed, idle $((age/3600))h"
  fi

  if [[ -n "$reason" ]]; then
    if (( DRY_RUN )); then
      log "WOULD REMOVE $d ($reason)"
    else
      if git -C "$main_root" worktree remove --force "$d" >>"$LOG_FILE" 2>&1 \
         || git -C "$d" worktree remove --force "$d" >>"$LOG_FILE" 2>&1; then
        rm -f "$meta"
        log "REMOVED $d ($reason)"
        removed=$((removed+1))
        pruned_repos["$main_root"]=1
      else
        # Leftover dir that git no longer considers a worktree — scrub it.
        if [[ ! -e "$d/.git" ]] || ! git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          rm -rf "$d"
          rm -f "$meta"
          log "SCRUBBED orphan dir $d ($reason; not a working tree)"
          removed=$((removed+1))
        else
          log "REMOVE FAILED $d ($reason)"
        fi
      fi
    fi
    continue
  fi

  if (( age > hard_ttl && (dirty || unpushed) )); then
    msg="STALE worktree $d on $branch, ${age}s old, $( ((dirty)) && echo -n 'dirty ' ) $( ((unpushed)) && echo -n 'unpushed' ) — needs a human (data loss risk if removed)"
    log "ALERT $msg"
    printf '%s\n' "$msg" >> "$ALERT_FILE"
    alerted=$((alerted+1))
  else
    kept=$((kept+1))
  fi
done

# prune stale worktree admin entries on every repo we touched, plus known repos
for repo in "${!pruned_repos[@]}"; do
  git -C "$repo" worktree prune 2>>"$LOG_FILE" || true
done

# Drop registry entries whose worktree path no longer exists
for meta in "$REGISTRY"/*.env; do
  [[ -f "$meta" ]] || continue
  p="$(sed -n 's/^path=//p' "$meta")"
  if [[ -n "$p" && ! -e "$p" ]]; then
    rm -f "$meta"
    log "SCRUBBED stale registry $(basename "$meta") (path gone: $p)"
  fi
done

(( removed || alerted )) && log "summary: removed=$removed alerted=$alerted kept=$kept"
exit 0
