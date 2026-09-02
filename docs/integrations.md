# Integrations: running session-warden under your own runtime or interface

Picture-first setup is in the [README](../README.md). This page is the
runtime contract.

session-warden does two different jobs, with two different contracts:

1. **Runtime / lifeguard** — supervise long-running Claude Code sessions (scan, rotate, summarize, reap). Each *runtime* (OpenClaw, Hermes, …) needs explicit support. That is the rest of this page.
2. **Worker / dispatch** — pick and invoke any bash CLI (nested harness or direct model) for a single task. A *worker* is a JSON record, not a runtime adapter. See [routing.md](routing.md). `session-warden onboard` installs host skills so OpenClaw, Hermes, Claude Code, Codex, or Grok can call `route` / `run`.

These are not the same. Adding DeepSeek as a worker does **not** mean the lifeguard rotates DeepSeek sessions. There is still no Codex CLI session support.

The layer *above* the lifeguard — the runtime that owns sessions, and the interface you chat through — is swappable in principle, but each runtime needs explicit support. The rest of this page is the honest map for that job.

## The two ways to put a different interface in front

**1. Keep a supported runtime; swap the interface.** The easiest path. OpenClaw already speaks Telegram and Discord; anything that can talk to a supported runtime (a simpler bot UI, a web dashboard, your own wrapper) gets the warden's supervision for free, because the warden works at the runtime layer, not the chat layer. This is how a fleet driven entirely from Telegram works today.

**2. Bring your own runtime; use the building blocks.** If your bot manages Claude Code sessions itself (spawning `claude` with `--resume`, tracking session IDs in its own store), the gateway-free pieces below are directly reusable, and the rest of this page describes the contract you'd implement to get full rotation.

## What is gateway-free today

These parts need no runtime at all — just Claude Code's own on-disk artifacts:

| Piece | What it does | Needs |
|---|---|---|
| `lib/extract.sh` | Claude Code session JSONL → readable transcript (text + every tool action) | `jq`, a JSONL path |
| `lib/memory.sh` (generic halves) | Summary prompt/carry-over, fallback memory (INCOMPLETE-labeled on timeout), size-guarded compaction, change-gated writes | `claude` CLI |
| `lib/recovery.sh` | Wake-prompt builder; INCOMPLETE banner for failed / zombie / stall endings | — |
| `bin/snapshot.sh` | any `~/.claude/projects/**/*.jsonl` → summarized, linked GBrain pages | `claude`, `jq`, `gbrain` |
| `lib/burn-solo.sh` + `bin/burn-solo-sample.sh` | meter token burn of standalone Claude Code sessions | `jq` |
| `lib/gbrain.sh` | bounded knowledge-graph writes | `gbrain` CLI |
| `lib/notify.sh` (Telegram core) | throttled alerts and digests | `curl` |
| `lib/roster.sh`, `lib/portable.sh` | fleet roster reader; GNU/BSD portability helpers | — |
| `lib/harvest-work.py` | collapse a directory of Claude-Code-style JSONLs into a judge-ready work sample | `python3` |

## What full rotation requires from a runtime

The supervision core (scan → rotate → summarize → restart, plus the stall reaper and burn firewall) is currently implemented against OpenClaw's contracts. A runtime integration has to answer five questions:

1. **Where is session state?** The warden reads a per-agent `sessions.json` with `status`, `cliSessionIds`, `totalTokens`, `numTurns`, `compactionCount`, `updatedAt`. Detection thresholds, zombie checks, and the stall reaper's STUCK verdict are all computed from these fields (`lib/detect.sh`, `lib/reap.sh`, `lib/burn.sh`).
2. **Where are the transcripts?** A mapping from agent name → the Claude Code project directory holding its session JSONLs. For OpenClaw this is the hard-coded path formula in `lib/memory.sh` / `lib/agent-attribution.sh`.
3. **How do we restart it and deliver messages?** Rotation ends with a gateway restart and a recovery message that wakes the agent with its context (`openclaw gateway restart`, `openclaw agent --deliver` today).
4. **Where does memory get injected?** The load-bearing memory write is the workspace `MEMORY.md`/`CONTEXT.md` that the runtime injects into the agent's prompt at boot. A runtime that doesn't inject workspace memory needs an equivalent hook, or the carry-over never reaches the model.
5. **How do we kill safely?** The reaper and burn enforcement only ever kill a pid whose cmdline carries the session's `--session-id` *and* whose environment carries the runtime's agent marker (`OPENCLAW_MCP_AGENT_ID` today) — that double gate is what guarantees a human's own `claude` session is never touched. A new runtime needs its own unambiguous process marker.

There is no plugin API for these yet — the OpenClaw answers are inlined at the call sites, and the one runtime-dispatch seam in the tree is `handoff_detect_runtime` in `lib/handoff.sh` (a two-way OpenClaw/Hermes case). Adding a runtime today means extending these scripts, not dropping in an adapter file. If you attempt one, the Hermes support is the worked example to follow.

## The Hermes integration, as a template

Hermes shows what a *partial* second-runtime integration looks like — memory continuity without rotation:

- **Detection** — `handoff_detect_runtime` maps agent → runtime by home directory (`~/.openclaw/agents/<a>` vs `~/.hermes-<a>`).
- **Extraction** — `lib/extract-hermes.py` reads Hermes' SQLite `state.db` and emits the same transcript shape `lib/extract.sh` produces, so everything downstream (summarization, GBrain) is shared.
- **Memory writes** — `write_hermes_memory` in `lib/memory.sh` targets Hermes' conventions: `memories/HANDOFF.md`, a marker-wrapped block in `CONTEXT.md`, and a resume pointer in `memories/USER.md`.
- **Model switch** — `bin/model-switch.sh` edits `config.yaml` and restarts the `hermes-<agent>-gateway` systemd unit.
- **Learning loop** — the weekly scorecard drives Hermes agents directly (`HERMES_HOME=<home> hermes chat -Q -q`), and the dream cycle ingests `~/.hermes*` transcripts into GBrain.

That's the pattern: one extractor to the common transcript shape, one memory writer to the runtime's injection point, one restart/config recipe. Rotation, reaping, and burn metering for Hermes don't exist yet.

## Worker contract (dispatch, not rotation)

A worker is whatever you can run in bash. Catalog + detect + invoke live in
`config/workers.json`, `config/workers.d/`, and `lib/dispatch.py`. The host
skill calls `session-warden route` then `session-warden run`. That is enough
to send a task to Codex, Kimi, Grok, DeepSeek, or GLM **as a one-shot**. It
is not enough for the lifeguard to treat those CLIs as session runtimes.

| Piece | Runtime (this page) | Worker ([routing.md](routing.md)) |
|---|---|---|
| What you add | extractor, memory writer, restart, kill marker | a JSON record + a CLI on PATH |
| Session rotate / reap | yes, once the five questions below are answered | no |
| Who calls it | cron / `scan.sh` | a host skill or `session-warden run` |

## What does not exist

To keep this page trustworthy, the current non-features, explicitly:

- **No Codex CLI session support.** The warden does not read, rotate, summarize, or meter Codex sessions. Codex *can* be a dispatch worker (`session-warden run --worker codex`) when the `codex` CLI is on PATH. The `codex/` strings elsewhere in the tree are provider labels in rate-guard and board cosmetics. Memory still survives a runtime-level switch to an OpenAI model, because the workspace memory files are model-agnostic — but the sessions being supervised are Claude Code sessions.
- **No adapter/plugin interface.** Runtime support is compiled in, per the sections above. Worker support is the JSON catalog, not a plugin API.
- **No macOS supervision core.** `/proc`, systemd user timers, and the Linux path formula are assumed; macOS gets the solo burn sampler, the read-only CLI commands, and `route` / `run` / `onboard`.

If you build an integration for another runtime, the contract above plus the Hermes files are the full surface area — PRs welcome (see [CONTRIBUTING.md](../CONTRIBUTING.md)).
