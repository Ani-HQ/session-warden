# Custom workers

A worker is a bash command. If you can run it in a terminal, you can put it
in `config/workers.d/*.json` and `session-warden route` will consider it.

Do **not** put API keys in the catalog. Use the vendor CLI's own auth, or a
wrapper that reads a secret from the environment.

## Wrapper sketch

`contrib/workers/` is for *your* one-liners, not for shipping credentials.

```bash
#!/usr/bin/env bash
# Example only — adjust the vendor URL and flag names.
# Save as ~/bin/deepseek and chmod +x, then detect.commands: ["deepseek"]
set -uo pipefail
: "${DEEPSEEK_API_KEY:?set DEEPSEEK_API_KEY in ~/.config/session-warden/secrets.env}"
prompt="${1:-}"
# call the vendor's documented non-interactive CLI or HTTP API here
```

Then drop a JSON overlay (see `config/workers.d/custom.example.json`) whose
`detect.commands` matches the wrapper name.

Documented non-interactive flags only. Do not add `--dangerously-skip-permissions`
or equivalent unless the user already runs that CLI that way themselves.
