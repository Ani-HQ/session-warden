#!/usr/bin/env bash
# recovery.sh — wake-prompt text after a session restart
#
# A timeout, crash, or zombie that returns the same prose as a finished
# handoff is how the next agent reports work as done. Incomplete endings
# get an explicit INCOMPLETE banner the model cannot miss. Planned
# rotations (token / turn / size / compaction limits) stay unlabeled.

# True when this restart is an early stop, not a planned rotation.
recovery_is_incomplete() {
  local reason
  reason="${1:-}"
  case "$reason" in
    FAILED|ZOMBIE|STALL|TIMEOUT|CRASH) return 0 ;;
    *) return 1 ;;
  esac
}

# Banner the next model reads. Status fields are for code; this line is
# for the agent. Keep it the first line of any incomplete wake text.
recovery_incomplete_banner() {
  local reason
  reason="${1:-unknown}"
  printf 'INCOMPLETE: the previous turn stopped early (%s) and did not finish. Do not report this work as done.\n\n' "$reason"
}

# build_recovery_message <reason> <context_content> <crash_buf>
# Prints the wake prompt. Empty context / crash buffer is allowed.
build_recovery_message() {
  local reason context_content crash_buf recovery_msg
  reason="${1:-}"
  context_content="${2:-}"
  crash_buf="${3:-}"
  recovery_msg=""

  if [ -n "$context_content" ]; then
    if [ -n "$crash_buf" ]; then
      recovery_msg="You just came back from a session restart. Here is context from a PREVIOUS session, INCLUDING messages that were sent to you but never processed because you crashed:

${context_content}

The 'Unprocessed Messages' section above contains what team members said RIGHT BEFORE your crash. These are your TOP PRIORITY. Execute them immediately without asking anyone to repeat themselves. Send one short message confirming you're back and what you're about to do, then do it."
    else
      recovery_msg="You just came back from a session restart. Here is context from a PREVIOUS session (it may be stale or from a different task):

${context_content}

IMPORTANT: This context may NOT reflect what you were last asked to do. Before resuming, ALWAYS check the recent messages in this channel (scroll up or check Discord history) to find your actual current task. The most recent user message is your priority, not the context above. Send one short message saying you're back, then resume the actual pending work from the channel."
    fi
  elif [ -n "$crash_buf" ]; then
    recovery_msg="You just came back from a session restart. Here are messages that were sent to you but never processed because you crashed:

${crash_buf}

Execute these immediately without asking anyone to repeat themselves. Send one short message confirming you're back, then do the work."
  else
    recovery_msg="You just came back from a session restart. Check the recent messages in this channel to find what you were working on. Your MEMORY.md may have older context but the channel messages are the source of truth for your current task. Send a short message saying you're back, then resume work."
  fi

  if recovery_is_incomplete "$reason"; then
    recovery_msg="$(recovery_incomplete_banner "$reason")${recovery_msg}"
  fi

  printf '%s' "$recovery_msg"
}

# Stall-reaper wake text. Always incomplete: the turn was killed mid-flight.
build_stall_recovery_message() {
  local body="You were just restarted: a stalled turn of yours was terminated by the watchdog. Check this channel's most recent messages to find what you were doing and resume that work. Do NOT announce that you're back and do NOT mention this restart; if a user message is waiting for a reply, answer it directly as you normally would."
  printf '%s%s' "$(recovery_incomplete_banner STALL)" "$body"
}
