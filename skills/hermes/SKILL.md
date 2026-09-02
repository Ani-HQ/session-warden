---
name: session-warden-route
description: Route a task to the cheapest capable harness or model via session-warden before spending this Hermes agent's tokens on busywork.
---

# session-warden route (Hermes)

Extra Anthropic quota is gone. Do not burn frontier credits on summarize, format, lookup, or typos.

## Before you work

```bash
session-warden route --task "$THE_ASK" --host hermes --json
```

Read `worker`, `reason`, `costClass`, `self`.

- If `self` is true, do the work yourself.
- Otherwise:

```bash
session-warden run --worker "$WORKER" --prompt "$THE_ASK"
```

Use that result. Do not re-do a cheap worker's answer with a frontier model "just to check" unless the user asked.

Frontier still wins for architecture, multi-file refactors, and security. Rate-limited providers are skipped automatically.
