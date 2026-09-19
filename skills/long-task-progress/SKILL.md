---
name: long-task-progress
description: Show live long-task progress as one Discord/Telegram card that is edited in place. Use when a task will take more than a couple of minutes or many items (research, enrichment, batch writes).
---

# Long-task progress card

Stay in this parent turn. Do not spawn Agent/Task children and exit.

Post **one** card. Edit that card. Never send a new "running…" message each tick.

```bash
# first tick
~/session-warden/bin/progress-card.sh start \
  --agent "$AGENT" \
  --channel "$SESSION_KEY" \
  --title "short task name" \
  --done 0 --total N \
  --now "what you are doing" \
  --sheet-url "$SHEET_URL"

# every 5 items, or when blocked, or when finished
~/session-warden/bin/progress-card.sh update \
  --agent "$AGENT" \
  --channel "$SESSION_KEY" \
  --done K --total N \
  --now "current item"

~/session-warden/bin/progress-card.sh done \
  --agent "$AGENT" \
  --channel "$SESSION_KEY" \
  --done N --total N \
  --now "finished"
```

`$SESSION_KEY` is the OpenClaw session key (example: `agent:dash:discord:channel:123`). Discord is inferred from that key. Set `--telegram-target` or `WARDEN_PROGRESS_TELEGRAM_TARGET` to fan out.

The helper throttles: at most one edit per 45s, or every 5 items, whichever comes first. `start`, `done`, and `blocked` always send.

Live cards include **Stop** and **Steer**. Clicks are handled by `progress-card-actions` (not a new message). Stop aborts the current run. Steer asks for a correction; the next message injects it. `done` drops those buttons.

The results sheet is the work artifact. The card is the live indicator. Do not use a sheet as the "still going?" UI.
