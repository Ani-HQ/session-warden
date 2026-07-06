# session-warden

Auto-rotate bloated Claude Code sessions. Preserve agent memory across rotations so agents pick up where they left off.

## Who this is for

Anyone running Claude Code as a persistent agent — via [OpenClaw](https://github.com/openclaw/openclaw), a custom wrapper, or manual `--resume` workflows. If your sessions accumulate tokens until they die, and you lose context every time, this fixes that.

## The problem

Claude Code sessions accumulate tokens, turns, and JSONL file size over time. Eventually they hit limits — token bloat, context overflow, compaction loops — and the session dies. You're left with a dead session and no memory of what was happening.

For OpenClaw users specifically: when a session fails, OpenClaw keeps the dead session ID pinned and resumes it on every new message, creating an infinite error loop. It's not a rate limit. It's a stale pointer.

## How it works

A cron job runs every 30 seconds. When it finds a session that's failed or exceeds configurable thresholds (tokens, turns, file size, compaction count), it runs a 4-step rotation:

1. **Detect** — scan session state for bloat, failures, or zombies (dead CLI process with stale JSONL)
2. **Rotate** — backup state, archive the JSONL (never deleted), clean up the stale session reference
3. **Summarize** — extract the full conversation (text + tool actions), summarize with a fast model (Haiku), write to Claude Code's native memory system
4. **Restart** — restart the agent gateway so agents boot with full context already loaded

The agent comes back online in under a second, knowing what it was doing.

## Session memory

Rotation without memory means the agent starts from scratch. The warden solves this in three layers:

**Layer 1: Post-rotation summarization.** The warden extracts the full conversation — not just text messages, but every tool action (files edited, commands run, branches created) — from the archived JSONL. A fast model (Haiku) summarizes this into a structured memory entry written to Claude Code's native memory system (`~/.claude/projects/.../memory/`). The agent reads this automatically on its next session start.

**Layer 2: Per-channel memory.** Each channel/context gets its own memory file. If an agent is active in 5 channels, each channel's context stays separate. On the next rotation, the file is replaced — no unbounded growth.

**Layer 3: Agent-side discipline.** Agents are instructed via `CLAUDE.md` to proactively write important context to memory during the session. If the session dies unexpectedly, the critical context is already persisted.

Session boundaries become invisible.

## Snapshot (standalone Claude Code sessions)

Rotation and memory cover OpenClaw agent sessions. But you also run plain Claude Code sessions yourself — in repos, in your home dir, anywhere. The **snapshot module** (`bin/snapshot.sh`) captures those into GBrain so they become permanent, searchable, linked memory too.

Every `WARDEN_SNAPSHOT_INTERVAL_MINUTES` (default 30) it:

1. Scans `~/.claude/projects/**/*.jsonl` modified in the last `WARDEN_SNAPSHOT_WINDOW_MINUTES` (default 120)
2. **Skips OpenClaw agent sessions** (path matches `*-openclaw-agents-*`) — those are already handled by context-sync (live) and rotation, so there's no double-ingestion
3. Extracts the transcript (`lib/extract.sh`), summarizes it with Haiku, and writes a typed GBrain page at `sessions/<date>/<agent>-<shortid>` (tags `[session, snapshot, <agent>]`), linked `performed_by` to its agent and with `mentions` edges to any entities the summary names
4. Tracks `{last_mtime, last_turn_count}` per session in `state/snapshot/state.json`, re-summarizing only when the file changed **and** at least `WARDEN_SNAPSHOT_MIN_TURNS` (default 4) new turns accrued — so most runs are cheap no-ops and Haiku only fires on real activity

The agent each session is attributed to is resolved from its working directory (`lib/agent-attribution.sh`): OpenClaw agents by their `~/.openclaw/agents/<name>` directory, your home dir as `home`, everything else `unknown`. To attribute your own repos or project paths to named agents, add glob rules to `config/agent-paths.env` (copy `config/agent-paths.env.example`); without it, non-OpenClaw paths just resolve to `unknown`.

**GBrain is a hard dependency for this module** — there is no graceful degradation. If the `gbrain` CLI isn't installed, snapshot exits with an error. GBrain is the canonical cross-session knowledge graph; snapshot writes there only (Claude Code's own auto-memory already handles local per-project persistence).

Config lives in `config/thresholds.env` (`WARDEN_SNAPSHOT_*`). Install adds a cron entry; `deploy/snapshot.{service,timer}` are the systemd alternatives.

## Reflector (nightly lesson distillation)

Session memory answers "what was I doing?"; nothing answers "what should I have learned?". The **reflector** (`bin/reflect.sh`) closes that loop nightly, ACE-style (append-only context engineering — new rules are only ever added, never rewritten over existing ones).

For each agent in `WARDEN_REFLECT_AGENTS` it:

1. **Gathers** the last 24h of material: session JSONLs under `~/.openclaw/agents/<agent>/sessions/` (extracted with `lib/extract.sh`), the warden's rotation summaries, and the agent's own daily notes in `memory/`. Agents with no material are skipped (logged as SKIP).
2. **Distills** 0-5 lesson bullets with a stronger model (`WARDEN_REFLECT_MODEL`, default Sonnet). The prompt demands general rules that would change future behavior — not restatements of what happened — and feeds in the agent's current `## General rules` + `## Lessons learned` so it never duplicates an existing rule. Each bullet is tagged `[YYYY-MM-DD, source: <agent> sessions]`. If nothing clears the bar, the model outputs `NO_LESSONS`.
3. **Verifies** with a second, cheaper model (`WARDEN_REFLECT_VERIFY_MODEL`, default Haiku) acting as a skeptic: each bullet is marked KEEP or REJECT — rejected if it is not grounded in the source material, is too specific to today, contradicts an existing rule, or derives from untrusted external content. Only KEEPs survive. If the verifier itself fails, bullets are staged with an UNVERIFIED warning and auto-apply is blocked.
4. **Stages** survivors in `~/.openclaw/agents/<agent>/memory/pending-lessons-YYYY-MM-DD.md` for human review. Nothing touches MEMORY.md unless `WARDEN_REFLECT_AUTO_APPLY=1` (default 0), in which case verified bullets are appended directly under `## Lessons learned` (below the warden block).
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
| `WARDEN_REFLECT_AGENTS` | `ping bloop dash isaac zara kai nova remy` | agents to reflect on (ping/bloop/dash/isaac = work team, zara/kai/nova/remy = personal) |
| `WARDEN_REFLECT_MODEL` | `claude-sonnet-4-6` | distillation model |
| `WARDEN_REFLECT_VERIFY_MODEL` | `claude-haiku-4-5-20251001` | skeptic/verifier model |
| `WARDEN_REFLECT_AUTO_APPLY` | `0` | `1` = skip staging, append verified lessons straight to MEMORY.md |
| `WARDEN_REFLECT_NOTIFY` | `1` | one Telegram digest per run |
| `WARDEN_REFLECT_WINDOW_MINUTES` | `1440` | lookback window for material |

## Skill harvester (weekly skill mining)

The reflector distills one-line *lessons*; nothing captures repeated *workflows*. The **skill harvester** (`bin/harvest-skills.sh`) closes that loop weekly: if an agent did the same multi-step thing twice this week, that procedure should become a skill, not stay tribal knowledge in session summaries.

For each agent in `WARDEN_HARVEST_AGENTS` it:

1. **Gathers** the week's material (`WARDEN_HARVEST_WINDOW_DAYS`, default 7): the warden's rotation summaries, the agent's own daily notes in `memory/`, and lessons already applied in `memory/applied/`. Agents with no material are skipped (logged as SKIP).
2. **Lists existing skills** — the agent's own (`~/.openclaw/agents/<agent>/skills/`), the shared fleet dir (`~/.openclaw/skills/`), and anything already staged — and feeds the names to the model so it never proposes a duplicate (a belt-and-braces name check enforces this even if the model ignores the instruction).
3. **Mines** with one strong-model call per agent (`WARDEN_HARVEST_MODEL`, default Sonnet): identify workflows performed **2+ times** this week that no existing skill covers, and emit a complete `SKILL.md` draft for each — YAML frontmatter (`name`, `description` with trigger conditions) plus a body with steps, known failure modes, and anti-patterns, all grounded in the week's material. At most **2 proposals per agent per run**. If nothing clears the bar, the model outputs `NO_SKILLS`.
4. **Stages** each draft at `~/.openclaw/skills-pending/<agent>/<skill-name>/SKILL.md` — it **never writes into a live skills dir**.
5. **Notifies** once per run via Telegram (`WARDEN_HARVEST_NOTIFY=1`): per-agent proposal counts and names, where the drafts live, and the promote command.

The **staged-approval flow**: read a draft, edit it if needed, then promote it with

```bash
bin/promote-skill.sh <agent> <skill-name>            # into the agent's own skills dir
bin/promote-skill.sh <agent> <skill-name> --shared   # into ~/.openclaw/skills/ for the fleet
```

`promote-skill.sh` moves the pending dir into the live skills dir (refusing to overwrite an existing skill) and records the skill in GBrain as `skills/<skill-name>` with provenance frontmatter per the GBrain conventions (`scope:` work/personal by team, `source: skill-harvester`, `trust: inferred`).

Flags on `harvest-skills.sh`: `--agent <name>` harvests a single agent; `--dry-run` prints the proposed drafts without writing or notifying. Logs to `state/harvest.log`; a lock file prevents overlapping runs; LLM failures are logged and skipped, never fatal.

Runs weekly, Sunday 05:00 UTC, via `deploy/harvest.{service,timer}` — after that night's reflector (04:10) so the week's lessons are already staged. Config (`config/thresholds.env`):

| Variable | Default | Meaning |
|---|---|---|
| `WARDEN_HARVEST_AGENTS` | `ping bloop dash isaac zara kai nova remy` | agents to harvest (ping/bloop/dash/isaac = work team, zara/kai/nova/remy = personal) |
| `WARDEN_HARVEST_WINDOW_DAYS` | `7` | lookback window for material |
| `WARDEN_HARVEST_MODEL` | `claude-sonnet-4-6` | skill-mining model |
| `WARDEN_HARVEST_NOTIFY` | `1` | one Telegram digest per run |

## Stall reaper (silent-hang backstop)

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

Process identity is safety-gated: a pid is only ever killed if its cmdline carries the session's `--session-id` **and** its `/proc/<pid>/environ` has `OPENCLAW_MCP_AGENT_ID` for that agent — so a human's own `claude` session is never touched. Honors `WARDEN_DRY_RUN=1`.

**Contract self-check.** The reaper reads openclaw's on-disk `sessions.json` schema. If a future openclaw upgrade reshapes that file, detection would silently return nothing and the reaper would no-op — quietly reintroducing the silent hang. So each run validates the schema and, on drift (entries present but none expose `status` / `cliSessionIds` / `updatedAt`, or the file won't parse), logs loud and fires a Telegram alert (throttled hourly) instead of failing silent. This is the one piece that keeps it honest across openclaw versions: the disk + CLI contracts are far more stable than the compiled-JS patch's anchors, but a major version bump can still move them — and when it does, you get pinged, not silence.

Runs on its own cron tick every 30s. Config: `WARDEN_REAP_ENABLED`, `WARDEN_STALL_HARD_CAP_SECONDS`, `WARDEN_STALL_KILL_GRACE_SECONDS`.

## Channel/plugin parity (silent-channel backstop)

Some OpenClaw upgrades unbundle a channel plugin from core. The gateway then boots "healthy", starts the channels whose plugins survived, and **silently ignores** an enabled channel that has no provider — no error, no log line, no health alert. The channel just goes dark. (Real incident, 2026-06-11: a release unbundled Discord; every Discord agent was deaf for ~14 hours before anyone noticed.)

`contrib/openclaw-patches/channel-parity.sh` enforces the invariant: **every channel enabled in `openclaw.json` must have an installed, enabled plugin that provides it.**

- `channel-parity.sh check` — report parity; exit 0 in-parity, 1 on mismatch.
- `channel-parity.sh heal` — for each missing channel, install the **official** `@openclaw/<id>` plugin (that scope only — never community code), schedule one gateway restart, and alert via the warden's Telegram. Loop-guarded: at most one heal attempt per channel per `CHANNEL_PARITY_COOLDOWN_SECONDS` (default 6h).

It's wired at three layers so a gap can't slip through any single one:

- **boot** — `deploy/20-channel-parity.conf` adds an `ExecStartPost` that runs `heal` after every gateway start (leading `-` + backgrounded, so it never blocks or fails startup).
- **cron** — `doctor.sh` runs `check` on its existing 5-min cadence and reports an unhealthy verdict on mismatch.
- **upgrade** — the update flow runs `check` before blessing a new OpenClaw version.

Missing prerequisites (no `jq`, no config) bail soft, never breaking gateway startup. Config: `OPENCLAW_CONFIG`, `OPENCLAW_BIN`, `CHANNEL_PARITY_COOLDOWN_SECONDS`, `CHANNEL_PARITY_STATE_DIR`.

## Quick start

```bash
git clone https://github.com/Ani-HQ/session-warden.git ~/session-warden
cd ~/session-warden
bash install.sh
```

The installer will:
- Check dependencies (`jq`, `claude` CLI, `curl`; `gbrain` is required for the snapshot module and GBrain memory)
- Detect your OpenClaw installation path
- Create a config file from the example (edit it to tune thresholds)
- Install cron entries (rotation scan every 30 seconds; snapshot every 30 minutes)

### CLI

After install, use the `session-warden` CLI:

```bash
# show session health across all agents
~/session-warden/bin/session-warden status

# dry run — see what would be rotated
~/session-warden/bin/session-warden scan --dry-run

# manually rotate a specific session
~/session-warden/bin/session-warden rotate my-agent discord-general

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

## Dependencies

- `jq` — JSON processing
- `claude` CLI (Anthropic) — session summarization via Haiku
- `curl` — Telegram alerts (optional)
- `python3` — crash buffer detection (optional, for Discord crash recovery)
- OpenClaw — the warden manages sessions stored in `~/.openclaw/agents/`

## Configuration

All config lives in `config/thresholds.env`. Key settings:

| Setting | Default | Description |
|---|---|---|
| `WARDEN_MAX_TOKENS` | 2,000,000 | Rotate when session exceeds this token count |
| `WARDEN_MAX_TURNS` | 500 | Rotate when session exceeds this many turns |
| `WARDEN_MAX_BYTES` | 4,194,304 | Rotate when JSONL exceeds 4 MB |
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

All `WARDEN_*` variables can be overridden via environment (env takes precedence over the config file).

## Architecture

```
session-warden/
├── bin/
│   ├── session-warden       # CLI entrypoint (scan, status, rotate, install, logs)
│   ├── scan.sh              # cron entry point (every 30s)
│   ├── reap-stalls.sh       # independent stall backstop (disk + /proc only)
│   ├── reap-worktrees.sh    # GC for ephemeral agent worktrees (cron, 15 min)
│   ├── wt                   # agent worktree helper (symlinked to ~/.local/bin/wt)
│   ├── rotate.sh            # fast-path: backup, archive, cleanup
│   ├── summarize.sh         # extract transcript, summarize, write memory
│   ├── status.sh            # show session health across all agents
│   ├── context-sync.sh      # periodic context capture for active sessions
│   ├── cleanup-archives.sh  # delete old archived JSONL (cron daily)
│   └── mcp-supervisor.sh    # keep MCP servers alive across rotations
├── lib/
│   ├── detect.sh            # threshold + zombie detection
│   ├── extract.sh           # JSONL → conversation transcript (text + tools)
│   ├── memory.sh            # summarize + write to Claude Code native memory
│   ├── notify.sh            # Telegram alerts
│   ├── channel-history.sh   # fetch recent Discord/Telegram messages
│   ├── detect-unprocessed.py  # identify unprocessed messages after crash
│   └── write-crash-buffer.py  # write crash buffer JSON
├── hooks/
│   └── post-summary/       # extensible: drop .sh scripts here
│       └── 01-gbrain.sh    # ingest memory into GBrain
├── contrib/
│   └── openclaw-patches/   # optional OpenClaw JS patches (version-specific)
├── tests/                  # full test suite
├── config/
│   ├── thresholds.env.example
│   └── thresholds.env      # your config (gitignored)
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
       │    ├─ memory.sh → Haiku summarization → Claude Code memory
       │    └─ hooks/post-summary/*.sh (background)
       ├─ openclaw gateway restart
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

Keeps heavy MCP servers (like Notion) running as persistent HTTP processes that survive CLI session rotations. Define your servers in `config/mcp-servers.env` or edit the defaults in the script.

```bash
bash ~/session-warden/bin/mcp-supervisor.sh start
bash ~/session-warden/bin/mcp-supervisor.sh status
bash ~/session-warden/bin/mcp-supervisor.sh ensure  # idempotent, good for cron
```

### Archive cleanup

Bounded growth for everything the warden writes: archived JSONLs, `scan.log`
(size-based rotation, `WARDEN_LOG_MAX_BYTES`), stale recovery/summary queue
items, and expired cooldown markers. Run daily via cron.

```bash
# add to crontab
30 3 * * * ~/session-warden/bin/cleanup-archives.sh
```

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

Set `WARDEN_HEARTBEAT_URL` (e.g. a [healthchecks.io](https://healthchecks.io)
check) and doctor pings it on every fully-healthy run. If the host dies or
doctor itself gets unwired, the pings stop and the external service alerts you
— covering the one failure no on-host check can report.

## OpenClaw patches (contrib)

The `contrib/openclaw-patches/` directory contains optional scripts that patch OpenClaw's compiled JavaScript to fix specific runtime issues (output limits, watchdog behavior, error messages). They're version-specific. Two helpers keep them durable:

- `ensure-patches.sh` — idempotent, never exits non-zero; wire as `ExecStartPre=-` on the gateway unit so patches re-apply on every restart.
- `update-openclaw.sh [version|--rollback]` — deliberate updates: snapshots the package, installs, re-applies patches, verifies every marker, and leaves the gateway restart to you.

See [contrib/openclaw-patches/README.md](contrib/openclaw-patches/README.md).

## Tests

```bash
# run the full test suite
bash tests/run-tests.sh

# run a single test file
bash tests/run-tests.sh test-detect

# verbose output
bash tests/run-tests.sh -v
```

Tests use a sandboxed mock environment — no real OpenClaw sessions, cron entries, or API calls are touched.

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

This tool addresses problems reported across the Claude Code and OpenClaw ecosystems:

- Session token accumulation with no auto-rotation
- Large JSONL files crashing the gateway
- Session continuity lost after forced resets
- Infinite error loops from stale session pointers

## License

MIT
