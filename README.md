# session-warden

Auto-rotate bloated Claude Code sessions. Preserve agent memory across rotations so agents pick up where they left off.

## The problem

Claude Code sessions accumulate tokens, turns, and JSONL file size over time. Eventually they hit limits — token bloat, context overflow, compaction loops — and the session dies. If you're running Claude Code as a persistent agent (via OpenClaw, a custom wrapper, or manual `--resume` workflows), you're stuck with a dead session and no memory of what was happening.

For OpenClaw users specifically: when a session fails, OpenClaw keeps the dead session ID pinned and resumes it on every new message, creating an infinite error loop that looks like an Anthropic rate limit. It's not. It's a stale pointer.

## What the warden does

Every 2 minutes, a cron job scans Claude Code session state. When it finds a session that's failed or exceeds configurable thresholds (tokens, turns, file size, compaction count), it runs a rotation:

1. **Backup** session state (safety net)
2. **Archive** the session JSONL (never deleted — it's the memory source)
3. **Delete** the stale session reference
4. **Restart** the agent gateway (OpenClaw) or signal for manual restart

The agent comes back online in under a second.

## Session memory (the hard part)

Rotation without memory means the agent starts from scratch. The warden solves this in three layers:

**Layer 1: Post-rotation summarization.** After the fast rotation, the warden extracts the full conversation — not just text messages, but every tool action (files edited, commands run, branches created, PRs opened) — from the archived JSONL. A fast model (Haiku) summarizes this into a structured memory entry written to Claude Code's native memory system (`~/.claude/projects/.../memory/`). The agent reads this automatically on its next session start.

**Layer 2: Per-channel memory.** Each channel/context gets its own memory file. If an agent is active in 5 channels, each channel's context stays separate. On the next rotation, the file is replaced with the latest context — no unbounded growth.

**Layer 3: Agent-side discipline.** Agents are instructed via `CLAUDE.md` to proactively write important context to memory *during* the session, not just at rotation time. If the session dies unexpectedly, the critical context is already persisted.

Session boundaries become invisible.

## Architecture

```
session-warden/
├── bin/
│   ├── scan.sh              # cron entry point (every 2 min)
│   ├── rotate.sh            # fast-path: backup, archive, delete, restart
│   ├── summarize.sh         # async: extract, summarize, write memory
│   ├── cleanup-archives.sh  # delete old archived JSONL files (cron daily)
│   ├── mcp-supervisor.sh    # keep MCP servers alive across rotations
│   └── patch-output-limits.sh  # bump OpenClaw CLI output buffer limits
├── lib/
│   ├── detect.sh            # threshold + status checks
│   ├── extract.sh           # JSONL → conversation transcript (text + tools)
│   ├── memory.sh            # write to Claude Code native memory
│   └── notify.sh            # Telegram alerts
├── scripts/
│   └── patch-error-humanizer.sh  # humanize OpenClaw error messages via Gemini
├── hooks/
│   └── post-summary/        # extensible: drop .sh scripts here
│       └── 01-gbrain.sh     # example: ingest to GBrain
├── config/
│   ├── thresholds.env.example
│   └── thresholds.env       # your config (gitignored)
├── install.sh
└── .gitignore
```

## Install

```bash
git clone https://github.com/Ani-HQ/session-warden.git ~/session-warden
cd ~/session-warden

# Create config from example
cp config/thresholds.env.example config/thresholds.env
# Edit config — set paths, thresholds, optional Telegram credentials
vim config/thresholds.env

# Install cron job
bash install.sh
```

### Dependencies

- `jq` — JSON processing
- `claude` CLI — session summarization (uses Haiku by default)
- `curl` — Telegram alerts (optional)

### Verify

```bash
# Check cron is installed
crontab -l | grep session-warden

# Dry run — see what would be rotated without doing it
WARDEN_DRY_RUN=1 bash ~/session-warden/bin/scan.sh
cat ~/session-warden/state/scan.log

# Test Telegram alerts
source ~/session-warden/config/thresholds.env
source ~/session-warden/lib/notify.sh
notify_test
```

## Configuration

All config lives in `config/thresholds.env`. Key settings:

| Setting | Default | Description |
|---|---|---|
| `WARDEN_MAX_TOKENS` | 2000000 | Rotate when session exceeds this token count |
| `WARDEN_MAX_TURNS` | 500 | Rotate when session exceeds this many turns |
| `WARDEN_MAX_BYTES` | 4194304 | Rotate when JSONL exceeds 4MB |
| `WARDEN_MAX_COMPACTIONS` | 10 | Rotate after this many compaction cycles |
| `WARDEN_MAX_CONSECUTIVE_FAILURES` | 3 | Back off after this many consecutive failures |
| `WARDEN_COOLDOWN_SECONDS` | 600 | Skip re-rotating same session within this window |
| `WARDEN_GATEWAY_RESTART_COOLDOWN_SECONDS` | 300 | Minimum seconds between gateway restarts |
| `WARDEN_SUMMARY_MODEL` | claude-haiku-4-5-20251001 | Model for summarization |
| `WARDEN_SCAN_AGENTS` | (blank) | Space-separated agent allowlist. Empty = scan all. |
| `WARDEN_ARCHIVE_RETENTION_DAYS` | 7 | Delete archived JSONL files older than this |
| `WARDEN_DRY_RUN` | 0 | Set to 1 to log without rotating |
| `WARDEN_TELEGRAM_BOT_TOKEN` | (blank) | Telegram bot token for alerts |
| `WARDEN_TELEGRAM_CHAT_ID` | (blank) | Telegram chat ID for alerts |

All `WARDEN_*` variables can be overridden via environment (env takes precedence over config file).

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

Scripts run in alphabetical order. Failures are logged but don't block other hooks.

### Example hooks

- `01-gbrain.sh` — ingest into [GBrain](https://github.com/garrytan/gbrain) for cross-agent memory access
- Write your own for Notion, Slack, Postgres, or any other backend

## Extra tools

### Archive cleanup

Archived JSONL files accumulate on disk after rotations. Run the cleanup script daily via cron to delete files older than `WARDEN_ARCHIVE_RETENTION_DAYS` (default: 7 days).

```bash
# Add to crontab
30 3 * * * /path/to/session-warden/bin/cleanup-archives.sh
```

### MCP supervisor

Heavy MCP servers (like Notion) restart every time the CLI session rotates, adding 10-15s of cold-start latency. The supervisor keeps them running as persistent HTTP processes that survive rotations.

```bash
# Start persistent MCP servers
bash ~/session-warden/bin/mcp-supervisor.sh start

# Check status
bash ~/session-warden/bin/mcp-supervisor.sh status

# Ensure all servers are running (idempotent, good for cron)
bash ~/session-warden/bin/mcp-supervisor.sh ensure
```

Notion server ports are defined in the script (default: 4001-4003). After starting, run `sync-agent-mcps.sh` to update agent MCP configs to use the persistent HTTP endpoints instead of stdio.

### Output limits patch

OpenClaw has hardcoded limits on CLI stdout buffer size that kill agent sessions mid-turn, especially when processing images. This script bumps the limits in the compiled JS.

```bash
bash ~/session-warden/bin/patch-output-limits.sh
```

Must be re-run after every `npm update -g openclaw`.

### Error humanizer

Patches the OpenClaw gateway to rewrite generic error messages ("Something went wrong") into human, self-deprecating messages using Gemini Flash. Reads the Google API key from `openclaw.json` at patch time.

```bash
bash ~/session-warden/scripts/patch-error-humanizer.sh
```

Idempotent (checks for a marker before patching). Must be re-run after OpenClaw updates.

## Monitoring

```bash
# Watch the log
tail -f ~/session-warden/state/scan.log

# Check for recent rotations
grep "ROTATE complete" ~/session-warden/state/scan.log

# Check for errors
grep "ERROR" ~/session-warden/state/scan.log
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| No rotations happening | Check cron: `crontab -l \| grep warden`. Check log for errors. |
| Telegram alerts not arriving | Run `notify_test`. Verify bot token and chat ID. Bot must have messaged the user before. |
| Agent still broken after rotation | Check session state — is the stale reference actually deleted? Check gateway restarted. |
| False-positive rotations | Raise thresholds in `thresholds.env`. |
| Summarization failing | Check `claude` CLI works: `claude -p --model claude-haiku-4-5-20251001 "test"` |

## Related issues

This tool addresses problems reported across the Claude Code and OpenClaw ecosystems:

- [openclaw#64463](https://github.com/openclaw/openclaw/issues/64463) — `session.maxTokensPerSession` (the warden enforces this externally)
- [openclaw#71555](https://github.com/openclaw/openclaw/issues/71555) — large session JSONL crashes gateway
- [openclaw#70853](https://github.com/openclaw/openclaw/issues/70853) — session continuity lost after reset

## License

MIT
