#!/usr/bin/env bash
# gbrain.sh — GBrain knowledge-graph integration for session-warden
#
# GBrain (https://github.com/garrytan/gbrain) is a self-wiring markdown
# knowledge graph: typed pages + typed edges + hybrid retrieval. Earlier the
# warden treated it as a flat sink (untyped pages, zero links). This library
# makes the warden write TYPED, LINKED pages and read back via synthesis.
#
# Design notes:
#   - `gbrain put` does NOT embed inline. Embedding is a separate `gbrain embed`
#     step run by the nightly dream-cycle (bin/dream-cycle.sh). So frequent
#     re-puts here are cheap (no per-write embedding cost).
#   - Every session page links to its agent page (performed_by) so the graph is
#     queryable by agent. Entity wikilinks in the summary body become `mentions`
#     edges. Auto-linking is done explicitly via `gbrain link` (robust across
#     CLI versions) rather than relying on implicit wikilink resolution.
#
# Used by: hooks/post-summary/01-gbrain.sh, bin/context-sync.sh,
#          bin/scan.sh (recovery), bin/dream-cycle.sh, bin/snapshot.sh

# APPEND, never prepend: the goal is "these dirs are reachable under cron",
# not "override the caller's resolution order". Prepending silently shadowed
# test-sandbox mock binaries with the real openclaw/claude — tests were
# delivering real messages while believing they were sandboxed.
export PATH="$PATH:$HOME/.bun/bin:$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin"

# GBrain's embed client (src/core/embedding.ts) reads process.env.OPENAI_API_KEY
# directly — it does NOT use the stored gbrain config key. Cron does not source
# ~/.bashrc, so without this the dream-cycle's `gbrain embed` fails auth and
# burns ~60s of retry-backoff per chunk. Pull the key from ~/.bashrc if the
# environment doesn't already carry one. (Set it in thresholds.env to override.)
if [ -z "${OPENAI_API_KEY:-}" ] && [ -f "$HOME/.bashrc" ]; then
  OPENAI_API_KEY="$(grep -hE '^[[:space:]]*export[[:space:]]+OPENAI_API_KEY=' "$HOME/.bashrc" 2>/dev/null \
    | tail -1 | sed -E "s/^[[:space:]]*export[[:space:]]+OPENAI_API_KEY=//; s/^[\"']//; s/[\"']$//")"
  export OPENAI_API_KEY
fi

# Bound every gbrain CLI call so a slow/hung remote brain never blocks rotation.
GBRAIN_TIMEOUT="${WARDEN_GBRAIN_TIMEOUT:-25}"

gbrain_available() {
  command -v gbrain >/dev/null 2>&1
}

# Cheap liveness probe: CLI present AND the brain answering (one-row list is
# the cheapest real round-trip; ~11s wall on this host, dominated by bun
# startup + remote DB). Bulk gbrain jobs (snapshot, dream-cycle) call this at
# start and skip cleanly on failure instead of erroring mid-run —
# rotation/scan must never block on gbrain. Goes through _gb so the bound
# (GBRAIN_TIMEOUT, default 25s) and the no-`timeout` bun quirk stay in one place.
gbrain_healthy() {
  gbrain_available || return 1
  _gb list -n 1 >/dev/null 2>&1
}

_gb() {
  # Bounded gbrain runner. We do NOT use `timeout` here: the bun-based gbrain
  # CLI hangs under `timeout` when `put` reads stdin (its event loop stays
  # alive), whereas a plain backgrounded child exits cleanly on stdin EOF.
  # So we background gbrain (inheriting the caller's stdin, incl. a `put` pipe)
  # and hard-kill only if it overruns GBRAIN_TIMEOUT. Returns 124 on overrun.
  gbrain "$@" 2>/dev/null &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$GBRAIN_TIMEOUT" ]; then
      kill -TERM "$pid" 2>/dev/null
      sleep 1; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1; i=$((i + 1))
  done
  wait "$pid"
}

# Write a page, reading markdown content from stdin. Must run in the FOREGROUND
# with no `timeout`/background wrapper: gbrain reads piped stdin and exits on
# EOF, but backgrounding it (POSIX redirects async stdin to /dev/null) or
# wrapping in `timeout` (bun event loop hangs) both break the stdin read.
# Args: $1=slug. Content on stdin.
_gb_put() {
  gbrain put "$1" >/dev/null 2>&1
}

# Slugify arbitrary text into a gbrain-safe slug segment.
gbrain_slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-64
}

# Ensure an entity page exists; create a minimal typed stub if missing.
# Args: $1=slug  $2=type  $3=title
gbrain_ensure_page() {
  local slug="$1" type="$2" title="$3"
  [ -z "$slug" ] && return 1
  if _gb get "$slug" >/dev/null 2>&1; then
    return 0
  fi
  printf -- '---\ntype: %s\ntitle: %s\ntags:\n  - session-warden\n---\n\n_Auto-created by session-warden as a graph anchor._\n' \
    "$type" "$title" | _gb_put "$slug"
}

# Derive a gbrain page type from a wikilink slug prefix.
# e.g. project/foo -> project, company/bar -> company, person/baz -> person
_gbrain_type_for() {
  case "$1" in
    project/*) echo "project" ;;
    company/*) echo "company" ;;
    person/*|people/*|wiki/people/*) echo "person" ;;
    deal/*) echo "deal" ;;
    agent/*) echo "agent" ;;
    repo/*) echo "source" ;;
    *) echo "concept" ;;
  esac
}

# Ingest one session into GBrain as a typed, linked page.
# Args: $1=agent  $2=channel_key  $3=cli_session_id  $4=memory_file  [$5=slug_prefix]
# slug_prefix defaults to a dated rotation slug; context-sync passes "live";
# model-switch / rate-guard pass "handoff".
gbrain_ingest_session() {
  local agent="$1" channel_key="$2" cli_session_id="$3" memory_file="$4" mode="${5:-rotation}"
  gbrain_available || { echo "GBRAIN: cli not found — skipping"; return 0; }
  [ -f "$memory_file" ] || { echo "GBRAIN: memory file missing ($memory_file)"; return 0; }

  local short_id="${cli_session_id:0:8}"
  local date_str safe_channel slug agent_slug title live_slug
  date_str=$(date +%Y-%m-%d)
  safe_channel=$(gbrain_slugify "$channel_key")
  agent_slug="agent/$(gbrain_slugify "$agent")"
  live_slug="session-warden/live/${agent}-${safe_channel}"

  if [ "$mode" = "live" ]; then
    # One living page per session, upserted in place — current state, no history churn.
    slug="$live_slug"
    title="${agent} — live session (${channel_key})"
  elif [ "$mode" = "handoff" ]; then
    # Durable mid-work checkpoint before model switch / rate-guard rewrite.
    slug="session-warden/handoff/${agent}-${safe_channel}"
    title="${agent} — handoff (${channel_key})"
  else
    slug="session-warden/${date_str}/${agent}-${short_id}"
    title="${agent} session ${short_id} — ${date_str}"
  fi

  # Strip the warden's Claude-memory frontmatter; rebuild purpose-built frontmatter
  # for GBrain (correct type, clean title, agent/platform tags).
  local body platform
  # Strip a leading YAML frontmatter block (--- ... ---) if present; keep the rest.
  body=$(awk '
    NR==1 && /^---[[:space:]]*$/ {infm=1; next}
    infm && /^---[[:space:]]*$/   {infm=0; next}
    !infm                         {print}
  ' "$memory_file" 2>/dev/null)
  [ -z "$body" ] && body=$(cat "$memory_file")
  platform=$(echo "$channel_key" | cut -d: -f2)

  # Write the typed page.
  printf -- '---\ntype: note\ntitle: %s\nagent: %s\nchannel: %s\ntags:\n  - session-warden\n  - %s\n  - %s\n  - %s\n---\n\n_Captured by session-warden (%s) at %s · session %s_\n\n%s\n' \
    "$title" "$agent" "$channel_key" "$agent" "${platform:-unknown}" "$mode" "$mode" "$(date -Iseconds)" "$cli_session_id" "$body" \
    | _gb_put "$slug" || { echo "GBRAIN: put failed for $slug"; return 1; }

  _gb tag "$slug" "session-warden" >/dev/null 2>&1
  _gb tag "$slug" "$agent" >/dev/null 2>&1
  [ "$mode" = "handoff" ] && _gb tag "$slug" "handoff" >/dev/null 2>&1
  [ "$mode" = "rotation" ] && _gb timeline-add "$slug" "$date_str" "Session rotated: ${agent} (${channel_key})" >/dev/null 2>&1
  [ "$mode" = "handoff" ] && _gb timeline-add "$slug" "$date_str" "Handoff checkpoint: ${agent} (${channel_key})" >/dev/null 2>&1

  # --- Build the graph ---------------------------------------------------
  # 1. Every session is performed_by its agent. Anchor + link.
  gbrain_ensure_page "$agent_slug" "agent" "$agent"
  _gb link "$slug" "$agent_slug" --type performed_by >/dev/null 2>&1

  # 2. Entity wikilinks in the body ([[type/slug]]) become `mentions` edges.
  local target tgt_type tgt_title
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    tgt_type=$(_gbrain_type_for "$target")
    tgt_title=$(basename "$target" | tr '-' ' ')
    gbrain_ensure_page "$target" "$tgt_type" "$tgt_title"
    _gb link "$slug" "$target" --type mentions >/dev/null 2>&1
  done < <(grep -oE '\[\[[a-zA-Z0-9/_-]+\]\]' "$memory_file" 2>/dev/null \
            | sed -E 's/^\[\[//; s/\]\]$//' | sort -u | head -12)

  # 3. Handoff pages point the live page at the durable checkpoint.
  if [ "$mode" = "handoff" ]; then
    printf -- '---\ntype: note\ntitle: %s — live session (%s)\nagent: %s\nchannel: %s\ntags:\n  - session-warden\n  - %s\n  - live\n---\n\n_Latest handoff: [[%s]] at %s_\n\nRead the handoff page before resuming mid-work after a model switch or rate-guard rewrite.\n' \
      "$agent" "$channel_key" "$agent" "$channel_key" "$agent" "$slug" "$(date -Iseconds)" \
      | _gb_put "$live_slug" >/dev/null 2>&1 || true
    _gb link "$live_slug" "$slug" --type related_to >/dev/null 2>&1 || true
  fi

  echo "GBRAIN: ingested $slug (typed=note, linked to ${agent_slug})"
  # Echo slug on a machine-readable line for callers (handoff CLI / recovery).
  echo "GBRAIN_SLUG=$slug"
  return 0
}

# Ingest a standalone (non-OpenClaw) Claude Code session into GBrain as a typed,
# linked page. Used by bin/snapshot.sh. Unlike gbrain_ingest_session there is no
# per-call gbrain_available guard — bin/snapshot.sh probes gbrain_healthy up
# front and skips the whole run when the brain is down.
#
# Slug: sessions/<date>/<agent>-<shortid>   tags: [session, snapshot, <agent>]
# Args: $1=agent  $2=session_id  $3=summary_file  $4=cwd  $5=turns
gbrain_ingest_snapshot() {
  local agent="$1" session_id="$2" summary_file="$3" cwd="$4" turns="$5"
  [ -f "$summary_file" ] || { echo "GBRAIN: summary file missing ($summary_file)"; return 1; }

  local short_id="${session_id:0:8}"
  local date_str slug agent_slug
  date_str=$(date +%Y-%m-%d)
  slug="sessions/${date_str}/$(gbrain_slugify "$agent")-${short_id}"
  agent_slug="agent/$(gbrain_slugify "$agent")"

  local summary
  summary=$(cat "$summary_file")

  # Write the typed page (header block + the Haiku summary body).
  printf -- '---\ntype: note\ntitle: %s session %s (%s)\nagent: %s\ntags:\n  - session\n  - snapshot\n  - %s\n---\n\n# Session %s (%s)\n\n- **Session ID:** `%s`\n- **CWD:** `%s`\n- **Turns:** %s\n- **Snapshotted at:** %s\n\n---\n\n%s\n' \
    "$agent" "$short_id" "$date_str" "$agent" "$agent" \
    "$short_id" "$agent" "$session_id" "$cwd" "$turns" "$(date -Iseconds)" "$summary" \
    | _gb_put "$slug" || { echo "GBRAIN: put failed for $slug"; return 1; }

  _gb tag "$slug" "session" >/dev/null 2>&1
  _gb tag "$slug" "snapshot" >/dev/null 2>&1
  _gb tag "$slug" "$agent" >/dev/null 2>&1

  local first_line
  first_line=$(grep -v '^[[:space:]]*$' "$summary_file" | head -1 | sed 's/^#*[[:space:]]*//' | head -c 100)
  [ -n "$first_line" ] && _gb timeline-add "$slug" "$date_str" "Session ${short_id} (${agent}): ${first_line}" >/dev/null 2>&1

  # --- Build the graph ---------------------------------------------------
  # 1. performed_by edge to the agent (anchor the agent page if missing).
  gbrain_ensure_page "$agent_slug" "agent" "$agent"
  _gb link "$slug" "$agent_slug" --type performed_by >/dev/null 2>&1

  # 2. mentions edges from [[wikilinks]] in the summary's Entities section.
  local target tgt_type tgt_title
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    tgt_type=$(_gbrain_type_for "$target")
    tgt_title=$(basename "$target" | tr '-' ' ')
    gbrain_ensure_page "$target" "$tgt_type" "$tgt_title"
    _gb link "$slug" "$target" --type mentions >/dev/null 2>&1
  done < <(grep -oE '\[\[[a-zA-Z0-9/_-]+\]\]' "$summary_file" 2>/dev/null \
            | sed -E 's/^\[\[//; s/\]\]$//' | sort -u | head -8)

  echo "GBRAIN: ingested $slug (snapshot, linked to ${agent_slug})"
  return 0
}

# Synthesize a cross-session briefing for recovery. Echoes synthesized text
# (empty on failure). Args: $1=agent  $2=channel_key
gbrain_query_context() {
  local agent="$1" channel_key="${2:-}"
  gbrain_available || return 0
  local q out
  q="What was the agent '${agent}' working on most recently? Summarize current task, pending/unfinished items, and any related context or blockers across recent sessions."
  out=$(_gb query "$q" 2>/dev/null)
  [ -n "$out" ] && printf '%s\n' "$out"
}
