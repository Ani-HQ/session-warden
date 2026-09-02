# Routing: bash workers, user rules, credits-first default

New here? The [README](../README.md) shows the credits chart and the route
diagram. This page is the rule language.

If a harness or model can be run in bash, it can be orchestrated. This is
**dispatch**, not session supervision. The lifeguard still only rotates Claude
Code sessions. See [integrations.md](integrations.md) for that contract.

## Why

Extra Anthropic quota is gone. A Claude-primary fleet either stalls when the
weekly cap hits, or burns frontier credits on summarize / format / typos.
`session-warden route` picks the cheapest capable worker; frontier stays for
hard work.

```bash
session-warden workers                  # what is on PATH
session-warden route --task "fix the typo in README" --json
session-warden run --task "fix the typo in README"
session-warden onboard --dry-run
```

## Catalog schema

Built-ins live in [`config/workers.json`](../config/workers.json). Overlays
are JSON files in `config/workers.d/` (same shape, or a single worker object).
`*.example.json` is ignored.

```json
{
  "id": "deepseek-chat",
  "kind": "model",
  "label": "DeepSeek Chat",
  "provider": "deepseek",
  "costClass": "cheap",
  "capabilities": ["chat", "code"],
  "detect": { "commands": ["deepseek"] },
  "invoke": {
    "argv": ["deepseek", "chat", "{{prompt}}"],
    "timeoutSec": 180
  }
}
```

| Field | Meaning |
|---|---|
| `id` | Stable name used by route/run and `--host` |
| `kind` | `harness` (nested CLI) or `model` (direct) |
| `provider` | Rate-guard skip key (`claude`, `openai`, …) |
| `costClass` | `cheap` / `mid` / `frontier` |
| `capabilities` | `chat`, `code`, `tools`, `repo` |
| `detect.commands` | PATH checks, no network |
| `invoke.argv` | `{{prompt}}` and `{{cwd}}` substituted as single arguments |
| `invoke.stdin` | optional; if true, the prompt is also written to stdin |
| `invoke.timeoutSec` | kill the worker after this many seconds |

Do not invent unsafe flags. Use each CLI's documented non-interactive invocation.
API keys stay in the vendor CLI or a wrapper — see [contrib/workers/README.md](../contrib/workers/README.md).

## How a worker is added (about ten lines)

1. Make sure you can run it: `deepseek chat "hello"` (or your wrapper).
2. Copy [`config/workers.d/custom.example.json`](../config/workers.d/custom.example.json) to `config/workers.d/deepseek.json`.
3. Set `id`, `detect.commands`, and `invoke.argv`.
4. `session-warden workers` should show `avail yes`.

## Decision order

1. **User rules** in `config/routing.yaml` (copy from `routing.yaml.example`). First matching rule whose worker is **available** wins.
2. **Credits-first heuristic** — cheapest capable worker. Frontier only when complexity is high, the cheap worker lacks `tools`/`repo`, or `run` retries after a failure.
3. Skip workers whose `provider` is currently demoted in `state/rate-guard/state.json`.

Complexity is a keyword/length heuristic, not an LLM call:

- **low** — summarize, format, rename, lookup, regex, short Q&A
- **mid** — implement a function, fix a test, write a script
- **high** — architecture, multi-file refactor, security, “use frontier”

Asks that mention files or edit/implement/fix need `tools` or `repo` (harness-only pool).

## Rule language

```yaml
policy: credits-first
rules:
  - match: { path: "**/security/**" }
    worker: claude-code
  - match: { complexity: low }
    worker: deepseek-chat
  - match:
      tag: docs
      contains: changelog
    worker: glm
```

`match` keys: `path` (glob, `**` allowed), `complexity` (`low`/`mid`/`high`), `tag` (from `--tag`), `contains` (substring of the task). All present keys must match. Pass `--path` / `--tag` on `session-warden route`.

JSON is also accepted (`config/routing.json`, or a file that starts with `{`).

## Skill contract (JSON)

```json
{
  "worker": "deepseek-chat",
  "costClass": "cheap",
  "reason": "credits-first",
  "complexity": "low",
  "fallback": "glm",
  "self": false
}
```

`self` is true when `--host` equals the chosen worker — the host should do the work itself instead of spawning a nested copy of itself.
