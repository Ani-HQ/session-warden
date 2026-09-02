#!/usr/bin/env bash
# router.sh — user rules then credits-first heuristic.
# Heavy lifting lives in lib/dispatch.py.

: "${WARDEN_HOME:?WARDEN_HOME must be set}"

# shellcheck source=workers.sh
source "${WARDEN_HOME}/lib/workers.sh"

# Forward route flags (--task, --path, --tag, --host, --json, --file).
router_route() {
  workers_py route "$@"
}
