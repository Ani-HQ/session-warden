#!/usr/bin/env bash
# portable.sh — small cross-platform helpers (GitHub #2: macOS-portable stat).
#
# GNU coreutils (Linux) and BSD (macOS) stat disagree on flags: GNU wants
# -c%Y/-c%s, BSD wants -f %m/-f %z. The probe order is load-bearing — GNU
# stat ALSO accepts -f (filesystem status), where %m means MOUNT POINT, so a
# BSD-first probe silently returns garbage with exit 0 on Linux. GNU -c fails
# loudly on macOS, so try it first and fall back to BSD.
# Both helpers echo 0 for a missing/unreadable file.

# stat_mtime <file> — seconds-since-epoch mtime, or 0
stat_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# stat_size <file> — size in bytes, or 0
stat_size() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0
}

# sed_inplace <script> <file>...
sed_inplace() {
  local script="$1"
  shift

  if sed --version >/dev/null 2>&1; then
    sed -i "$script" "$@"
  else
    sed -i '' "$script" "$@"
  fi
}

# touch_relative <GNU-relative-time> <file>...
# Supports the "N seconds/minutes/hours/days ago" forms used by tests.
touch_relative() {
  local relative="$1"
  shift

  if touch --version >/dev/null 2>&1; then
    touch -d "$relative" "$@"
    return
  fi

  local amount unit suffix extra flag ts
  read -r amount unit suffix extra <<< "$relative"
  [ "$suffix" = "ago" ] && [ -z "$extra" ] || return 1
  case "$amount" in
    ''|*[!0-9]*) return 1 ;;
  esac

  case "$unit" in
    second|seconds) flag="-v-${amount}S" ;;
    minute|minutes) flag="-v-${amount}M" ;;
    hour|hours) flag="-v-${amount}H" ;;
    day|days) flag="-v-${amount}d" ;;
    *) return 1 ;;
  esac

  ts=$(date "$flag" "+%Y%m%d%H%M.%S") || return 1
  touch -t "$ts" "$@"
}

# date_iso_seconds — ISO-8601-ish current time with seconds.
date_iso_seconds() {
  if date --version >/dev/null 2>&1; then
    date -Iseconds
    return
  fi

  local ts
  ts=$(date "+%Y-%m-%dT%H:%M:%S%z") || return 1
  printf '%s:%s\n' "${ts%??}" "${ts: -2}"
}
