---
name: session-warden-route
description: Route a task to the cheapest capable harness or model via session-warden before spending Grok credits on busywork.
---

# session-warden route (Grok)

Extra Anthropic quota is gone. Keep frontier models for hard work; route busywork out.

## Before you work

```bash
session-warden route --task "$THE_ASK" --host grok-build --json
```

Read `worker`, `reason`, `costClass`, `self`.

- If `self` is true, do the work yourself.
- Otherwise:

```bash
session-warden run --worker "$WORKER" --prompt "$THE_ASK"
```

Use that result. Do not re-do a cheap worker's answer "just to check" unless the user asked.

Frontier still wins for architecture, multi-file refactors, and security. Rate-limited providers are skipped automatically.

If your grokbot has no skills directory, paste this file into whatever skill/prompt slot it uses.
