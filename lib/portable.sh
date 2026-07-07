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
