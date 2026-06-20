# Merged Architecture: session-warden + gbrain-snapshotter

## Current State (two repos)

**session-warden** manages OpenClaw agent sessions:
- detect bloated/failed/zombie sessions (scan every 30s)
- rotate: archive JSONL, clean session refs, capture crash buffer
- summarize: extract transcript, Haiku summary, write to Claude Code memory
- recover: restart gateway, send recovery messages with GBrain-synthesized context
- context-sync: live capture of healthy sessions to memory + GBrain (every 5 min)
- dream-cycle: nightly embed refresh, health check, daily digest synthesis
- GBrain integration: typed pages, performed_by + mentions edges, wikilinks

**gbrain-snapshotter** captures ALL Claude Code sessions (including non-OpenClaw):
- scan `~/.claude/projects/**/*.jsonl` for recently-modified sessions
- summarize last 40 turns via `claude -p`
- write typed pages to GBrain with graph wiring
- runs every 30 min via systemd timer

**Problems with two repos:**
- OpenClaw sessions are double-ingested (warden writes `session-warden/*`, snapshotter writes `sessions/*`)
- Duplicated logic: JSONL extraction, agent attribution, GBrain page writing, slug generation
- Two systemd services/cron jobs to maintain
- Snapshotter can't access warden's richer memory (carry-forward, crash buffers, channel history)

## Merged Architecture

One repo. The warden gains a new `bin/snapshot.sh` module that absorbs the snapshotter's job: scanning non-OpenClaw Claude Code sessions and ingesting them into GBrain.

### Directory Structure (changes marked with *)

```
session-warden/
  bin/
    scan.sh                 # existing (unchanged)
    rotate.sh               # existing (unchanged)
    summarize.sh            # existing (unchanged)
    context-sync.sh         # existing (minor: skip openclaw sessions if snapshot handles them)
    snapshot.sh             # * NEW: replaces gbrain-snapshotter/snapshotter.sh
    dream-cycle.sh          # existing (updated: also processes snapshot pages in digest)
    status.sh               # existing (updated: show snapshot stats)
    backfill-gbrain-links.sh  # existing (unchanged, works for both prefixes)
    cleanup-archives.sh     # existing (unchanged)
    mcp-supervisor.sh       # existing (unchanged)
  lib/
    detect.sh               # existing (unchanged)
    extract.sh              # existing (unchanged)
    memory.sh               # existing (unchanged)
    gbrain.sh               # existing (minor: add snapshot-specific helpers)
    notify.sh               # existing (unchanged)
    channel-history.sh      # existing (unchanged)
    agent-attribution.sh    # * NEW: unified agent_from_cwd() + agent_from_sessions_path()
  hooks/
    post-summary/
      01-gbrain.sh          # existing (unchanged)
  config/
    thresholds.env          # existing (extended with snapshot settings)
  deploy/
    dream-cycle.service     # existing (unchanged)
    dream-cycle.timer       # existing (unchanged)
    snapshot.service         # * NEW (or reuse via cron)
    snapshot.timer           # * NEW
  tests/
    test-snapshot.sh         # * NEW
    test-agent-attribution.sh  # * NEW
    ...existing tests...
  state/
    snapshot/               # * NEW: mtime tracking for snapshot module
      state.json
    ...existing state dirs...
  install.sh                # existing (extended: install snapshot cron/timer)
```

### New Module: bin/snapshot.sh

This is the snapshotter, rewritten to live inside the warden and reuse its libraries.

**What it does:**
1. Scan `~/.claude/projects/**/*.jsonl` modified in the last N minutes
2. Skip sessions that belong to OpenClaw agents (these are handled by context-sync + rotation)
3. For each qualifying session: extract transcript, summarize via Haiku, write typed GBrain page
4. Reuse `lib/gbrain.sh` for page writing (gbrain_ingest_session or a new variant)
5. Reuse `lib/extract.sh` for JSONL parsing

**Key design decisions:**

1. **OpenClaw exclusion.** The snapshot module skips any JSONL whose path matches `*-openclaw-agents-*` (the sanitized path pattern Claude uses for OpenClaw project dirs). This eliminates double-ingestion. OpenClaw sessions are exclusively handled by context-sync (live) and summarize (rotation).

2. **Unified agent attribution.** A new `lib/agent-attribution.sh` consolidates both repos' agent detection:
   ```
   agent_from_cwd():
     *.openclaw/agents/<name>*  -> <name>     (OpenClaw agents)
     <user glob rules>          -> <name>     (optional config/agent-paths.env)
     $HOME or $HOME/            -> home
     *                          -> unknown

   agent_from_sessions_path():
     (existing, for OpenClaw sessions.json paths)
   ```

3. **GBrain page schema.** Snapshot pages use slug `sessions/<date>/<agent>-<shortid>` (same as before) with:
   - type: note
   - tags: [session, snapshot, <agent>]
   - performed_by edge to agent/<agent>
   - mentions edges from wikilinks in summary
   - This is consistent with warden pages, just different slug prefix

4. **Summarization reuse.** Snapshot uses the same Haiku model (`WARDEN_SUMMARY_MODEL`) and a prompt similar to `lib/memory.sh` but shorter (snapshot doesn't need carry-forward or crash buffer logic since these are standalone CLI sessions, not persistent agents).

5. **State tracking.** Snapshot keeps `state/snapshot/state.json` mapping session_id -> `{last_mtime, last_turn_count}`. Re-summarization triggers only when mtime has changed AND at least `WARDEN_SNAPSHOT_MIN_TURNS` new turns since last snapshot. Prevents wasted Haiku calls on trivially-changed sessions.

6. **Schedule.** Runs every 30 min via cron or systemd timer. Independent of the 30s scan cycle (snapshot is expensive due to Haiku calls; scan is cheap).

### Changes to Existing Modules

**config/thresholds.env** -- new settings:
```bash
# Snapshot: capture non-OpenClaw Claude Code sessions into GBrain
WARDEN_SNAPSHOT_WINDOW_MINUTES=${WARDEN_SNAPSHOT_WINDOW_MINUTES:-120}   # lookback window for active sessions
WARDEN_SNAPSHOT_MIN_TURNS=${WARDEN_SNAPSHOT_MIN_TURNS:-4}               # minimum turns to trigger first snapshot
WARDEN_SNAPSHOT_MAX_TURNS=${WARDEN_SNAPSHOT_MAX_TURNS:-40}              # max turns fed to summarizer
WARDEN_SNAPSHOT_INTERVAL_MINUTES=${WARDEN_SNAPSHOT_INTERVAL_MINUTES:-30} # cron/timer frequency
```

**bin/dream-cycle.sh** -- update digest synthesis:
- Currently only collects pages tagged `session-warden`. Update to also include `snapshot` tag
- Or simplify: collect all pages under `session-warden/` and `sessions/` prefixes

**bin/status.sh** -- add snapshot stats:
- Show last snapshot run time, sessions processed, any failures

**install.sh** -- add snapshot cron/timer:
```bash
# existing scan cron (30s)
# new snapshot cron (30 min)
*/30 * * * * /bin/bash ${WARDEN_HOME}/bin/snapshot.sh  # session-warden-snapshot
```

### Data Flow (merged)

```
                    session-warden (unified)
                    =======================

OpenClaw Sessions                    Standalone Claude Code Sessions
(~/.openclaw/agents/*)               (~/.claude/projects/**)
        |                                       |
        v                                       v
  scan.sh (30s cron)                   snapshot.sh (30m cron)
  detect bloat/failure/zombie          scan JSONL, skip openclaw paths
        |                                       |
        v                                       v
  rotate.sh                            extract transcript (lib/extract.sh)
  archive, cleanup, crash buffer       summarize via Haiku
        |                                       |
        v                                       v
  summarize.sh                         gbrain_ingest_session (lib/gbrain.sh)
  extract, Haiku, write memory         typed page, performed_by, mentions
  hooks/01-gbrain.sh                            |
        |                                       |
        v                                       v
  context-sync.sh (5m cron)            state/snapshot/state.json
  live capture -> memory + gbrain      (mtime tracking)
        |                                       |
        +-------------------+-------------------+
                            |
                            v
                   dream-cycle.sh (nightly)
                   embed --stale
                   doctor health check
                   daily digest (both prefixes)
```

### Migration Plan

1. Create `lib/agent-attribution.sh` with unified `agent_from_cwd()`. Update `detect.sh` and snapshotter to source it.
2. Create `bin/snapshot.sh` by refactoring `gbrain-snapshotter/snapshotter.sh` to:
   - Source warden config and libs instead of standalone logic
   - Use `lib/extract.sh` instead of its own `extract_conversation()`
   - Use `lib/gbrain.sh` (`gbrain_ingest_session`) instead of inline gbrain writes
   - Add OpenClaw path exclusion
   - Read state from `state/snapshot/state.json`
3. Update `config/thresholds.env` with snapshot settings
4. Update `install.sh` to add snapshot cron entry
5. Update `bin/dream-cycle.sh` to include snapshot pages in digest
6. Update `bin/status.sh` to report snapshot health
7. Add `tests/test-snapshot.sh` and `tests/test-agent-attribution.sh`
8. Remove `WARDEN_SNAPSHOTTER` config var (no longer external)
9. Remove external snapshotter call from `bin/summarize.sh` (line 73-75)
10. Update README.md with snapshot module docs
11. Retire `~/gbrain-snapshotter/` repo (disable systemd timer, archive or delete)

### What This Does NOT Change

- Rotation logic (scan, detect, rotate, recovery) is untouched
- Context-sync for live OpenClaw sessions is untouched
- GBrain page schema/types/linking is unchanged
- Hook system is unchanged
- MCP supervisor is unchanged
- Test infrastructure is unchanged

### Resolved Design Decisions

1. **GBrain is a hard dependency.** No graceful degradation, no `gbrain_available` guards in snapshot. If `gbrain` CLI isn't installed, snapshot exits with an error. The entire warden treats GBrain as the canonical persistence layer. The existing `gbrain_available` soft guards in other modules (context-sync, scan recovery) should also be tightened: GBrain is required, not optional.

2. **Snapshot writes to GBrain only, not Claude Code memory.** Standalone CLI sessions don't have agent workspaces or persistent channels. Claude Code's native auto-memory + auto-dream already handles local session persistence for the same project directory. Writing a second memory layer would conflict. GBrain is the cross-session knowledge graph; local memory is Claude's own job.

3. **30 min check frequency, configurable via `WARDEN_SNAPSHOT_INTERVAL_MINUTES`.** Most checks are no-ops (mtime hasn't changed). Haiku only fires when content actually changed. 30 min balances freshness and spend.

4. **Re-summarize only if mtime changed AND at least `WARDEN_SNAPSHOT_MIN_TURNS` new turns since last snapshot.** `state/snapshot/state.json` tracks both `last_mtime` and `last_turn_count` per session. Prevents re-summarizing sessions where someone just ran one command, but catches meaningful context shifts. Default threshold: 4 turns (same as current `MIN_TURNS`).
