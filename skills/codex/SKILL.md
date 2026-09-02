---
name: session-warden-route
description: Route busywork to a cheaper model or harness via session-warden before spending Codex credits.
---

# session-warden route (Codex)

Extra Anthropic quota is gone. Preserve credits: route summarize, format, lookup, and typos away from this harness.

## Before you work

```bash
session-warden route --task "$THE_ASK" --host codex --json
```

Read `worker`, `reason`, `costClass`, `self`.

- If `self` is true, do the work yourself.
- Otherwise:

```bash
session-warden run --worker "$WORKER" --prompt "$THE_ASK"
```

Use that result. Do not re-do a cheap worker's answer "just to check" unless the user asked.

Frontier still wins for architecture, multi-file refactors, and security. Rate-limited providers are skipped automatically.
