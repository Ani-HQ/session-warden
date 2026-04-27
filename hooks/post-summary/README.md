# Post-Summary Hooks

Drop executable `.sh` scripts here. They run after each session is summarized, with these env vars:

| Variable | Description |
|---|---|
| `WARDEN_AGENT` | Agent name (e.g., `ping`) |
| `WARDEN_CHANNEL_KEY` | Full channel key |
| `WARDEN_SESSION_ID` | Claude CLI session ID |
| `WARDEN_MEMORY_FILE` | Path to the generated memory file |
| `WARDEN_TRANSCRIPT_FILE` | Path to the extracted transcript |
| `WARDEN_ARCHIVED_JSONL` | Path to the archived JSONL |

Scripts run in alphabetical order. Failures are logged but don't block other hooks.

## Examples

- `01-gbrain.sh` — ingest into GBrain for cross-agent memory
- `02-slack.sh` — post rotation summary to a Slack channel
- `03-notion.sh` — write to a Notion database
