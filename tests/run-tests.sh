#!/usr/bin/env bash
# run-tests.sh — minimal test runner for session-warden
#
# Usage:
#   bash tests/run-tests.sh              # run all tests
#   bash tests/run-tests.sh test-detect   # run one test file
#   bash tests/run-tests.sh -v            # verbose output

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="$(dirname "$TESTS_DIR")"
export WARDEN_HOME TESTS_DIR

# ─── Colors ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Args ─────────────────────────────────────────────────
TARGET=""
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    *) TARGET="$arg" ;;
  esac
done
export VERBOSE

# ─── Setup ────────────────────────────────────────────────

source "$TESTS_DIR/helpers/setup.sh"

# ─── Run tests ────────────────────────────────────────────

printf "\n${CYAN}session-warden test suite${NC}\n"
printf "=========================\n\n"

test_files=()
if [ -n "$TARGET" ]; then
  target_file="$TESTS_DIR/${TARGET}.sh"
  [ -f "$target_file" ] || target_file="$TESTS_DIR/test-${TARGET}.sh"
  if [ -f "$target_file" ]; then
    test_files=("$target_file")
  else
    echo "ERROR: test file not found: $TARGET"
    exit 1
  fi
else
  for f in "$TESTS_DIR"/test-*.sh; do
    [ -f "$f" ] && test_files+=("$f")
  done
fi

for test_file in "${test_files[@]}"; do
  test_name=$(basename "$test_file" .sh | sed 's/^test-//')
  printf "${CYAN}%s${NC}\n" "$test_name"

  # Reset sandbox for each test file
  setup_sandbox

  # Run test file in a subshell — it writes results to TEST_RESULTS_FILE
  ( source "$test_file" )
done

# ─── Collect results ─────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
ERRORS=()

if [ -f "$TEST_RESULTS_FILE" ]; then
  while IFS='|' read -r result msg; do
    case "$result" in
      PASS) PASS=$((PASS + 1))
            [ "$VERBOSE" -eq 1 ] && printf "    ${GREEN}PASS${NC} %s\n" "$msg"
            ;;
      FAIL) FAIL=$((FAIL + 1))
            printf "    ${RED}FAIL${NC} %s\n" "$msg"
            ERRORS+=("$msg")
            ;;
      SKIP) SKIP=$((SKIP + 1))
            printf "    ${YELLOW}SKIP${NC} %s\n" "$msg"
            ;;
    esac
  done < "$TEST_RESULTS_FILE"
fi

# ─── Teardown ─────────────────────────────────────────────

teardown_sandbox
rm -f "$TEST_RESULTS_FILE"

# ─── Report ───────────────────────────────────────────────

printf "\n=========================\n"
printf "${GREEN}%d passed${NC}" "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf ", ${RED}%d failed${NC}" "$FAIL"
fi
if [ "$SKIP" -gt 0 ]; then
  printf ", ${YELLOW}%d skipped${NC}" "$SKIP"
fi
printf "\n"

if [ "$FAIL" -gt 0 ]; then
  printf "\n${RED}Failed tests:${NC}\n"
  for e in "${ERRORS[@]}"; do
    printf "  - %s\n" "$e"
  done
  exit 1
fi

exit 0
