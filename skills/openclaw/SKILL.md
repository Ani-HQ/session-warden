---
name: session-warden-route
description: Route a task to the cheapest capable harness or model via session-warden before spending this agent's frontier tokens on busywork.
---

# session-warden route (OpenClaw)

Extra Anthropic quota is gone. Do not burn this agent's Claude/Codex credits on summarize, format, lookup, or typos.

## Before you work

```bash
session-warden route --task "$THE_ASK" --host openclaw --json
```

Read `worker`, `reason`, `costClass`, `self`.

- If `self` is true, do the work yourself.
- Otherwise:

```bash
session-warden run --worker "$WORKER" --prompt "$THE_ASK"
```

Use that result. Do not re-do a cheap worker's answer with Opus "just to check" unless the user asked.

Frontier still wins for architecture, multi-file refactors, and security. Rate-limited providers are skipped automatically.
