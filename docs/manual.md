# Operator manual

This is the long reference that used to live in the README: rotation, memory,
the learning loop, config, and architecture.

**Setting this up for the first time?** Start at the [README](../README.md).
It is pictures and three commands.

Related: [routing](routing.md) · [onboard](onboard.md) · [integrations](integrations.md)

---

## The problem

Claude Code sessions accumulate tokens, turns, and JSONL file size over time. Eventually they hit limits — token bloat, context overflow, compaction loops — and the session dies. You're left with a dead session and no memory of what was happening.

Runtimes can make this worse. OpenClaw, for example, keeps a dead session ID pinned and resumes it on every new message, creating an infinite error loop. It's not a rate limit. It's a stale pointer.

## How it works

A cron job runs every 30 seconds. When it finds a session that's failed or exceeds configurable thresholds (tokens, turns, compaction count), it runs a 4-step rotation:

1. **Detect** — scan session state for bloat, failures, or zombies (dead CLI process with stale JSONL)
2. **Rotate** — backup state, archive the JSONL (never deleted), clean up the stale session reference
3. **Summarize** — extract the full conversation (text + tool actions), summarize with a fast model (Haiku), write it into the agent's memory files
4. **Restart** — restart the runtime gateway so agents boot with full context already loaded

The agent comes back online in under a second, knowing what it was doing.

## Module map

| Module | Entry point | Schedule | What it does |
|---|---|---|---|
| Scan + rotate | `bin/scan.sh` → `bin/rotate.sh`, `bin/summarize.sh` | cron, 30s (install.sh) | detect bloated/failed/zombie sessions; archive, summarize into memory, restart |
| Stall reaper | `bin/reap-stalls.sh` | cron, 30s (install.sh) | gateway-independent backstop that kills silently wedged turns |
| Doctor | `bin/doctor.sh` | cron, 5 min (install.sh) | warden self-health + dead-man's switch |
| Snapshot | `bin/snapshot.sh` | cron, 30 min (install.sh) | capture standalone Claude Code sessions into GBrain |
| Context sync | `bin/context-sync.sh` | cron, 5 min (manual) | refresh MEMORY.md/CONTEXT.md from *live* sessions so restarts are always fresh |
| Archive cleanup | `bin/cleanup-archives.sh` | cron, daily (manual) | bounded growth for archives, logs, queues, cooldowns, burn ledgers |
| Worktree GC | `bin/reap-worktrees.sh` + `bin/wt` | cron, 15 min (manual) | ephemeral per-task git worktrees for agents, garbage-collected |
| Burn firewall | `lib/burn.sh` (in scan) + `bin/burn-report.sh` | with scan / on demand | meter per-agent token burn; alert or enforce on spikes, budgets, retry loops |
| Burn solo | `bin/burn-solo-sample.sh` | launchd/cron (manual) | meter standalone Claude Code usage outside any gateway |
| Dream cycle | `bin/dream-cycle.sh` | nightly 03:30 (`deploy/dream-cycle.timer`) | GBrain maintenance: ingest runtime transcripts, embed stale pages, doctor, daily digest |
| Reflector | `bin/reflect.sh` | nightly 04:10 (`deploy/reflect.timer`) | distill verified lessons per agent, staged for human review |
| Skill harvester | `bin/harvest-skills.sh` | weekly Sun 05:00 (`deploy/harvest.timer`) | mine repeated workflows into staged SKILL.md drafts |
| Model scorecard | `bin/scorecard.sh` | weekly Sat 06:00 (`deploy/scorecard.timer`) | fixed benchmark across models, blind-judged |
| Fleet review | `bin/fleet-review.sh` | weekly Sat 06:30 (`deploy/fleet-review.timer`) | judge each roster agent's *real* week of work: 0-100 role-fit score + insight |
| Memory evals | `bin/eval-memory.sh` | monthly 1st 07:00 (`deploy/eval-memory.timer`) | replay fixed cases against current memory; pass-rate delta is the regression signal |
| Rate guard | `bin/rate-guard.sh` | every 2 min (`deploy/rate-guard.timer`) | demote rate-limited providers fleet-wide until reset; handoff before rewrite; one Telegram alert |
| Model-switch handoff | `bin/handoff.sh`, `bin/model-switch.sh` | on demand | checkpoint live work to memory + GBrain before changing models; rate-guard uses the same primitive |
| Worker route / run | `bin/route.sh`, `bin/run.sh` | on demand | credits-first pick among bash workers; user rules in `config/routing.yaml` win |
| Onboard | `bin/onboard.sh` | on demand | detect hosts + workers, write routing.yaml, install host skills (no OpenClaw required) |
| MCP supervisor | `bin/mcp-supervisor.sh` | manual / cron | keep heavy MCP servers alive across rotations |
| Fleet board | `contrib/fleet-live/collect.py` | cron, 2 min (manual) | static public status board: live sessions, spend, recurring loops, skills learned |

`install.sh` wires the cron entries marked *(install.sh)*. Rows marked *(manual)* need a crontab line you add yourself (shown in each section below); the timer-based rows are systemd user units you copy from `deploy/` (see Quick start).

## Session memory

Rotation without memory means the agent starts from scratch. The warden writes memory at two levels on every rotation (and every 5 minutes for live sessions, via context-sync):

**Claude Code project memory.** The full conversation — not just text messages, but every tool action (files edited, commands run, branches created) — is extracted from the archived JSONL and summarized by a fast model (`WARDEN_SUMMARY_MODEL`, default Haiku) into a structured entry: what was happening, actions taken, decisions made, pending work, lesson candidates, and entity wikilinks. It lands as a per-channel file under the agent's Claude Code project memory dir (`~/.claude/projects/<agent-project>/memory/session_<channel>.md`), indexed in that dir's `MEMORY.md`. Each channel's file is *replaced* on rotation — no unbounded growth — and compacted by a second model call if it exceeds `WARDEN_MEMORY_MAX_BYTES`.

**Workspace injection — the load-bearing layer.** The same summary is written into the agent's workspace: `CONTEXT.md`, and a marker-delimited block in the workspace `MEMORY.md` (`<!-- SESSION-WARDEN-START/END -->`). The runtime injects workspace memory into the agent's prompt at boot — context is *injected*, not voluntarily loaded — which is why continuity survives model switches. The warden's block is deliberately placed after the agent's own content so the prompt-cache prefix stays warm, and writes are skipped when content is unchanged so the file stays byte-identical.

Carry-over is explicit: the previous memory is fed back into each new summarization with instructions to carry forward unresolved pending items, so a task survives any number of rotations. The recovery message that wakes the agent additionally inlines `CONTEXT.md`, a GBrain cross-session briefing, and any crash buffer. If the previous turn died early (failed, zombie, stalled) or summarization timed out, that text starts with `INCOMPLETE:` so the next agent cannot read a transcript tail as a finished report.

**Agent-side discipline** completes the picture: agents are instructed via `CLAUDE.md` to proactively write important context to memory during the session, so even an unexpected death loses little.

Session boundaries become invisible.

## Model-switch handoff

Changing an agent's model (or rate-guard demoting a provider) used to kill mid-work working memory: the transcript often survived on disk, but nothing durable said what the agent was doing. Use the warden — don't edit the runtime's config by hand.

```bash
# Checkpoint only (safe before a manual restart)
session-warden handoff my-agent
session-warden handoff my-agent --reason model-switch

# Checkpoint then change primary model
session-warden model-switch my-agent google/gemini-3.6-flash
session-warden model-switch my-agent gemini-3.6-flash
```

What it does:

1. Detects the runtime per agent — OpenClaw (`~/.openclaw/agents/<id>`) or Hermes (`~/.hermes-<id>`)
2. Waits out mid-turn / active work (best-effort)
3. OpenClaw: graceful flush + transcript extract → Claude memory + CONTEXT.md
4. Hermes: extract from `state.db` → `memories/HANDOFF.md` + CONTEXT.md
5. Upserts GBrain `session-warden/handoff/<agent>-<channel>` and points the live page at it
6. `model-switch` applies the new primary (OpenClaw hot-reloads; Hermes restarts its gateway) and queues a wake/recovery that tells the agent to read the handoff first

Rate-guard demote/restore calls the same handoff for every agent whose **primary** model would change. If handoff fails for an agent, that agent's chain is left unchanged (partial demotion) and Telegram gets an alert — no silent amnesia.

## Snapshot (standalone Claude Code sessions)

Rotation and memory cover gateway-managed agent sessions. But you also run plain Claude Code sessions yourself — in repos, in your home dir, anywhere. The **snapshot module** (`bin/snapshot.sh`) captures those into GBrain so they become permanent, searchable, linked memory too. It reads `~/.claude/projects` directly — no gateway involved.

Every `WARDEN_SNAPSHOT_INTERVAL_MINUTES` (default 30) it:

1. Scans `~/.claude/projects/**/*.jsonl` modified in the last `WARDEN_SNAPSHOT_WINDOW_MINUTES` (default 120)
2. **Skips gateway-managed agent sessions** (path matches the OpenClaw agents pattern) — those are already handled by context-sync (live) and rotation, so there's no double-ingestion
3. Extracts the transcript (`lib/extract.sh`), summarizes it with Haiku, and writes a typed GBrain page at `sessions/<date>/<agent>-<shortid>` (tags `[session, snapshot, <agent>]`), linked `performed_by` to its agent and with `mentions` edges to any entities the summary names
4. Tracks `{last_mtime, last_turn_count}` per session in `state/snapshot/state.json`, re-summarizing only when the file changed **and** at least `WARDEN_SNAPSHOT_MIN_TURNS` (default 4) new turns accrued — so most runs are cheap no-ops and Haiku only fires on real activity

The agent each session is attributed to is resolved from its working directory (`lib/agent-attribution.sh`): OpenClaw agents by their agents directory, your home dir as `home`, everything else `unknown`. To attribute your own repos or project paths to named agents, add glob rules to `config/agent-paths.env` (copy `config/agent-paths.env.example`); without it, non-gateway paths just resolve to `unknown`.

**GBrain is what this module writes to** — without the `gbrain` CLI the run logs `GBRAIN UNAVAILABLE` and exits cleanly having done nothing. GBrain is the canonical cross-session knowledge graph; snapshot writes there only (Claude Code's own auto-memory already handles local per-project persistence).

Config lives in `config/thresholds.env` (`WARDEN_SNAPSHOT_*`). Install adds a cron entry; `deploy/snapshot.{service,timer}` are the systemd alternatives.

## Dream cycle (nightly GBrain maintenance)

GBrain's value compounds only if the graph is maintained while idle. The **dream cycle** (`bin/dream-cycle.sh`) does the maintenance the warden's per-rotation writes intentionally skip, nightly at 03:30 via `deploy/dream-cycle.{service,timer}`:

1. **`gbrain transcripts ingest --since last`** — import new agent sessions from the runtimes it finds on disk (OpenClaw session trees and `~/.hermes*` homes) as redacted conversation pages (GBrain 0.46+; skipped on older CLIs). Does **not** pass `--all`, which would also vacuum every Claude Code session on the host. Disable with `WARDEN_GBRAIN_INGEST=0`
2. **`gbrain embed --stale`** — `gbrain put` does not embed inline, so without this pass embedding coverage decays toward zero and search quality with it
3. **`gbrain doctor`** — graph health check; Telegram alert on warn/error
4. **Daily digest** — synthesizes the day's session pages into a single `daily-digest` page linking them, so the graph gains a queryable per-day rollup

It runs *before* the reflector (04:10) on purpose: by the time lessons are distilled, the day's pages are already embedded and searchable. Requires the `gbrain` CLI; a lock file prevents overlapping runs.

## Reflector (nightly lesson distillation)

Session memory answers "what was I doing?"; nothing answers "what should I have learned?". The **reflector** (`bin/reflect.sh`) closes that loop nightly, ACE-style (append-only context engineering — new rules are only ever added, never rewritten over existing ones).

For each agent in `WARDEN_REFLECT_AGENTS` (default: every agent in `config/fleet-roster.tsv`) it:

1. **Gathers** the last 24h of material: the agent's session JSONLs (extracted with `lib/extract.sh`), the warden's rotation summaries, and the agent's own daily notes in `memory/`. Agents with no material are skipped (logged as SKIP).
2. **Distills** 0-5 lesson bullets with a stronger model (`WARDEN_REFLECT_MODEL`, default Sonnet). The prompt demands general rules that would change future behavior — not restatements of what happened — and feeds in the agent's current `## General rules` + `## Lessons learned` so it never duplicates an existing rule. Each bullet is tagged `[YYYY-MM-DD, source: <agent> sessions]`. If nothing clears the bar, the model outputs `NO_LESSONS`.
3. **Verifies** with a second, cheaper model (`WARDEN_REFLECT_VERIFY_MODEL`, default Haiku) acting as a skeptic: each bullet is marked KEEP or REJECT — rejected if it is not grounded in the source material, is too specific to today, contradicts an existing rule, or derives from untrusted external content. Only KEEPs survive. If the verifier itself fails, bullets are staged with an UNVERIFIED warning and auto-apply is blocked.
4. **Stages** survivors in the agent's `memory/pending-lessons-YYYY-MM-DD.md` for human review. Nothing touches MEMORY.md unless `WARDEN_REFLECT_AUTO_APPLY=1` (default 0), in which case verified bullets are appended directly under `## Lessons learned` (below the warden block).
5. **Notifies** once per run via Telegram (`WARDEN_REFLECT_NOTIFY=1`): per-agent lesson counts, where the pending files live, and the apply command.

The **staged-approval flow**: review a pending file, delete any bullet you disagree with, then promote the survivors with

```bash
bin/apply-lessons.sh <agent>          # apply the most recent pending file
bin/apply-lessons.sh <agent> --all    # apply every pending file for the agent
```

`apply-lessons.sh` appends the bullets under `## Lessons learned` in the agent's `MEMORY.md`, records each lesson in GBrain as `lessons/<agent>/YYYY-MM-DD-<n>` with provenance frontmatter per the GBrain conventions (`scope:` work/personal by team, `source: reflector`, `trust: inferred`), and archives the pending file to `memory/applied/`.

Flags on `reflect.sh`: `--agent <name>` reflects a single agent; `--dry-run` prints the distilled+verified bullets without writing or notifying. Logs to `state/reflect.log`; a lock file prevents overlapping runs; LLM failures are logged and skipped, never fatal.

Runs nightly at 04:10 UTC via `deploy/reflect.{service,timer}` — after the dream-cycle (03:30), so the day's GBrain pages are already embedded. Config (`config/thresholds.env`):

| Variable | Default | Meaning |
|---|---|---|
| `WARDEN_REFLECT_AGENTS` | fleet roster | space-separated agents to reflect on; unset = every agent in `config/fleet-roster.tsv` |
| `WARDEN_REFLECT_MODEL` | `claude-sonnet-4-6` | distillation model |
| `WARDEN_REFLECT_VERIFY_MODEL` | `claude-haiku-4-5-20251001` | skeptic/verifier model |
| `WARDEN_REFLECT_AUTO_APPLY` | `0` | `1` = skip staging, append verified lessons straight to MEMORY.md |
| `WARDEN_REFLECT_NOTIFY` | `1` | one Telegram digest per run |
| `WARDEN_REFLECT_WINDOW_MINUTES` | `1440` | lookback window for material |

## Skill harvester (weekly skill mining)

The reflector distills one-line *lessons*; nothing captures repeated *workflows*. The **skill harvester** (`bin/harvest-skills.sh`) closes that loop weekly: if an agent did the same multi-step thing twice this week, that procedure should become a skill, not stay tribal knowledge in session summaries.

For each agent in `WARDEN_HARVEST_AGENTS` (default: every agent in `config/fleet-roster.tsv`) it:

1. **Gathers** the week's material (`WARDEN_HARVEST_WINDOW_DAYS`, default 7): the warden's rotation summaries, the agent's own daily notes in `memory/`, and lessons already applied in `memory/applied/`. Agents with no material are skipped (logged as SKIP).
2. **Lists existing skills** — the agent's own, the shared fleet skills dir, and anything already staged — and feeds the names to the model so it never proposes a duplicate (a belt-and-braces name check enforces this even if the model ignores the instruction).
3. **Mines** with one strong-model call per agent (`WARDEN_HARVEST_MODEL`, default Sonnet): identify workflows performed **2+ times** this week that no existing skill covers, and emit a complete `SKILL.md` draft for each — YAML frontmatter (`name`, `description` with trigger conditions) plus a body with steps, known failure modes, and anti-patterns, all grounded in the week's material. At most **2 proposals per agent per run**. If nothing clears the bar, the model outputs `NO_SKILLS`.
4. **Stages** each draft in a pending-skills dir (`skills-pending/<agent>/<skill-name>/SKILL.md`) — it **never writes into a live skills dir**.
5. **Notifies** once per run via Telegram (`WARDEN_HARVEST_NOTIFY=1`): per-agent proposal counts and names, where the drafts live, and the promote command. With a Discord bot configured (below), each staged skill additionally gets an **interactive Discord card** with Promote / Promote shared / Reject / View draft buttons.

The **staged-approval flow**: read a draft, edit it if needed, then promote it with

```bash
bin/promote-skill.sh <agent> <skill-name>            # into the agent's own skills dir
bin/promote-skill.sh <agent> <skill-name> --shared   # into the shared fleet skills dir
```

`promote-skill.sh` moves the pending dir into the live skills dir (refusing to overwrite an existing skill) and records the skill in GBrain as `skills/<skill-name>` with provenance frontmatter per the GBrain conventions (`scope:` work/personal by team, `source: skill-harvester`, `trust: inferred`).

Flags on `harvest-skills.sh`: `--agent <name>` harvests a single agent; `--dry-run` prints the proposed drafts without writing or notifying. Logs to `state/harvest.log`; a lock file prevents overlapping runs; LLM failures are logged and skipped, never fatal.

Runs weekly, Sunday 05:00 UTC, via `deploy/harvest.{service,timer}` — after that night's reflector (04:10) so the week's lessons are already staged. Config (`config/thresholds.env`):

| Variable | Default | Meaning |
|---|---|---|
| `WARDEN_HARVEST_AGENTS` | fleet roster | space-separated agents to harvest; unset = every agent in `config/fleet-roster.tsv` |
| `WARDEN_HARVEST_WINDOW_DAYS` | `7` | lookback window for material |
| `WARDEN_HARVEST_MODEL` | `claude-sonnet-4-6` | skill-mining model |
| `WARDEN_HARVEST_NOTIFY` | `1` | one Telegram digest per run |
| `WARDEN_DISCORD_BOT_TOKEN` | (unset) | Discord bot for interactive proposal cards (dedicated-bot path) |
| `WARDEN_HARVEST_DISCORD_ACCOUNT` | (unset) | OpenClaw Discord account that posts cards (fleet-native path) |
| `WARDEN_HARVEST_DISCORD_CHANNEL_ID` | (unset) | channel the cards are posted to |
| `WARDEN_DISCORD_ALLOWED_USER_IDS` | (unset) | who may click the buttons — empty = nobody |
| `WARDEN_HARVEST_NOTIFY_DISCORD` | `1` | `0` = skip Discord cards even when configured |

### Interactive Discord proposals

Instead of copy-pasting `promote-skill.sh` commands from a text digest, you can act on proposals directly in Discord. When `WARDEN_HARVEST_DISCORD_CHANNEL_ID` is set along with either `WARDEN_HARVEST_DISCORD_ACCOUNT` (OpenClaw path) or `WARDEN_DISCORD_BOT_TOKEN` (dedicated-bot path), the harvester posts one card per staged skill with **Promote**, **Promote shared**, **Reject**, and **View draft** buttons.

**OpenClaw path (preferred on fleets that already run Discord via OpenClaw):** set `WARDEN_HARVEST_DISCORD_ACCOUNT` (the OpenClaw Discord account name). Cards are posted with `openclaw message send --presentation`; clicks are handled by the [`harvest-skill-actions`](../contrib/openclaw-plugins/harvest-skill-actions) OpenClaw plugin — no second Discord bot or gateway.

**Dedicated-bot path:** set `WARDEN_DISCORD_BOT_TOKEN` and run [`contrib/discord-harvest-actions`](../contrib/discord-harvest-actions) via `bin/harvest-actions.sh` / `deploy/harvest-actions.service`.

Promote runs `promote-skill.sh` (with `--shared` for the fleet-wide variant), Reject moves the draft to a rejected dir (never deletes), View replies ephemerally with the `SKILL.md`. Handled cards drop their buttons. Clicks are gated to the `WARDEN_DISCORD_ALLOWED_USER_IDS` allowlist and refused otherwise (default-deny: your agents live in these channels too).

## Model scorecard (weekly A/B benchmark)

When several experimental agents run the same fleet role on different models, nothing measures which model is actually better at the fleet's work. The **model scorecard** (`bin/scorecard.sh`) closes that loop weekly with a fixed, committed benchmark across the Hermes agents you list in `WARDEN_SCORECARD_AGENTS`. (This module runs turns through the Hermes CLI, so it currently benchmarks Hermes-hosted agents only.)

Each run it:

1. **Runs the task set** — `config/scorecard-tasks.jsonl`, 8 fixed tasks spanning factual reasoning, summarization, structured extraction (JSON), writing in a constrained style, planning, a GBrain-grounded question (tests MCP tool use, for agents with the gbrain server), a clarify-before-acting judgment check, and a logic puzzle. Every agent answers every task as a real non-interactive Hermes turn (`HERMES_HOME=<home> hermes chat -Q -q <prompt>`, `WARDEN_SCORECARD_TURN_TIMEOUT` 180s). Raw answers land in `state/scorecard/<date>/<agent>/<task-id>.txt`; a dead turn is recorded verbatim and scored 0.
2. **Judges blind** — one call per answer to the claude CLI (`WARDEN_SCORECARD_JUDGE_MODEL`, default Sonnet): task prompt + rubric + answer, score 0-10 with a one-line justification. The judge is **never told which agent or model produced the answer** — model names appear only in the report, added after judging.
3. **Reports** — `state/scorecard/<date>/REPORT.md`: per-task/per-category scores and a totals row per agent, plus every judge justification. Mirrored to GBrain as `scorecards/YYYY-MM-DD` (`scope: personal`, `source: scorecard`, `trust: verified` — scores are measured against a fixed rubric, not asserted).
4. **Notifies** once per run via Telegram (`WARDEN_SCORECARD_NOTIFY=1`): the totals table.

Because the task set is committed and fixed, week-over-week totals are comparable — a model/config regression in one agent shows up as a falling total, not vibes. Change the task set deliberately and rarely; history resets when you do.

Flags: `--agent <name>` benchmarks a single agent; `--task <id>` runs a single task; `--dry-run` prints answers + scores without writing the report or notifying. Logs to `state/scorecard.log`; a lock file prevents overlapping runs.

Runs weekly, Saturday 06:00 UTC, via `deploy/scorecard.{service,timer}`. Config (`config/thresholds.env`):

| Variable | Default | Meaning |
|---|---|---|
| `WARDEN_SCORECARD_AGENTS` | (unset) | experimental Hermes agents (homes at `~/.hermes-<name>`) — set your own |
| `WARDEN_SCORECARD_JUDGE_MODEL` | `claude-sonnet-4-6` | blind judge |
| `WARDEN_SCORECARD_TURN_TIMEOUT` | `180` | seconds per agent turn before it's scored 0 |
| `WARDEN_SCORECARD_NOTIFY` | `1` | one Telegram digest per run |
| `WARDEN_HERMES_BIN` | `~/hermes-agent/venv/bin/hermes` | Hermes CLI (shared venv, per-agent via `HERMES_HOME`) |

## Fleet review (weekly real-work quality review)

The scorecard benchmarks experimental agents on synthetic tasks; it says nothing about how your production agents perform their *real* jobs. The **fleet review** (`bin/fleet-review.sh`) closes that gap weekly: for every agent in `config/fleet-roster.tsv` it harvests the work the agent actually did over the window (`lib/harvest-work.py`, over the agent's session transcripts), then a judge (`WARDEN_FLEET_JUDGE_MODEL`, default Sonnet) scores that real output against a role-aware quality bar: a 0-100 score, a one-line insight, and one recommended action per agent.

Dormant agents (no sessions in the window) are recorded as idle, not scored or penalised. An agent that correctly does nothing — say, a filter agent returning NO_REPLY on marketing mail — is good filtering: the harvester collapses those runs so the judge sees the substantive work, and the judge is told as much.

Outputs land in `state/fleet-review/<date>/`: `review.json` (machine-readable), `REPORT.md` (per-agent score, delta vs last run, insight), and `<agent>.sample.txt` (the harvested sample, for audit). Mirrored to GBrain as `fleet-review/YYYY-MM-DD`; one Telegram digest per run.

Flags: `--agent <name>` reviews a single agent; `--dry-run` prints scores without writing or notifying. Requires `python3` and `jq`. Runs weekly, Saturday 06:30 UTC, via `deploy/fleet-review.{service,timer}` — after that morning's scorecard. Config (`config/thresholds.env`):

| Variable | Default | Meaning |
|---|---|---|
| `WARDEN_FLEET_JUDGE_MODEL` | `claude-sonnet-4-6` | scores each agent's real work against its role |
| `WARDEN_FLEET_WINDOW_DAYS` | `7` | look-back window for harvested work |
| `WARDEN_FLEET_MAX_SAMPLE_CHARS` | `12000` | per-agent work-sample cap fed to the judge |
| `WARDEN_FLEET_JUDGE_TIMEOUT` | `150` | seconds per judge call |
| `WARDEN_FLEET_NOTIFY` | `1` | one Telegram digest per run |

## Memory evals (monthly regression)

The reflector writes memory; nothing checked whether the memory files actually carry the knowledge an agent needs. The **memory eval** (`bin/eval-memory.sh`) closes that loop monthly for the agents in `WARDEN_EVAL_AGENTS` (default: the fleet roster): a fixed set of eval cases per agent, replayed against the agent's *current* `MEMORY.md` + `AGENTS.md`, with the pass-rate delta against the previous run as the regression signal.

**Generating cases** (one-time per agent, `--generate <agent>`): reads the agent's `MEMORY.md` below the warden block plus its GBrain lessons pages (`gbrain search "lessons/<agent>"`), and asks the claude CLI (`WARDEN_EVAL_GEN_MODEL`, default Sonnet) for 10-15 cases into the agent's `evals/cases.jsonl` — each `{"id", "question", "expected"}` where `question` is a realistic situation in which the agent should apply a stored rule/fact and `expected` is the rule/fact a correct answer must surface. Cases test **application**, not parroting: the question never names the rule. Lines are validated individually; a batch under 5 valid cases refuses to overwrite. Keep cases fixed between runs — deltas are only meaningful against a stable set.

**Running** (default mode), for each agent with a cases file:

1. **Answers** each case with the claude CLI (`WARDEN_EVAL_MODEL`, default Sonnet) with the agent's current `MEMORY.md` (below the warden block) + `AGENTS.md` piped in as context — we're testing whether the memory files carry the knowledge, not burning live agent sessions.
2. **Judges** each answer with a cheap model (`WARDEN_EVAL_JUDGE_MODEL`, default Haiku): does it reflect the expected rule/fact? PASS/FAIL + one-line note. Paraphrase passes; ignoring or contradicting fails.
3. **Reports** — `state/evals/<date>/REPORT.md`: per-agent pass rates with a per-agent delta vs the previous run's `rates.tsv` (the regression signal), plus every failure with its judge note. Raw answers in `state/evals/<date>/<agent>/<case-id>.txt`. Mirrored to GBrain as `evals/YYYY-MM-DD` (`scope: shared`, `source: eval-memory`, `trust: verified`).
4. **Notifies** once per run via Telegram (`WARDEN_EVAL_NOTIFY=1`): pass rates + failure count.

A falling pass rate means memory quality regressed — a lesson got lost in a rewrite, a migration to GBrain dropped context the agent still needs, or MEMORY.md bloated past usefulness.

Flags: `--agent <name>` evaluates a single agent; `--generate <agent>` (re)generates that agent's case set and exits; `--dry-run` prints per-case verdicts without writing the report or notifying. Logs to `state/evals.log`; a lock file prevents overlapping runs.

Runs monthly, 1st 07:00 UTC, via `deploy/eval-memory.{service,timer}`. Config (`config/thresholds.env`):

| Variable | Default | Meaning |
|---|---|---|
| `WARDEN_EVAL_AGENTS` | fleet roster | space-separated agents under eval; unset = every agent in `config/fleet-roster.tsv` |
| `WARDEN_EVAL_MODEL` | `claude-sonnet-4-6` | answers each case with the agent's memory attached |
| `WARDEN_EVAL_JUDGE_MODEL` | `claude-haiku-4-5-20251001` | PASS/FAIL judge |
| `WARDEN_EVAL_GEN_MODEL` | `claude-sonnet-4-6` | `--generate` case writer |
| `WARDEN_EVAL_NOTIFY` | `1` | one Telegram digest per run |

## Stall reaper (silent-hang backstop)

*OpenClaw-specific: this module reads OpenClaw's on-disk session schema and process markers.*

OpenClaw's gateway runs an in-process watchdog that kills a turn whose CLI child stops making progress. It's fast and precise, but it shares a failure domain with the gateway: it lives in the compiled runtime (a string patch that no-ops after `npm update openclaw`) and it needs the gateway's own event loop healthy enough to fire. When either fails, an agent turn hangs forever and the channel goes silent with no reply.

The **stall reaper** (`bin/reap-stalls.sh`) is the independent backstop. It reads gateway state from **disk and `/proc` only — never an RPC** — so it keeps working even when the gateway loop is wedged or the patch was wiped by an upgrade.

A turn is **STUCK** when, for a session, all hold:

1. `status == "running"` in the on-disk `sessions.json` (the gateway believes a turn is in flight — a live process alone can't tell you this, since idle sessions keep a persistent CLI process too)
2. no forward progress — `max(updatedAt, session JSONL mtime)` is older than `WARDEN_STALL_HARD_CAP_SECONDS` (default 900s / 15 min). A healthy turn, however long, keeps appending its transcript; a network-stalled one can't write anything.

The cap sits well **above** the in-gateway watchdog, so the reaper only fires when the fast layer didn't — it never touches healthy long turns. Process liveness is not part of the verdict; it decides the **action**:

- **live wedged child found** → `SIGTERM`→`SIGKILL` it directly (`kill(2)`, fully gateway-independent). The gateway sees the child exit and fails the turn.
- **no live child** (turn already died, gateway never cleared `running`) → clear the stale state on disk + hand off to recovery, without disrupting the other agents.
- **still stuck on the next tick** after we acted → the gateway event loop itself isn't reacting → `openclaw gateway restart` (shared cooldown with `scan.sh`).

Either way the killed session is marked failed and the reaper **delivers the "you're back" nudge itself** (`openclaw agent --deliver`, backgrounded), rather than depending on `scan.sh`'s drainer being scheduled — independence is the whole point.

Process identity is safety-gated: a pid is only ever killed if its cmdline carries the session's `--session-id` **and** its `/proc/<pid>/environ` has the runtime's agent-ID marker for that agent — so a human's own `claude` session is never touched. Honors `WARDEN_DRY_RUN=1`.

**Contract self-check.** The reaper reads the gateway's on-disk `sessions.json` schema. If a future upgrade reshapes that file, detection would silently return nothing and the reaper would no-op — quietly reintroducing the silent hang. So each run validates the schema and, on drift (entries present but none expose `status` / `cliSessionIds` / `updatedAt`, or the file won't parse), logs loud and fires a Telegram alert (throttled hourly) instead of failing silent. This is the one piece that keeps it honest across gateway versions: the disk + CLI contracts are far more stable than the compiled-JS patch's anchors, but a major version bump can still move them — and when it does, you get pinged, not silence.

Runs on its own cron tick every 30s. Config: `WARDEN_REAP_ENABLED`, `WARDEN_STALL_HARD_CAP_SECONDS`, `WARDEN_STALL_KILL_GRACE_SECONDS`.

## Channel/plugin parity (silent-channel backstop)

*OpenClaw-specific: guards an OpenClaw packaging failure mode.*

Some OpenClaw upgrades unbundle a channel plugin from core. The gateway then boots "healthy", starts the channels whose plugins survived, and **silently ignores** an enabled channel that has no provider — no error, no log line, no health alert. The channel just goes dark. (Real incident, 2026-06-11: a release unbundled Discord; every Discord agent was deaf for ~14 hours before anyone noticed.)

`contrib/openclaw-patches/channel-parity.sh` enforces the invariant: **every channel enabled in `openclaw.json` must have an installed, enabled plugin that provides it.**

- `channel-parity.sh check` — report parity; exit 0 in-parity, 1 on mismatch.
- `channel-parity.sh heal` — for each missing channel, install the **official** `@openclaw/<id>` plugin (that scope only — never community code), schedule one gateway restart, and alert via the warden's Telegram. Loop-guarded: at most one heal attempt per channel per `CHANNEL_PARITY_COOLDOWN_SECONDS` (default 6h).

It's wired at three layers so a gap can't slip through any single one:

- **boot** — `deploy/20-channel-parity.conf` adds an `ExecStartPost` that runs `heal` after every gateway start (leading `-` + backgrounded, so it never blocks or fails startup).
- **cron** — `doctor.sh` runs `check` on its existing 5-min cadence and reports an unhealthy verdict on mismatch.
- **upgrade** — the update flow runs `check` before blessing a new OpenClaw version.

Missing prerequisites (no `jq`, no config) bail soft, never breaking gateway startup. Config: `OPENCLAW_CONFIG`, `OPENCLAW_BIN`, `CHANNEL_PARITY_COOLDOWN_SECONDS`, `CHANNEL_PARITY_STATE_DIR`.

## Burn firewall (subscription-window protection)

Always-on agents run on the Claude subscription you already pay for — and one
agent in a retry loop can quietly drain a 5-hour usage window before you
notice. The burn firewall is the warden's answer: it meters what every agent
consumes, tells you what ate your window, and (opt-in) steps in before a
runaway loop costs you your whole plan.

**Ledger** (`lib/burn.sh`) — every scan samples per-channel token counters into
an append-only ledger (`state/burn/<agent>.jsonl`). Records are cumulative
snapshots deduped on change, so idle fleets stay ledger-quiet and a missed
sample never corrupts history. Retention via `cleanup-archives.sh`
(`WARDEN_BURN_RETENTION_DAYS`).

**Report** (`bin/burn-report.sh`) — `session-warden burn` answers "what ate my
usage": tokens per agent/channel inside the current window (default 5h),
rotation resets handled, `--json` for scripts, `--agent` to filter, budget
percentage when a budget is set.

**Detection** (alert-only by default, throttled Telegram alerts):
- `BURN` — a channel consumed more than `WARDEN_BURN_SPIKE_TOKENS_5M` within
  5 minutes.
- `BUDGET` — an agent crossed `WARDEN_BURN_WARN_PCT` (warn) or 100% (breach)
  of `WARDEN_BURN_WINDOW_BUDGET` tokens per window.
- `LOOP` — the retry-loop signature: the last `WARDEN_LOOP_REPEATS` tool calls
  in the transcript are identical *and* they all land within
  `WARDEN_LOOP_WINDOW_SECS` (default 600s). This is the silent 5-10x budget
  killer. The time window is the discriminator: a real loop retries seconds
  apart, while an agent on a scheduled heartbeat runs the same probe once an
  hour and would otherwise be paged as a loop while sitting completely idle.
  Transcripts whose lines carry no parseable timestamp fall back to the
  identical-only rule, so older history is still covered.

**Enforcement** (`WARDEN_BURN_ENFORCE=1`, default off):
- Budget breach → the agent is **paused** until the window resets. Only idle
  CLI processes are stopped — a turn actively writing its transcript always
  finishes.
- Confirmed retry loop → the looping turn is **killed** (env-matched pid,
  never a human's `claude`; one kill per channel per cooldown) and recovery
  rides the normal rotate-and-summarize pipeline, so the agent reboots with
  context and a note about why.

**Digest** — one Telegram summary per day (`WARDEN_BURN_DIGEST_HOUR`, default
21:00): fleet consumption for the last 24h plus firewall event counts. Events
live in `state/burn/events.jsonl`.

### Solo mode (standalone Claude Code)

Session Warden Solo covers the usage that never passes through a gateway:
plain Claude Code sessions under `~/.claude/projects`. The sampler
(`bin/burn-solo-sample.sh`, logic in `lib/burn-solo.sh`) writes the same
cumulative burn-ledger shape to `state/burn/solo.jsonl`, with each standalone
session reported as its own channel (`project:sid`). Gateway-managed agent
transcripts are excluded because the normal burn firewall already meters them.

This is subscription-window protection for the Claude plan you already pay for;
it is not API cost accounting. The point is to answer "what is eating my
Claude window?" across both always-on agents and manual Claude Code work.

On macOS, schedule solo sampling with the launchd template:

```bash
mkdir -p ~/Library/LaunchAgents && \
sed "s#__WARDEN_HOME__#$HOME/session-warden#g" \
  ~/session-warden/deploy/com.session-warden.burn-solo.plist.example \
  > ~/Library/LaunchAgents/com.session-warden.burn-solo.plist && \
launchctl load ~/Library/LaunchAgents/com.session-warden.burn-solo.plist
```

Then inspect standalone usage:

```bash
session-warden burn --solo
```

Set `WARDEN_BURN_PLAN_BUDGET` to the token budget for your whole subscription
window when you want `session-warden burn` to answer "how much of my plan
window is left?" across agents plus solo sessions. The plan line is separate
from `WARDEN_BURN_WINDOW_BUDGET`, which remains the per-agent budget signal.

Solo mode follows a hard safety rule: it never pauses, kills, or signals a
human-owned Claude Code process. It only samples, reports, and sends throttled
spike alerts (`WARDEN_BURN_SPIKE_TOKENS_5M`) via Telegram and, on macOS,
desktop notifications (`WARDEN_BURN_DESKTOP_NOTIFY=1`, default).

Historical transcripts are not backfilled. The first time the solo sampler sees
an existing session file, it records the current byte offset as the baseline and
starts metering from the next append. That keeps setup fast even if
`~/.claude/projects` already contains months of history.

## Fleet lifeguard install (OpenClaw)

Already played with `onboard`? This is the other half — cron that keeps long Claude Code sessions alive.

```bash
cd ~/session-warden
bash install.sh
```

The installer targets the OpenClaw runtime and will:
- Check dependencies (`jq`, `claude` CLI, `curl` required; `python3` and `gbrain` optional — `gbrain` is needed for the snapshot module's output and the dream cycle)
- Detect your OpenClaw installation path (it exits if OpenClaw isn't installed — on another runtime, use the building blocks per [integrations.md](integrations.md) instead)
- Create a config file from the example, then **stop and ask you to review it** — edit `config/thresholds.env`, then run `bash install.sh` a second time
- On the second run: install cron entries (rotation scan + stall reaper every 30 seconds, doctor every 5 minutes, snapshot every 30 minutes)

The nightly/weekly modules (dream cycle, reflector, harvester, scorecard, fleet review, evals) are systemd user timers, installed separately:

```bash
cp deploy/*.service deploy/*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dream-cycle.timer reflect.timer harvest.timer \
  scorecard.timer fleet-review.timer eval-memory.timer rate-guard.timer
```

Only enable the timers whose modules you actually use (the dream cycle requires GBrain; the others mirror into GBrain when it's available). `deploy/snapshot.{service,timer}` is the systemd alternative to snapshot's cron entry. Rate guard needs the Anthropic OAuth usage signal (`~/.claude/.credentials.json`) and pairs with `contrib/openclaw-plugins/fleet-rate-guard` enabled in `openclaw.json`.

### CLI

After install, use the `session-warden` CLI:

```bash
# show session health across all agents
~/session-warden/bin/session-warden status

# dry run — see what would be rotated
~/session-warden/bin/session-warden scan --dry-run

# manually rotate a specific session
~/session-warden/bin/session-warden rotate my-agent discord-general

# what ate my usage window?
~/session-warden/bin/session-warden burn

# checkpoint an agent's live work before a manual restart or model change
~/session-warden/bin/session-warden handoff my-agent

# which bash workers are on PATH?
~/session-warden/bin/session-warden workers

# cheapest capable worker for this ask (JSON is the host-skill contract)
~/session-warden/bin/session-warden route --task "fix the typo in README" --json

# tail the log
~/session-warden/bin/session-warden logs -f

# verify the warden itself is alive and correctly wired
~/session-warden/bin/session-warden doctor

# show version
~/session-warden/bin/session-warden version
```

Optionally, add `~/session-warden/bin` to your PATH for shorter commands.

### Verify

```bash
# one command: checks cron wiring, loop heartbeats, gateway, deps, state hygiene
~/session-warden/bin/session-warden doctor

# dry run
~/session-warden/bin/session-warden scan --dry-run
cat ~/session-warden/state/scan.log

# test telegram alerts (optional)
source ~/session-warden/config/thresholds.env
source ~/session-warden/lib/notify.sh
notify_test
```

## Configuration

All config lives in `config/thresholds.env`. Key settings:

| Setting | Default | Description |
|---|---|---|
| `WARDEN_MAX_TOKENS` | 2,000,000 | Rotate when session exceeds this token count |
| `WARDEN_MAX_TURNS` | 500 | Rotate when session exceeds this many turns |
| `WARDEN_MAX_COMPACTIONS` | 10 | Rotate after this many compaction cycles |
| `WARDEN_MAX_CONSECUTIVE_FAILURES` | 3 | Back off after N consecutive rotation failures |
| `WARDEN_COOLDOWN_SECONDS` | 600 | Skip re-rotating same session within this window |
| `WARDEN_GATEWAY_RESTART_COOLDOWN_SECONDS` | 300 | Minimum seconds between gateway restarts |
| `WARDEN_SUMMARY_MODEL` | claude-haiku-4-5-20251001 | Model for summarization (any Claude model works) |
| `WARDEN_SCAN_AGENTS` | (empty) | Space-separated agent allowlist. Empty = scan all |
| `WARDEN_ARCHIVE_RETENTION_DAYS` | 7 | Delete archived JSONL files older than this |
| `WARDEN_DRY_RUN` | 0 | Set to 1 to log without rotating |
| `WARDEN_TELEGRAM_BOT_TOKEN` | (empty) | Telegram bot token for rotation alerts |
| `WARDEN_TELEGRAM_CHAT_ID` | (empty) | Telegram chat ID for rotation alerts |
| `WARDEN_NOTIFY_ROTATIONS` | 0 | Post a chat alert on every routine rotation. Off by default — routine threshold rotations recover silently (logged only); crash and stall recoveries always notify regardless |

All `WARDEN_*` variables can be overridden via environment (env takes precedence over the config file). The table above is the short list — [`config/thresholds.env.example`](../config/thresholds.env.example) is the complete, commented reference for every variable the scripts read, including all the per-module (reflector/harvester/scorecard/fleet-review/eval) settings and advanced knobs. Secrets (bot tokens, API keys) belong in `~/.config/session-warden/secrets.env` (chmod 600), which the config sources if present.

## Architecture

```
session-warden/
├── bin/
│   ├── session-warden       # CLI entrypoint (scan, status, rotate, burn, handoff, model-switch, workers, route, run, onboard, doctor, logs)
│   ├── workers.sh           # list catalog workers + PATH detect
│   ├── route.sh             # credits-first worker pick (rules, then heuristic)
│   ├── run.sh               # invoke a worker; route-then-run with one fallback
│   ├── onboard.sh           # detect hosts, write routing.yaml, install skills
│   ├── scan.sh              # cron entry point (every 30s)
│   ├── reap-stalls.sh       # independent stall backstop (disk + /proc only)
│   ├── reap-worktrees.sh    # GC for ephemeral agent worktrees (cron, 15 min)
│   ├── wt                   # agent worktree helper
│   ├── rotate.sh            # fast-path: backup, archive, cleanup
│   ├── summarize.sh         # extract transcript, summarize, write memory
│   ├── status.sh            # show session health across all agents
│   ├── context-sync.sh      # periodic context capture for active sessions
│   ├── snapshot.sh          # standalone Claude Code sessions → GBrain
│   ├── dream-cycle.sh       # nightly GBrain maintenance + daily digest
│   ├── reflect.sh           # nightly lesson distillation
│   ├── apply-lessons.sh     # promote staged lessons into MEMORY.md + GBrain
│   ├── harvest-skills.sh    # weekly skill mining
│   ├── promote-skill.sh     # promote a staged SKILL.md draft
│   ├── harvest-actions.sh   # Discord button listener (dedicated-bot path)
│   ├── scorecard.sh         # weekly blind model benchmark (Hermes agents)
│   ├── fleet-review.sh      # weekly real-work quality review (roster agents)
│   ├── eval-memory.sh       # monthly memory-quality regression
│   ├── handoff.sh           # checkpoint live work (CLI over lib/handoff.sh)
│   ├── model-switch.sh      # handoff, then change an agent's primary model
│   ├── rate-guard.sh        # demote/restore rate-limited providers
│   ├── burn-report.sh       # "what ate my usage" report (session-warden burn)
│   ├── burn-solo-sample.sh  # sample standalone Claude Code usage
│   ├── doctor.sh            # warden self-health + dead-man's switch
│   ├── backfill-gbrain-links.sh  # one-shot graph-edge backfill for old pages
│   ├── cleanup-archives.sh  # bounded growth for archives/logs/queues (cron daily)
│   └── mcp-supervisor.sh    # keep MCP servers alive across rotations
├── lib/
│   ├── detect.sh            # threshold + zombie detection
│   ├── extract.sh           # Claude Code JSONL → transcript (gateway-free)
│   ├── extract-hermes.py    # Hermes state.db → the same transcript shape
│   ├── memory.sh            # summarize + write memory files (per-runtime writers)
│   ├── handoff.sh           # runtime detection + checkpoint primitive
│   ├── burn.sh              # burn ledger, detection, enforcement
│   ├── burn-solo.sh         # standalone-session burn sampling
│   ├── rate-guard.{sh,py}   # provider demotion/restore logic
│   ├── dispatch.py          # worker catalog, detect, route, invoke
│   ├── workers.sh           # thin shell API over dispatch.py
│   ├── router.sh            # thin shell API for route
│   ├── notify.sh            # Telegram alerts (+ Discord cards)
│   ├── gbrain.sh            # bounded GBrain CLI wrappers
│   ├── registry.sh          # runtime agent registry (agents.list) gate
│   ├── roster.sh            # config/fleet-roster.tsv reader
│   ├── agent-attribution.sh # working dir → agent name resolution
│   ├── harvest-work.py      # collapse a week of transcripts into a work sample
│   ├── portable.sh          # GNU/BSD stat helpers
│   ├── reap.sh              # stall detection + safe kill logic
│   ├── channel-history.sh   # fetch recent Discord/Telegram messages
│   ├── detect-unprocessed.py  # identify unprocessed messages after crash
│   └── write-crash-buffer.py  # write crash buffer JSON
├── hooks/
│   └── post-summary/       # extensible: drop .sh scripts here
│       └── 01-gbrain.sh    # ingest memory into GBrain
├── contrib/
│   ├── openclaw-patches/   # optional OpenClaw JS patches (version-specific)
│   ├── openclaw-plugins/   # OpenClaw plugins: fleet-rate-guard, harvest-skill-actions, error-humanizer
│   ├── discord-harvest-actions/  # dedicated-bot Discord listener for skill proposals
│   ├── costs/              # token spend vs. subscription cost model
│   ├── timers/             # recurring-loop collector (systemd timers + crontab)
│   ├── fleet-live/         # static public fleet board
│   └── workers/            # how to wrap an API-only model as a bash worker
├── deploy/                 # systemd user units, logrotate policy, launchd template
├── docs/
│   ├── assets/             # logo, diagrams, Excalidraw sources
│   ├── integrations.md     # runtime contract vs worker (bash argv) contract
│   ├── routing.md          # catalog schema, rule language, credits-first heuristic
│   ├── onboard.md          # session-warden onboard + per-host skill install
│   └── manual.md           # operator manual (rotation, memory, learning loop)
├── skills/                 # host SKILL.md packs (openclaw, hermes, claude-code, codex, grok)
├── tests/                  # test suite (bash tests/run-tests.sh)
├── config/
│   ├── thresholds.env.example       # complete config reference
│   ├── agent-paths.env.example      # optional path-glob → agent attribution map
│   ├── fleet-roster.tsv.example     # agent roster + board presentation
│   ├── timers-labels.json.example   # recurring-loop labels
│   ├── cost-rates.json              # API list prices + subscription plans
│   ├── scorecard-tasks.jsonl        # fixed scorecard benchmark task set
│   ├── workers.json                 # built-in bash workers (claude, codex, kimi, grok, deepseek, glm)
│   ├── workers.d/                   # user overlays (*.example.json committed; rest gitignored)
│   ├── routing.yaml.example         # credits-first rules
│   └── thresholds.env, fleet-roster.tsv, timers-labels.json, routing.yaml   # yours (gitignored)
├── state/                  # runtime state (gitignored)
├── install.sh
└── LICENSE
```

### Data flow

```
cron (30s)
  └─ scan.sh
       ├─ detect.sh → find bloated/failed/zombie sessions
       ├─ rotate.sh → backup, archive JSONL, cleanup session reference
       │    └─ channel-history.sh → capture unprocessed Discord messages
       ├─ summarize.sh (synchronous, before restart)
       │    ├─ extract.sh → JSONL → human-readable transcript
       │    ├─ memory.sh → Haiku summarization → memory files
       │    └─ hooks/post-summary/*.sh (background)
       ├─ burn.sh → sample ledger, check spike/budget/loop
       ├─ gateway restart
       └─ send recovery messages to agents
```

## Hooks

Drop executable `.sh` scripts in `hooks/post-summary/` to extend the warden. They run after each session is summarized, with these environment variables:

| Variable | Description |
|---|---|
| `WARDEN_AGENT` | Agent name |
| `WARDEN_CHANNEL_KEY` | Full channel key |
| `WARDEN_SESSION_ID` | Claude CLI session ID |
| `WARDEN_MEMORY_FILE` | Path to the generated memory file |
| `WARDEN_TRANSCRIPT_FILE` | Path to the extracted transcript |
| `WARDEN_ARCHIVED_JSONL` | Path to the archived JSONL |

Scripts run in alphabetical order. Failures are logged but don't block other hooks or the gateway restart.

Example hooks you could write:
- Ingest memory into a knowledge base (the included `01-gbrain.sh` does this for GBrain)
- Post rotation summaries to Slack or Discord
- Archive transcripts to S3 or GCS
- Write to a Postgres audit log

## Extra tools

### MCP supervisor

Keeps heavy MCP servers (like Notion) running as persistent HTTP processes that survive CLI session rotations. Define your servers in `config/mcp-servers.env` (create it — no `.example` ships) or edit the defaults in the script.

```bash
bash ~/session-warden/bin/mcp-supervisor.sh start
bash ~/session-warden/bin/mcp-supervisor.sh status
bash ~/session-warden/bin/mcp-supervisor.sh ensure  # idempotent, good for cron
```

### Archive cleanup

Bounded growth for everything the warden writes: archived JSONLs, `scan.log`
(size-based rotation, `WARDEN_LOG_MAX_BYTES`), stale recovery/summary queue
items, expired cooldown markers, and burn ledgers. Run daily via cron.

```bash
# add to crontab
30 3 * * * ~/session-warden/bin/cleanup-archives.sh
```

### Log rotation (logrotate)

Weekly rotation for every log under `state/` (`scan.log`, `reflect.log`,
`harvest.log`, ...): keep 4 generations, compressed, `copytruncate` so the
append-only writers never notice. Install the policy system-wide:

```bash
sudo cp deploy/session-warden.logrotate /etc/logrotate.d/session-warden
# dry-run to verify
sudo logrotate -d /etc/logrotate.d/session-warden
```

Replace `YOUR_USER` in the file (path and `su` directive) with your username
first — the header comment has a `sed` one-liner. The size-based rotation in
`cleanup-archives.sh` (`WARDEN_LOG_MAX_BYTES`) stays on as a backstop for
sudden log floods between weekly runs; `dateext` keeps the two schemes'
filenames from colliding.

### Doctor (self-health + dead-man's switch)

The warden monitors agents; `doctor` monitors the warden. It derives the
expected wiring and diffs it against reality — cron entries, loop heartbeats,
gateway state, dist patches (opt-in), dependencies, disk, queue backlogs.

```bash
# manual check — exit 0 healthy, 1 unhealthy
session-warden doctor

# installed by install.sh: every 5 min, Telegram alert on failure (throttled 1/h)
*/5 * * * * ~/session-warden/bin/doctor.sh --alert
```

Doctor also guards the skills prompt budget on OpenClaw fleets: the runtime
renders every live skill's name and description into every prompt, capped at
`maxSkillsPromptChars` (default 18,000 chars) — past the cap it silently drops
skills. Doctor warns at 80% of the budget and fails above it, per agent
(`WARDEN_SKILLS_PROMPT_BUDGET` / `WARDEN_SKILLS_MAX_COUNT` to tune).

Set `WARDEN_HEARTBEAT_URL` (e.g. a [healthchecks.io](https://healthchecks.io)
check) and doctor pings it on every fully-healthy run. If the host dies or
doctor itself gets unwired, the pings stop and the external service alerts you
— covering the one failure no on-host check can report.

### Agent registry gate

The warden supervises the agents the runtime declares (OpenClaw's
`agents.list`), not every directory under its agents dir. This matters because
supervising an agent is what keeps it running: a rotation ends in a recovery
message that wakes it. Discovery by directory glob therefore made a retired
agent self-perpetuating — it kept its session files, so the warden kept
rotating and recovering it long after it was meant to be gone.

Retiring an agent is removing it from the registry. The warden then leaves it
alone, and `doctor.sh` fails if an undeclared agent is still running, so a
half-finished retirement is loud rather than silent.

| Variable | Default | Meaning |
| --- | --- | --- |
| `WARDEN_UNMANAGED_AGENTS` | `claude claude-code main` | Session directories the runtime owns for subagent spawns. Never supervised, never reported. |
| `WARDEN_STRAY_ACTIVE_MAX_AGE` | `86400` | How recently an undeclared agent must have run for doctor to call it a live leak rather than leftover files. |

A missing or unreadable runtime config means "no opinion": the warden scans
everything, as it did before. A config that fails to parse must never switch
supervision off for the whole fleet.

## Fleet board (contrib)

A static, public-safe status board for the fleet — live example: **[fleet.ani.computer](https://fleet.ani.computer)**.

Three collectors feed it, each usable on its own:

| Collector | Output | What it reads |
|---|---|---|
| `contrib/costs/costs.py` | `state/costs/costs.json` | token usage per agent, priced against `config/cost-rates.json` — what the month *would* have cost at API list rates vs. what the flat subscriptions actually cost |
| `contrib/timers/collect.py` | `state/timers/timers.json` | every recurring loop from systemd user timers and your crontab, with last/next run times |
| `contrib/fleet-live/collect.py` | `live.json` in `$FLEET_OUT` (default `/var/www/fleet`) | the two above plus live session state, rendered by the single-file `index.html` |

```bash
# preview locally: write live.json next to index.html and serve the directory
FLEET_OUT=contrib/fleet-live python3 contrib/fleet-live/collect.py
python3 -m http.server -d contrib/fleet-live 8000

# in production, copy index.html to your web root once and keep live.json fresh
*/2 * * * * /usr/bin/python3 $HOME/session-warden/contrib/fleet-live/collect.py >> /tmp/fleet-live.log 2>&1
```

`live.json` and `index.html` are static files — serve them from anything (Cloudflare Pages, S3, `python3 -m http.server`). There is no backend, and the page fetches nothing but `live.json`.

Everything the board shows is opt-in:

- **Agents** come from `config/fleet-roster.tsv` — set the `board` column to `0` to keep one off the public page.
- **Loops** come from `config/timers-labels.json` — only loops marked `"public": true` are published. session-warden's own loops are public by default; everything else, including anything it discovers in your crontab, stays internal until you name it.

Copy both `.example` files in `config/` to get started. The real files are gitignored, so your agent names, job names, and log paths never end up in a commit.

## OpenClaw patches (contrib)

The `contrib/openclaw-patches/` directory contains optional scripts that patch OpenClaw's compiled JavaScript to fix specific runtime issues (output limits, watchdog behavior, error messages). They're version-specific. Two helpers keep them durable:

- `ensure-patches.sh` — idempotent, never exits non-zero; wire as `ExecStartPre=-` on the gateway unit so patches re-apply on every restart.
- `update-openclaw.sh [version|--rollback]` — deliberate updates: snapshots the package, installs, re-applies patches, verifies every marker, and leaves the gateway restart to you.

See [contrib/openclaw-patches/README.md](../contrib/openclaw-patches/README.md).

## Tests

```bash
# run the full test suite
bash tests/run-tests.sh

# run a single test file
bash tests/run-tests.sh test-detect
# verbose output
bash tests/run-tests.sh -v
```

Tests use a sandboxed mock environment — no real gateway sessions, cron entries, or API calls are touched. The suite targets Linux (it relies on `flock` and GNU tooling); expect failures if you run it on macOS.

## Monitoring

```bash
# is the warden itself healthy?
session-warden doctor

# watch the log
tail -f ~/session-warden/state/scan.log

# check for recent rotations
grep "ROTATE complete" ~/session-warden/state/scan.log

# check for errors
grep "ERROR" ~/session-warden/state/scan.log
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| No rotations happening | Check cron: `crontab -l \| grep warden`. Check log for errors. |
| Telegram alerts not arriving | Run `notify_test`. Verify bot token and chat ID. |
| Agent still broken after rotation | Check session state: is the stale reference deleted? Check gateway restarted. |
| False-positive rotations | Raise thresholds in `thresholds.env`. |
| Summarization failing | Check `claude` CLI works: `claude -p --model claude-haiku-4-5-20251001 "test"` |
| Zombie detection too aggressive | Increase `stale_threshold` in `detect.sh` (default: 30 min). |

## Related issues

This tool addresses problems reported across the Claude Code agent-fleet ecosystem:

- Session token accumulation with no auto-rotation
- Large JSONL files crashing gateways
- Session continuity lost after forced resets
- Infinite error loops from stale session pointers

## License

MIT
