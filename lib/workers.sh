#!/usr/bin/env bash
# workers.sh — catalog load, detect, invoke.
# Heavy lifting lives in lib/dispatch.py.

: "${WARDEN_HOME:?WARDEN_HOME must be set}"

workers_py() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required for session-warden workers/route/run" >&2
    return 1
  fi
  python3 "${WARDEN_HOME}/lib/dispatch.py" "$@"
}

# JSON catalog with detected/available flags.
workers_catalog_json() {
  workers_py catalog --json
}

# Print human table (detected vs missing).
workers_list() {
  workers_py catalog
}

# Count available (detected and not rate-guard-demoted) workers.
workers_detected_count() {
  workers_py detect
}

# Invoke worker id with a prompt. Extra args forwarded (e.g. --json --cwd).
workers_invoke() {
  local id="$1"
  local prompt="$2"
  shift 2 || true
  workers_py invoke --worker "$id" --prompt "$prompt" "$@"
}
