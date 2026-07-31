# Changelog

Notable changes to session-warden. The sections below cover the current PR
stack in merge order: #16 ← #17 ← #18 ← `feat/warden-hardening` ← `feat/scorecard-evals` ← `feat/burn-solo`.

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
  (the work-team agents) had no performance signal — only the experimental
  Hermes agents were benchmarked by the model scorecard. Weekly via
  `deploy/fleet-review.{service,timer}` (Sat 06:30 UTC).
- `lib/notify.sh`: `notify_fleet` Telegram digest helper.

### Fixed — retired agents kept themselves alive

- `lib/registry.sh` (new), `bin/scan.sh`: warden now supervises only the agents
  openclaw declares in `agents.list`, instead of every directory matching
  `agents/*/sessions/sessions.json`. Discovery by glob made retirement
  something warden could not observe — a retired agent keeps its session files,
  so warden kept rotating it, and every rotation ends in a recovery message
  that wakes the agent again. Four agents retired on 2026-07-29 stayed in that
  loop for two days and were nearly as busy as the fleet's most active agent
  (89, 86, 62 and 52 rotations against `ping`'s 100). A missing or unparseable
  config means "no opinion" and everything is scanned as before, so a bad read
  can never silently switch supervision off. Session pools openclaw owns
  (`claude`, `claude-code`, `main` — override with `WARDEN_UNMANAGED_AGENTS`)
  are left alone; warden has never rotated one.
- `bin/doctor.sh`: report any undeclared agent whose sessions changed in the
  last `WARDEN_STRAY_ACTIVE_MAX_AGE` seconds (default 24h) as a failure, which
  also alerts. This is what makes the gate above safe to have: an agent dropped
  from `agents.list` by mistake stops being supervised, and this check is the
  only thing between that and silence.

### Fixed — prompt cache stability

- `lib/memory.sh`: only rewrite a workspace `MEMORY.md` / `CONTEXT.md` when the
  content actually changed. Both files are injected into the agent's system
  prompt, and `bin/context-sync.sh` rewrote them on every pass with a fresh
  `_Updated:` timestamp at the top of the block. Because a provider's prompt
  cache is invalidated from the first differing byte onward, that one moving
  line discarded the cached prefix every few minutes even when the summary was
  identical — the failure mode predicted in #31. Writes now compare content
  with the clock blanked, so an unchanged summary leaves the file untouched.
  A changed summary, session id, or channel still rewrites as before.
- `lib/memory.sh`: move the injected block **below** the agent's own memory
  instead of above it. Because a cache is invalidated from the first differing
  byte onward, putting the only volatile section on line 1 meant a legitimate
  summary change discarded the entire file — for the largest agent in the
  fleet, 11.3KB thrown away to update 2.2KB. With the block last, the 9.2KB of
  stable rules and lessons above it stay warm. Existing files migrate on their
  next write; no manual step.
- `bin/reflect.sh`, `bin/apply-lessons.sh`: close the `## Lessons learned`
  section when the warden block starts, so new bullets are still inserted above
  it rather than flushed at end-of-file underneath it. Works under either
  layout.
- `tests/test-memory.sh`: exercise the real `write_workspace_context` against
  the sandbox instead of a hand-copied stub that had drifted from it. Adds
  coverage for the migration and for the cached prefix staying byte-identical
  across a real summary change.

### Changed — health dashboard information architecture

- `contrib/health-dashboard/generate.sh` rewritten around a founder-first
  layout: a plain-English verdict (written each run by a cheap model, with a
  deterministic fallback so the page never blanks), a ranked "needs attention"
  list computed from live signals, a unified fleet-performance panel (work /
  personal / experimental, each agent with model + role + score + insight +
  active/idle), a condensed system-health strip in plain terms, and the old
  operator tables demoted to a collapsed "raw signals" drawer. Keeps the CRT
  phosphor styling; adds real per-agent model labels.

### Added — burn firewall (`feat/burn-firewall`)

- Subscription-window protection for always-on agents: per-channel usage
  ledger sampled every scan (`state/burn/<agent>.jsonl`, deduped cumulative
  snapshots), `session-warden burn` report ("what ate my usage", rotation
  resets handled), BURN/BUDGET/LOOP detection with throttled Telegram alerts,
  opt-in enforcement (`WARDEN_BURN_ENFORCE=1`: pause on budget breach — idle
  CLIs only; env-matched kill of confirmed retry loops with recovery via the
  normal rotate pipeline), daily digest, and ledger retention in
  `cleanup-archives.sh`. All knobs under `WARDEN_BURN_*` / `WARDEN_LOOP_*`;
  sampling on by default, enforcement off by default.

### Added — Session Warden Solo (`feat/burn-solo`)

- Standalone Claude Code metering for sessions that do not pass through the
  OpenClaw gateway: `bin/burn-solo-sample.sh` samples recent
  `~/.claude/projects/*/*.jsonl` transcripts into `state/burn/solo.jsonl`,
  excludes OpenClaw agent transcripts, tolerates malformed JSONL lines, and
  starts metering from first sight instead of back-parsing old history.
- `session-warden burn` now includes solo usage as agent `solo`, supports
  `--solo`, and can show a whole-plan window percentage with
  `WARDEN_BURN_PLAN_BUDGET` across agents plus standalone sessions.
- Solo spike alerts reuse the burn event/throttle ledger and add a macOS
  desktop notification fallback (`WARDEN_BURN_DESKTOP_NOTIFY=1`) for users
  without Telegram configured. Solo mode is alert-only: it never pauses, kills,
  or signals human-owned Claude Code processes.
- `deploy/com.session-warden.burn-solo.plist.example` provides a launchd user
  agent template for sampling standalone Claude Code usage every 120 seconds on
  macOS; `install.sh` points Darwin users at the template but does not install
  or load launchd jobs automatically.

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
