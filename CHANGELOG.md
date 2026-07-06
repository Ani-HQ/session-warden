# Changelog

Notable changes to session-warden. The sections below cover the current PR
stack in merge order: #16 ← #17 ← #18 ← `feat/warden-hardening`.

## [Unreleased] — 1.0.0

### Fixed — recovery delivery (#16)

- Pass `--channel last` to every `openclaw agent` call site (scan.sh recovery,
  rotate.sh graceful save-state, reap-stalls.sh recovery). OpenClaw 2026.6.x
  requires an explicit `--channel` when multiple channel plugins are
  configured; every delivery had failed silently since ~Jun 11, and the
  failure-counter coupling wedged otherwise-healthy agents in permanent
  BACKOFF.

### Added — Reflector, nightly lesson distillation (#17)

- `bin/reflect.sh`: gathers each agent's last-24h material (transcripts,
  rotation summaries, daily notes), distills 0-5 ACE-style append-only lesson
  bullets with a strong model, adversarially verifies each with an independent
  cheaper skeptic, and stages survivors in `memory/pending-lessons-YYYY-MM-DD.md`.
- `bin/apply-lessons.sh`: promotes approved bullets into `## Lessons learned`
  and mirrors them to GBrain with provenance.
- `deploy/reflect.{service,timer}`: daily 04:10 UTC, after the dream-cycle.
  Telegram digest per run; `WARDEN_REFLECT_AUTO_APPLY` opt-in for unattended
  appends (default: staged for human review).

### Added — weekly skill harvester (#18)

- `bin/harvest-skills.sh`: mines each agent's week (rotation summaries, daily
  notes, applied lessons) for workflows performed 2+ times that no existing
  skill covers, and stages complete SKILL.md drafts under
  `~/.openclaw/skills-pending/<agent>/` (max 2/agent, never live dirs).
- `bin/promote-skill.sh <agent> <skill> [--shared]`: promotes a reviewed draft
  to live skills plus a GBrain provenance page.
- `deploy/harvest.{service,timer}`: Sundays 05:00 UTC, after the reflector.

### Changed — hardening pass (`feat/warden-hardening`)

- **BACKOFF escalation**: first hit of `WARDEN_MAX_CONSECUTIVE_FAILURES` sends
  one Telegram alert (`notify_backoff`) and writes a
  `state/cooldowns/<key>.backoff-alerted` marker; while it exists the BACKOFF
  log line is throttled to hourly instead of every 30s scan. Marker clears
  wherever the counter resets.
- **Failure-counter lifecycle**: the counter now resets when the rotation
  itself completes and increments only when rotation fails before completing.
  Recovery delivery failures log but no longer poison the counter.
- **Recovery delivery visibility**: delivery failures log the openclaw CLI
  exit code and the first ~200 chars of stderr (scan.sh and reap-stalls.sh).
  Channel-less sessions (`agent:*:explicit:*` or no channel binding in
  sessions.json) are sent without `--deliver` instead of failing.
- **Summaries feed the loop**: rotation summaries end with a `## GBrain refs`
  section linking the session's rotation and live graph pages, and the
  summary prompt stages a `## Lessons candidates` section (picked up by the
  nightly reflector) when a session contains a lesson-worthy event.
- **logrotate**: `deploy/session-warden.logrotate` (weekly, rotate 4,
  compress, copytruncate) covers `state/*.log`; installed to
  `/etc/logrotate.d/session-warden`. cleanup-archives' size-based rotation
  stays as a flood backstop.
- **update-openclaw.sh**: the verify step recognizes the patch-retirement
  condition (native reliability config in openclaw >= 2026.6.5) and reports
  "patches retired (native support) — nothing to verify" instead of a false
  `[MISSING]` alarm.
- **GBrain graceful degradation**: `gbrain_healthy()` probes the brain at the
  start of snapshot.sh and dream-cycle.sh; when it fails they log
  `GBRAIN UNAVAILABLE — skipping gbrain work` and exit 0. Rotation/scan never
  block on gbrain.
- **Portable stat (GitHub #2)**: `lib/portable.sh` `stat_mtime`/`stat_size`
  helpers (GNU `-c` first, BSD `-f` fallback) replace every GNU-specific
  `stat -c` call, fixing zombie detection and mid-turn protection on macOS.
- **dream-cycle.sh doc drift**: header now describes the actual deployment
  (user timer installed and enabled) instead of "NOT enabled automatically".

Release note: 1.0.0 is cut by the repo owner after the PR stack
(#16 → #17 → #18 → hardening) merges; nothing is tagged from the branches.
