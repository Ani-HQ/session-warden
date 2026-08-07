# discord-harvest-actions

Button handler for the skill harvester's interactive Discord proposal cards.

`bin/harvest-skills.sh` posts one Discord message per staged `SKILL.md` draft
with four buttons. This service connects to the Discord **gateway** (no public
HTTPS endpoint or open port needed on the fleet host) and executes the clicks:

| Button | Action |
|--------|--------|
| Promote | `bin/promote-skill.sh <agent> <skill>` |
| Promote shared | `bin/promote-skill.sh <agent> <skill> --shared` |
| Reject | move draft to `~/.openclaw/skills-rejected/<agent>/<skill>-<ts>` (never deleted) |
| View draft | ephemeral reply with the `SKILL.md` contents |

After promote/reject the card is edited in place (outcome + who clicked) and
the buttons are removed, so a handled proposal can't be double-actioned.

## Setup

1. Create a Discord application + bot (or reuse an existing one), invite it to
   your server with the **Send Messages** permission. No privileged intents
   needed.
2. In `config/thresholds.env` set:
   - `WARDEN_DISCORD_BOT_TOKEN` — the bot token
   - `WARDEN_HARVEST_DISCORD_CHANNEL_ID` — where proposal cards go
   - `WARDEN_DISCORD_ALLOWED_USER_IDS` — comma/space-separated Discord user
     IDs allowed to click. **Empty = every click is refused** (default-deny:
     your agents live in these channels too).
3. Install + start the service:

```bash
cp deploy/harvest-actions.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now harvest-actions.service
```

The launcher (`bin/harvest-actions.sh`) installs the npm dependencies on first
run. Logs go to the journal: `journalctl --user -u harvest-actions -f`.

## Security notes

- `custom_id`s are validated against a strict slug regex and resolved paths
  are checked to stay inside `skills-pending/` — a forged interaction can't
  reach outside the staging area.
- Promotion runs `promote-skill.sh` via `execFile` (no shell), with a 60s
  timeout.
- Rejection is a move, not a delete — drafts land in
  `~/.openclaw/skills-rejected/` with a timestamp suffix.
