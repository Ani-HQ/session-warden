# Changelog

Notable changes to session-warden. The sections below cover the current PR
stack in merge order: #16 ← #17 ← #18 ← `feat/warden-hardening` ← `feat/scorecard-evals`.

## [Unreleased] — fleet performance + dashboard redesign

### Added — real-work fleet review

- `bin/fleet-review.sh`: weekly quality review of the **production** fleet's
  REAL work (not synthetic tasks). For each agent in `config/fleet-roster.tsv`
  it harvests the past week's session output via `lib/harvest-work.py`, then a
  judge scores role-fit 0-100 with a plain-English insight + one action. Writes
  `state/fleet-review/<date>/review.json` (+ REPORT.md), mirrors to GBrain, and
  sends a Telegram digest. Dormant agents are recorded as idle, not penalised;
  runs of routine no-op turns (e.g. NO_REPLY triage) are collapsed so the judge
  sees substantive work. Closes the gap where the Discord work team
  (ping/bloop/dash/isaac) had no performance signal — only the experimental
  Hermes agents were benchmarked by the model scorecard. Weekly via
  `deploy/fleet-review.{service,timer}` (Sat 06:30 UTC).
- `lib/notify.sh`: `notify_fleet` Telegram digest helper.

### Changed — health dashboard information architecture

- `contrib/health-dashboard/generate.sh` rewritten around a founder-first
  layout: a plain-English verdict (written each run by a cheap model, with a
  deterministic fallback so the page never blanks), a ranked "needs attention"
  list computed from live signals, a unified fleet-performance panel (work /
  personal / experimental, each agent with model + role + score + insight +
  active/idle), a condensed system-health strip in plain terms, and the old
  operator tables demoted to a collapsed "raw signals" drawer. Keeps the CRT
  phosphor styling; adds real per-agent model labels.

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
### Added — model scorecard, weekly Hermes A/B benchmark (`feat/scorecard-evals`)

- `bin/scorecard.sh` + `config/scorecard-tasks.jsonl`: runs a fixed 8-task
  benchmark (factual reasoning, summarization, JSON extraction, style,
  planning, GBrain-grounded tool use, clarify-before-acting judgment, logic)
  through each experimental Hermes agent (carolyn/gemini-3.5-flash,
  midi/zai-glm-4.7, baymax/gemini-3.1-pro-preview) as real non-interactive
  turns, then scores 0-10 with a blind judge — the judge is never told which
  agent/model answered. Report to `state/scorecard/<date>/REPORT.md`, GBrain
  mirror `scorecards/YYYY-MM-DD` (scope: personal, source: scorecard,
  trust: verified), Telegram totals digest.
- `deploy/scorecard.{service,timer}`: Saturdays 06:00 UTC.

### Added — memory evals, monthly memory-quality regression (`feat/scorecard-evals`)

- `bin/eval-memory.sh`: per-agent eval cases
  (`~/.openclaw/evals/<agent>/cases.jsonl`, generated once with
  `--generate <agent>` from MEMORY.md + GBrain lessons; application-style, not
  parroting) replayed monthly against the agent's CURRENT MEMORY.md +
  AGENTS.md via the claude CLI, PASS/FAIL judged by Haiku. Per-agent pass
  rates with deltas vs the previous run (the regression signal) in
  `state/evals/<date>/REPORT.md`, GBrain mirror `evals/YYYY-MM-DD`
  (scope: shared, source: eval-memory, trust: verified), Telegram digest.
- `deploy/eval-memory.{service,timer}`: monthly, 1st 07:00 UTC.

