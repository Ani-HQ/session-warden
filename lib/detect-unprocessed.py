#!/usr/bin/env python3
"""Detect unprocessed messages in a channel after an agent crash.

Reads a JSON array of messages (from Discord/Telegram) on stdin or from
the file path given as argv[1]. Outputs a JSON object with:
  - unprocessed: messages sent by humans that the bot never processed
  - last_bot_message: the last normal bot response before the crash
  - total_fetched: total messages analyzed

Crash detection: identifies error/recovery bot messages (e.g., "All models failed",
"standing by", etc.) and finds human messages that appeared between the last
normal bot response and the first crash message.
"""

import json
import re
import sys

CRASH_PATTERNS = [
    r"all models failed",
    r"circuits?.*(crossed|tangled|bit)",
    r"crashed",
    r"error.*failed",
    r"resumed.*no interrupted",
    r"standing by",
    r"same state.*no.*activity",
    r"duplicate.*restart",
    r"already (checked|caught up)",
    r"session restart",
    r"neural nets.*tangled",
    r"digital faceplant",
    r"shucks",
]


def is_crash_or_recovery(content):
    lower = content.lower()
    for pat in CRASH_PATTERNS:
        if re.search(pat, lower):
            return True
    return False


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            messages = json.load(f)
    else:
        messages = json.load(sys.stdin)

    empty = {"unprocessed": [], "last_bot_message": None, "total_fetched": 0}

    if not isinstance(messages, list) or not messages:
        print(json.dumps(empty))
        return

    # Find boundary: last normal bot response vs first crash/recovery message
    first_crash_idx = len(messages)
    last_normal_bot_idx = -1

    for i, msg in enumerate(messages):
        if msg.get("is_bot", False):
            if is_crash_or_recovery(msg.get("content", "")):
                if first_crash_idx == len(messages):
                    first_crash_idx = i
            else:
                if i < first_crash_idx:
                    last_normal_bot_idx = i

    # Unprocessed = human messages between last normal bot response and first crash
    unprocessed = []
    for i, msg in enumerate(messages):
        if not msg.get("is_bot", False) and msg.get("content", "").strip():
            if i > last_normal_bot_idx and i < first_crash_idx:
                unprocessed.append(msg)

    # Fallback: if no crash messages found, human messages after last bot message
    if first_crash_idx == len(messages):
        last_bot_idx = -1
        for i, msg in enumerate(messages):
            if msg.get("is_bot", False):
                last_bot_idx = i
        unprocessed = []
        for i, msg in enumerate(messages):
            if i > last_bot_idx and not msg.get("is_bot", False) and msg.get("content", "").strip():
                unprocessed.append(msg)

    # Also include human messages after crash (user telling agent to recover)
    for i, msg in enumerate(messages):
        if i >= first_crash_idx and not msg.get("is_bot", False) and msg.get("content", "").strip():
            if msg not in unprocessed:
                unprocessed.append(msg)

    last_bot = None
    if last_normal_bot_idx >= 0:
        last_bot = messages[last_normal_bot_idx]

    result = {
        "unprocessed": unprocessed,
        "last_bot_message": last_bot,
        "total_fetched": len(messages),
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
