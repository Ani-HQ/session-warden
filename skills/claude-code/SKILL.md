---
name: session-warden-route
description: Route busywork to a cheaper model or harness via session-warden. Use before spending Claude Code tokens on summarize, format, lookup, or typos.
---

# session-warden route (Claude Code)

Extra Anthropic quota is gone. You are the frontier harness. Do not spend yourself on busywork.

## Before you work

```bash
session-warden route --task "$THE_ASK" --host claude-code --json
```

Read `worker`, `reason`, `costClass`, `self`.

- If `self` is true, do the work yourself.
- Otherwise:

```bash
session-warden run --worker "$WORKER" --prompt "$THE_ASK"
```

Use that result. Do not re-do it with Opus "just to check" unless the user asked.

Frontier still wins for architecture, multi-file refactors, and security. Rate-limited providers are skipped automatically.
