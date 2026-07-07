# Contributing

Thanks for helping improve session-warden.

## Running the tests

```bash
bash tests/run-tests.sh              # full suite
bash tests/run-tests.sh test-detect  # one file
bash tests/run-tests.sh -v           # verbose
```

Tests run in a sandboxed mock environment (mock OpenClaw state, mock `claude`
CLI, mock crontab) — no live gateway, API calls, or real cron entries are
touched. `jq` and `bash` 4+ are the only requirements. CI runs the same suite
on every PR.

## Code style

- Bash, `#!/usr/bin/env bash`, with `set -uo pipefail` (deliberately not `-e`
  in long-running loops — a single bad session must never kill the scan).
- Everything must pass `shellcheck --severity=warning` (CI enforces this on
  `bin/`, `lib/`, `contrib/`, `hooks/`, `tests/`, and `install.sh`).
  If a finding is a false positive, add a targeted
  `# shellcheck disable=SCxxxx` with a one-line justification comment.
- Portability: use the helpers in `lib/portable.sh` instead of raw `stat`
  flags (GNU vs BSD). Scripts should keep working on both Linux and macOS
  where practical.
- Config: any new tunable must be a `WARDEN_*` variable with a sane default,
  documented in `config/thresholds.env.example`.
- Production safety first: these scripts run from cron against live agent
  fleets. Prefer no-ops and loud logging over clever recovery; never delete a
  session JSONL (archive it).

## Pull requests

- Branch from `main`; one logical change per PR.
- Add or update tests for behavior changes (`tests/test-<area>.sh`, using the
  helpers in `tests/helpers/setup.sh`).
- Conventional-commit-ish subject lines are appreciated: `fix(reap): ...`,
  `docs: ...`, `feat(scorecard): ...`.
- Update README/CHANGELOG when you change user-facing behavior.
- Keep CI green: `bash tests/run-tests.sh` and shellcheck both pass before
  requesting review.
