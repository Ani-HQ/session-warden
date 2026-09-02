<p align="center">
  <img src="docs/assets/logo.svg" width="120" height="120" alt="session-warden — a life ring with a three-way route">
</p>

<h1 align="center">session-warden</h1>

<p align="center">
  <strong>You talk. Warden picks who runs it. Cheap first.</strong>
</p>

<p align="center">
  <a href="https://github.com/Ani-HQ/session-warden/actions/workflows/ci.yml"><img src="https://github.com/Ani-HQ/session-warden/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-0B3D3A.svg" alt="MIT"></a>
  <img src="https://img.shields.io/badge/if_it_runs_in_bash-it_can_be_orchestrated-E07A5F.svg" alt="If it runs in bash, it can be orchestrated">
</p>

<p align="center"><img src="docs/assets/hosts.svg" width="560" alt="Works inside OpenClaw, Hermes, Claude Code, Codex, Grok"></p>
<p align="center"><img src="docs/assets/workers.svg" width="560" alt="Routes to Claude, Codex, Kimi, Grok, DeepSeek, GLM"></p>

<p align="center"><img src="docs/assets/stack.svg" width="720" alt="You talk to a host. The host asks session-warden. Warden picks a worker. The worker runs bash."></p>

Anthropic extra quota is gone. Keep frontier models for hard work. Send typos, lists, and status checks to a cheap CLI.

If it runs in bash, it can be a worker.

## Setup

<p align="center"><img src="docs/assets/setup.svg" width="720" alt="Three setup steps: clone, onboard, then route or run."></p>

<p align="center"><img src="docs/assets/needs.svg" width="720" alt="You need git, python3, jq, curl, and one worker CLI on PATH."></p>

```bash
git clone https://github.com/Ani-HQ/session-warden.git ~/session-warden
cd ~/session-warden

./bin/session-warden onboard --dry-run   # peek first
./bin/session-warden onboard             # write rules + host skills

./bin/session-warden workers             # what is actually on PATH
./bin/session-warden route --task "fix the typo in README" --json
```

That is the whole install for the router. No OpenClaw. No cron. No config file unless you want one.

A typo / summarize / format ask should pick a **cheap** worker when one is installed. Architecture / security / “use frontier” stays on a harness.

```bash
# do the work (route, then invoke; one fallback if the first CLI fails)
./bin/session-warden run --task "fix the typo in README"
```

Add `~/session-warden/bin` to your PATH if you want the short command.

Stuck? [docs/onboard.md](docs/onboard.md) is the walkthrough.

## Did it work?

`route --json` should look like this for a typo when a cheap CLI is on PATH:

```json
{
  "worker": "deepseek-chat",
  "reason": "credits-first",
  "complexity": "low"
}
```

If every worker is missing, `workers` prints an empty list. Install any one of `claude`, `codex`, `kimi`, `grok`, `deepseek`, or `glm`, then try again.

## Where credits go

<p align="center"><img src="docs/assets/credits.svg" width="720" alt="Most work is busywork. Spend cheap credits there. Keep frontier for the small slice that is actually hard."></p>

```mermaid
pie title Typical mix on a busy agent machine
  "busywork → cheap CLI" : 80
  "build → mid-tier" : 15
  "hard → frontier" : 5
```

Not a live meter. The point: pay pennies for lists. Keep Claude for hard.

## How it picks

<p align="center"><img src="docs/assets/route.svg" width="720" alt="Routing: your rules first, then cheap workers for busywork, mid-tier for builds, frontier only for hard or risky work."></p>

```mermaid
flowchart TD
  A[your prompt] --> B{your rules<br/>routing.yaml}
  B -->|match| C[that worker]
  B -->|no match| D{credits-first}
  D -->|typo / list / status| E[cheapest CLI]
  D -->|code / tests / PR| F[mid-tier CLI]
  D -->|prod / delete / security| G[frontier]
  D -->|worker is down| H[skip it · try next]
```

Your file wins. Heuristics are a keyword check — not an extra LLM call.

```bash
cp config/routing.yaml.example config/routing.yaml
# then pin e.g. **/security/** → claude-code
./bin/session-warden route --task "audit auth" --path src/security/auth.go --json
```

Rule language: [docs/routing.md](docs/routing.md).

## Two ways in

<p align="center"><img src="docs/assets/two-paths.svg" width="720" alt="Two ways in: talk to your host, or type session-warden yourself."></p>

| I have… | Do this | What you get |
|---|---|---|
| Claude Code, Codex, Grok, or Hermes | `session-warden onboard` | Router + a short skill inside that host |
| Just a terminal | `session-warden route` / `run` | Same router. No host required |
| An [OpenClaw](https://github.com/openclaw/openclaw) fleet | `onboard`, then `bash install.sh` (twice) | Router for every ask · lifeguard for long Claude sessions |

`install.sh` exits without OpenClaw. That is on purpose.

## Optional: keep a Claude session alive

<p align="center"><img src="docs/assets/lifeguard.svg" width="720" alt="Optional OpenClaw lifeguard: detect a bloated Claude session, rotate it, summarize into memory, restart."></p>

This half is Claude Code sessions only. It does **not** rotate Codex / Kimi / Grok sessions.

```bash
bash install.sh
# review config/thresholds.env, then run install.sh again
```

Full story: [docs/manual.md](docs/manual.md).

## Next

| I want to… | Go here |
|---|---|
| Understand a host skill | [docs/onboard.md](docs/onboard.md) |
| Write a routing rule or add a CLI | [docs/routing.md](docs/routing.md) |
| Plug in another runtime | [docs/integrations.md](docs/integrations.md) |
| Edit the drawings | [docs/assets/excalidraw/](docs/assets/excalidraw/) |
| Run rotation, memory, burn, doctor… | [docs/manual.md](docs/manual.md) |

```bash
bash tests/run-tests.sh
```

## License

MIT
