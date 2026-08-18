#!/usr/bin/env bash
# dream-cycle.sh — nightly GBrain enrichment ("dream cycle").
#
# GBrain's value compounds only if the brain is maintained while idle. This job
# does the maintenance the warden's per-rotation writes intentionally skip:
#
#   1. transcripts ingest — GBrain 0.46+ pulls dead OpenClaw + Hermes session
#                        logs into conversation pages (secrets redacted,
#                        embed deferred). Incremental via `--since last`.
#                        Never `ingest --all`: that also vacuums every Claude
#                        Code session on the host.
#   2. embed --stale   — `gbrain put` does NOT embed inline, so without this
#                        coverage decays toward zero (it was at 17%). This is
#                        the durable fix that keeps the brain searchable.
#   3. doctor          — health check; Telegram alert on warn/error.
#   4. daily digest     — synthesize the day's session activity into a single
#                        `daily-digest` page that links the day's sessions, so
#                        the graph gains a queryable rollup per day.
#
# Runs nightly at 03:30 local (600s jitter, Persistent=true) via the user
# systemd timer deploy/dream-cycle.timer:
#   systemctl --user status dream-cycle.timer

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/gbrain.sh"
[ -f "${WARDEN_HOME}/lib/notify.sh" ] && source "${WARDEN_HOME}/lib/notify.sh"

LOG_FILE="${WARDEN_LOG_FILE}"
log() { echo "[$(date -Iseconds)] DREAM: $*" >> "$LOG_FILE"; }

LOCKFILE="${WARDEN_HOME}/state/dream-cycle.lock"
exec 196>"$LOCKFILE"
if ! flock -n 196; then
  log "another dream-cycle is running — skipping"
  exit 0
fi

# Probe the brain itself, not just the CLI binary — a dead backend would
# otherwise burn the 30-min embed timeout and error mid-run.
gbrain_healthy || { log "GBRAIN UNAVAILABLE — skipping gbrain work"; exit 0; }

MODEL="${WARDEN_SUMMARY_MODEL:-claude-haiku-4-5-20251001}"
date_str=$(date +%Y-%m-%d)

# Run a long gbrain job. `timeout` is Linux; macOS test hosts may lack it.
# Never use lib/gbrain.sh `_gb` here — its 25s cap is for rotation, not bulk.
_dream_gbrain() {
  local secs="${1:-1800}"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" gbrain "$@"
  else
    gbrain "$@"
  fi
}

# OpenClaw + Hermes only. `gbrain transcripts ingest --all` also discovers
# every Claude Code session on the host (often tens of thousands).
_ingest_transcripts() {
  [ "${WARDEN_GBRAIN_INGEST:-1}" = "1" ] || { log "transcripts ingest disabled"; return 0; }
  local t="${WARDEN_GBRAIN_INGEST_TIMEOUT:-1800}"
  local out oc_root hermes_homes=() d

  if ! gbrain transcripts status >/dev/null 2>&1; then
    log "transcripts ingest unavailable — skipping (need gbrain >= 0.46)"
    return 0
  fi

  oc_root="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}/agents"
  if [ -d "$oc_root" ]; then
    log "ingesting OpenClaw transcripts"
    out=$(_dream_gbrain "$t" transcripts ingest --format openclaw --since last "$oc_root" 2>&1) || true
    log "transcripts openclaw: $(echo "$out" | tail -1)"
  fi

  [ -d "$HOME/.hermes" ] && hermes_homes+=("$HOME/.hermes")
  for d in "$HOME"/.hermes-*; do
    [ -d "$d" ] || continue
    hermes_homes+=("$d")
  done
  if [ "${#hermes_homes[@]}" -gt 0 ]; then
    log "ingesting Hermes transcripts (${#hermes_homes[@]} homes)"
    out=$(_dream_gbrain "$t" transcripts ingest --format hermes --since last "${hermes_homes[@]}" 2>&1) || true
    log "transcripts hermes: $(echo "$out" | tail -1)"
  fi
}

# --- 1. Ingest new harness transcripts ------------------------------------
_ingest_transcripts

# --- 2. Refresh stale embeddings ------------------------------------------
log "refreshing stale embeddings"
embed_out=$(_dream_gbrain 1800 embed --stale 2>&1)
log "embed --stale: $(echo "$embed_out" | tail -1)"

# --- 3. Health check ------------------------------------------------------
health=$(gbrain doctor --json 2>/dev/null)
log "doctor: $health"
if echo "$health" | grep -q '"status":"error"'; then
  type send_telegram &>/dev/null && send_telegram "🧠 GBrain dream-cycle: doctor reports ERRORS — $(echo "$health" | head -c 300)"
fi

# --- 4. Synthesize the daily digest ---------------------------------------
# Collect today's session pages from BOTH producers — rotation/live pages
# (session-warden/<date>/) and snapshot pages (sessions/<date>/) — and roll them
# up into one digest page that links to each session.
today_pages=$( { gbrain list --tag session-warden -n 200 2>/dev/null; gbrain list --tag snapshot -n 200 2>/dev/null; } \
  | awk -v d="$date_str" '($1 ~ "^session-warden/"d"/") || ($1 ~ "^sessions/"d"/") {print $1}' | sort -u)

if [ -n "$today_pages" ]; then
  digest_input=""
  link_targets=""
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    link_targets+="${slug}"$'\n'
    digest_input+=$'\n\n===== '"${slug}"$' =====\n'
    digest_input+=$(gbrain get "$slug" 2>/dev/null | head -60)
  done < <(echo "$today_pages")

  digest=$(echo "$digest_input" | timeout 90 claude -p --model "$MODEL" "You are a memory system writing a daily rollup across an AI agent fleet. From the per-session notes below, write a concise digest under 250 words. Output exactly:

## Highlights
(3-6 bullets: what actually happened across the fleet today — concrete, with agent names)

## Decisions
(bullets: notable decisions or rules established)

## Open threads
(bullets: unfinished work to pick up)

No preamble, no code fences." 2>/dev/null)

  if [ -n "$digest" ]; then
    digest_slug="daily-digest/${date_str}"
    printf -- '---\ntype: daily-digest\ntitle: Fleet daily digest — %s\ntags:\n  - session-warden\n  - daily-digest\n---\n\n_Synthesized by dream-cycle at %s_\n\n%s\n' \
      "$date_str" "$(date -Iseconds)" "$digest" | _gb_put "$digest_slug"
    # Link the digest to each session it summarizes.
    while IFS= read -r slug; do
      [ -z "$slug" ] && continue
      _gb link "$digest_slug" "$slug" --type summarizes >/dev/null 2>&1
    done < <(echo "$link_targets")
    log "wrote $digest_slug linking $(echo "$link_targets" | grep -c .) sessions"
  else
    log "digest synthesis empty — skipped"
  fi
else
  log "no session-warden pages for $date_str — no digest"
fi

log "dream-cycle complete"
flock -u 196
