# Onboard: use session-warden inside any harness

`install.sh` still requires OpenClaw — that path is the **fleet lifeguard**.
`session-warden onboard` is the **router + host skills** path. It works on a
machine that only has Claude Code or Codex.

Extra Anthropic quota is gone. Onboard exists so people can keep using
frontier tools without spending them on busywork.

## One command

```bash
session-warden onboard
```

It will:

1. Detect hosts (OpenClaw home, `~/.hermes-*`, `claude`, `codex`, `grok`)
2. Detect catalog workers on PATH (`session-warden workers`)
3. Write `config/routing.yaml` from the example if missing
4. Install a short `session-warden-route` skill into each detected host
5. Print a recap: what stays cheap, when frontier still fires, one command to try

```bash
session-warden onboard --dry-run          # print paths, write nothing
session-warden onboard --host claude-code # one host only
```

## Per-host install targets

| Host | Skill lands at |
|---|---|
| OpenClaw | `~/.openclaw/skills/session-warden-route/SKILL.md` |
| Hermes | `~/.hermes-<name>/skills/session-warden-route/SKILL.md` (each home) |
| Claude Code | `~/.claude/skills/session-warden-route/SKILL.md` |
| Codex | `~/.codex/skills/session-warden-route/SKILL.md`, or an `AGENTS.md` snippet if there is no skills dir |
| Grok | `~/.grok/skills/session-warden-route/SKILL.md`, or a copy-paste note |

Packs live in [`skills/`](../skills/). The skill tells the host: call
`session-warden route --json` before spending its own tokens; if the chosen
worker is not you, `session-warden run`.

## Try this

```bash
session-warden route --task "fix the typo in README" --json
session-warden run --task "fix the typo in README"
```

A typo/summarize/format ask should pick a cheap model when one is on PATH.
Architecture / security / “use frontier” stays on a harness.

Then edit `config/routing.yaml` to pin paths (for example `**/security/**` →
`claude-code`). See [routing.md](routing.md).

## What this does not do

- It does not rotate, summarize, or reap Codex / Kimi / Grok **sessions**.
- It does not drop the OpenClaw requirement from `install.sh`.
- It does not install vendor CLIs or API keys for you.
