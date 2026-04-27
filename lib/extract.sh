#!/usr/bin/env bash
# extract.sh — extract conversation + tool context from JSONL

# Extract full conversation: text messages + tool actions
# Produces a human-readable transcript with tool context included
extract_session_transcript() {
  local jsonl="$1"
  [ -f "$jsonl" ] || return 1

  jq -r '
    if .type == "user" and (.message.content | any(.type == "text")) then
      "USER: " + ([.message.content[] | select(.type == "text") | .text] | join("\n"))
    elif .type == "assistant" and (.message.content | any(.type == "text" or .type == "tool_use")) then
      (
        ([.message.content[] | select(.type == "text") | .text] | if length > 0 then "ASSISTANT: " + join("\n") else "" end),
        ([.message.content[] | select(.type == "tool_use") |
          "  → " + .name +
          (if .input.file_path then " " + .input.file_path else "" end) +
          (if .input.command then " `" + (.input.command | tostring[0:100]) + "`" else "" end)
        ] | if length > 0 then join("\n") else "" end)
      ) | select(. != "")
    else
      empty
    end
  ' "$jsonl" 2>/dev/null
}

# Extract just the tool actions for a compact "what was done" view
extract_tool_summary() {
  local jsonl="$1"
  [ -f "$jsonl" ] || return 1

  jq -r '
    select(.type == "assistant" and (.message.content | any(.type == "tool_use"))) |
    [.message.content[] | select(.type == "tool_use") |
      .name +
      (if .input.file_path then " " + (.input.file_path | split("/") | last) else "" end) +
      (if .input.command then " `" + (.input.command | tostring[0:60]) + "`" else "" end)
    ] | .[]
  ' "$jsonl" 2>/dev/null | sort | uniq -c | sort -rn | head -20
}
