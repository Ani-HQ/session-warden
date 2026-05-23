#!/usr/bin/env python3
"""Write a crash buffer file from detect-unprocessed output.

Args: argv[1] = result file (from detect-unprocessed.py)
      argv[2] = output buffer file path
      argv[3] = agent name
      argv[4] = channel key
      argv[5] = provider
      argv[6] = captured_at (epoch seconds)
      argv[7] = session_updated_at (epoch ms)
"""

import json
import sys


def main():
    result_file = sys.argv[1]
    buffer_file = sys.argv[2]
    agent = sys.argv[3]
    channel_key = sys.argv[4]
    provider = sys.argv[5]
    captured_at = int(sys.argv[6])
    session_updated_at = int(sys.argv[7])

    with open(result_file) as f:
        data = json.load(f)

    buffer = {
        "agent": agent,
        "channel_key": channel_key,
        "provider": provider,
        "captured_at": captured_at,
        "session_updated_at": session_updated_at,
        "unprocessed_messages": data.get("unprocessed", []),
        "last_bot_message": data.get("last_bot_message"),
        "total_fetched": data.get("total_fetched", 0),
    }

    with open(buffer_file, "w") as f:
        json.dump(buffer, f, indent=2)


if __name__ == "__main__":
    main()
