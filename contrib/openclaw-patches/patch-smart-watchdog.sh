#!/usr/bin/env bash
# patch-smart-watchdog.sh — wrapper for the JS patcher
# MUST be re-run after every `npm update openclaw` or `npm install -g openclaw`.
set -euo pipefail
node "$(dirname "$0")/patch-smart-watchdog.js"
