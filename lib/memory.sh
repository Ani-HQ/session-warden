#!/usr/bin/env bash
# memory.sh — write session memory to Claude Code's native memory system

MEMORY_MODEL="${WARDEN_SUMMARY_MODEL:-claude-haiku-4-5-20251001}"
MEMORY_MAX_FILE_BYTES="${WARDEN_MEMORY_MAX_BYTES:-16384}"

# Resolve the Claude Code memory directory for an agent
claude_memory_dir() {
  local agent="$1"
  local dir="${WARDEN_CLAUDE_PROJECTS}/-home-${USER}--openclaw-agents-${agent}/memory"
  mkdir -p "$dir"
  echo "$dir"
}

# Summarize a transcript and write to Claude Code memory
# Args: $1=agent, $2=channel-key, $3=cli-session-id, $4=transcript-file
write_session_memory() {
  local agent="$1" channel_key="$2" cli_session_id="$3" transcript_file="$4"
  local mem_dir
  mem_dir=$(claude_memory_dir "$agent")
  local memory_index="${mem_dir}/MEMORY.md"
  local ts
  ts=$(date -Iseconds)

  # Sanitize channel key for filename
  local safe_channel
  safe_channel=$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g')
  local mem_file="${mem_dir}/session_${safe_channel}.md"

  [ -f "$transcript_file" ] || {
    log "MEMORY: no transcript file at $transcript_file"
    return 1
  }

  local transcript
  transcript=$(cat "$transcript_file")

  [ -z "$transcript" ] && {
    log "MEMORY: empty transcript — skipping"
    return 0
  }

  local summary
  summary=$(claude -p --model "$MEMORY_MODEL" "You are a memory system for an AI agent named '${agent}'. This agent's session is being rotated and you need to capture everything important so the agent can continue seamlessly in this channel.

The transcript below includes both conversation text and tool actions (marked with →). Pay attention to BOTH — the tool actions show what was actually done (files edited, commands run, branches created).

Write a structured memory entry:

## What was happening
(1-3 sentences: the main task or thread in this channel)

## Actions taken
(bullet list: concrete things done — files created/edited, branches pushed, PRs opened, commands run)

## Decisions made
(bullet list: choices, preferences, or rules established)

## Pending / unfinished
(bullet list: anything incomplete, promised, or next-up)

## Context for next session
(anything that would be confusing without this note — why something was done a certain way, relationships between tasks, blockers)

Be specific: file paths, branch names, URLs, error messages. Under 300 words. Write in second person ('you were...').

TRANSCRIPT:
${transcript}" 2>/dev/null)

  if [ -z "$summary" ]; then
    log "MEMORY: summarization returned empty for $agent"
    return 1
  fi

  # Write the memory file
  cat > "$mem_file" << EOF
---
name: session-context-${safe_channel}
description: Last session context for channel ${channel_key} — what was being worked on, actions taken, and pending items
type: project
---

_Captured by session-warden at ${ts}_
_Session: ${cli_session_id}_

${summary}
EOF

  # Update MEMORY.md index
  if [ ! -f "$memory_index" ]; then
    echo "# Memory" > "$memory_index"
    echo "" >> "$memory_index"
  fi

  # Remove old entry for this channel if present, then add new one
  local entry_line="- [Session: ${channel_key}](session_${safe_channel}.md) — last session context before rotation"
  if grep -qF "session_${safe_channel}.md" "$memory_index" 2>/dev/null; then
    grep -vF "session_${safe_channel}.md" "$memory_index" > "${memory_index}.tmp"
    mv "${memory_index}.tmp" "$memory_index"
  fi
  echo "$entry_line" >> "$memory_index"

  local file_size
  file_size=$(stat -c%s "$mem_file")
  log "MEMORY: written ${mem_file} (${file_size} bytes)"

  # Compact if too large
  if [ "$file_size" -gt "$MEMORY_MAX_FILE_BYTES" ]; then
    compact_memory_file "$mem_file"
  fi

  return 0
}

compact_memory_file() {
  local mem_file="$1"
  log "MEMORY: compacting ${mem_file}"

  local content
  content=$(cat "$mem_file")
  local compacted
  compacted=$(claude -p --model "$MEMORY_MODEL" "Compact this session memory file to ~40% of its current length. Keep the frontmatter block (--- to ---) exactly as-is. Preserve concrete details (paths, branches, decisions). Drop completed items. Keep pending items and context.

${content}" 2>/dev/null)

  [ -n "$compacted" ] && echo "$compacted" > "$mem_file"
}
