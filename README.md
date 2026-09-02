<p align="center">
  <img src="docs/assets/logo.svg" width="120" height="120" alt="session-warden — a life ring with a three-way route">
</p>

<h1 align="center">session-warden</h1>

<p align="center"><strong>You talk. Warden picks who runs it. Cheap first.</strong></p>

<p align="center">
  <a href="https://github.com/Ani-HQ/session-warden/actions/workflows/ci.yml"><img src="https://github.com/Ani-HQ/session-warden/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-0B3D3A.svg" alt="MIT"></a>
</p>

<p align="center"><img src="docs/assets/hosts.svg" width="560" alt="Works inside OpenClaw, Hermes, Claude Code, Codex, Grok"></p>
<p align="center"><img src="docs/assets/workers.svg" width="560" alt="Routes to Claude, Codex, Kimi, Grok, DeepSeek, GLM"></p>

<p align="center"><img src="docs/assets/diagram-stack.jpg" width="720" alt="You talk to a host. The host asks session-warden. Warden picks a cheap or frontier worker."></p>

If it runs in bash, it can be a worker.

## Setup

<p align="center"><img src="docs/assets/diagram-setup.jpg" width="720" alt="Setup in 3 steps: clone, onboard, then route or run."></p>

<p align="center"><img src="docs/assets/needs.svg" width="720" alt="You need git, python3, jq, curl, and one worker CLI on PATH."></p>

```bash
git clone https://github.com/Ani-HQ/session-warden.git ~/session-warden
cd ~/session-warden
./bin/session-warden onboard
./bin/session-warden route --task "fix the typo in README" --json
```

That is the whole install. No OpenClaw. No cron.

A typo should pick a **cheap** worker when one is on PATH. Then do the work:

```bash
./bin/session-warden run --task "fix the typo in README"
```

More detail: [docs/onboard.md](docs/onboard.md).

## Where credits go

<p align="center"><img src="docs/assets/credits.svg" width="720" alt="80 percent busywork on a cheap CLI, 15 percent build on mid-tier, 5 percent hard on frontier."></p>

Pay pennies for lists. Keep Claude for hard.

## How it picks

<p align="center"><img src="docs/assets/diagram-route.jpg" width="720" alt="Your prompt, then your rules, then cheap-first: busywork to a cheap CLI, build to mid-tier, hard work to frontier."></p>

Your `routing.yaml` wins. Otherwise cheapest capable worker. Pin a rule:

```bash
cp config/routing.yaml.example config/routing.yaml
./bin/session-warden route --task "audit auth" --path src/security/auth.go --json
```

[docs/routing.md](docs/routing.md)

## Two ways in

<p align="center"><img src="docs/assets/diagram-paths.jpg" width="720" alt="Talk to a host, or type session-warden route and run yourself."></p>

`onboard` drops a skill into OpenClaw / Hermes / Claude Code / Codex / Grok so the host calls warden for you. Or skip the host and type the commands.

## Optional: keep a Claude session alive

<p align="center"><img src="docs/assets/diagram-lifeguard.jpg" width="720" alt="Optional lifeguard: detect, rotate, remember, restart. Claude Code and OpenClaw only."></p>

```bash
bash install.sh          # review config/thresholds.env
bash install.sh          # second run wires cron
```

Claude Code sessions only. Full story: [docs/manual.md](docs/manual.md).

## Next

[onboard](docs/onboard.md) · [routing](docs/routing.md) · [integrations](docs/integrations.md) · [drawings](docs/assets/excalidraw/) · [operator manual](docs/manual.md)

```bash
bash tests/run-tests.sh
```

## License

MIT
