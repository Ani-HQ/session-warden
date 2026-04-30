#!/usr/bin/env bash
# memory.sh — write session memory to Claude Code's native memory system

MEMORY_MODEL="${WARDEN_SUMMARY_MODEL:-claude-haiku-4-5-20251001}"
MEMORY_MAX_FILE_BYTES="${WARDEN_MEMORY_MAX_BYTES:-16384}"

# Resolve the Claude Code memory directory for an agent
claude_memory_dir() {
  local agent="$1"
  local dir="${WARDEN_CLAUDE_PROJECTS}/-home-$(whoami)--openclaw-agents-${agent}/memory"
  mkdir -p "$dir"
  echo "$dir"
}

# Build a fallback memory when Haiku summarization fails or times out.
# Extracts the last 30 lines of transcript + pending items from previous memory.
# Args: $1=transcript, $2=existing_context (previous memory content, may be empty)
build_fallback_memory() {
  local transcript="$1" existing_context="$2"
  local tail_lines pending_block=""

  tail_lines=$(echo "$transcript" | tail -30)

  if [ -n "$existing_context" ]; then
    local pending
    pending=$(echo "$existing_context" | sed -n '/## Pending/,/^## /p' | sed '$d')
    if [ -n "$pending" ]; then
      pending_block="

### Carried forward from previous session
${pending}
"
    fi
  fi

  cat <<FALLBACK
## What was happening
(fallback: summarization unavailable — raw transcript tail below)

## Recent activity (last 30 lines)
\`\`\`
${tail_lines}
\`\`\`
${pending_block}
## Context for next session
This is a fallback memory written because Haiku summarization timed out or failed. Review the transcript archive for full context.
FALLBACK
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

  local existing_context=""
  if [ -f "$mem_file" ]; then
    existing_context=$(cat "$mem_file")
  fi

  local carry_forward_block=""
  if [ -n "$existing_context" ]; then
    carry_forward_block="
PREVIOUS SESSION MEMORY (carry forward any unresolved pending items):
${existing_context}
"
  fi

  local summary
  summary=$(timeout 60 claude -p --model "$MEMORY_MODEL" "You are a memory system. Extract a structured summary from the transcript below for an AI agent named '${agent}' so it can resume work seamlessly after a session restart.

RULES:
- Output ONLY the structured sections below. No preamble, no commentary, no code fences, no frontmatter.
- Do NOT wrap output in \`\`\`markdown blocks.
- Do NOT include instructions like 'push this to memory' or 'save this'.
- Write in second person ('you were...').
- Be specific: file paths, branch names, URLs, error messages.
- Under 300 words total.

The transcript includes both conversation text and tool actions (marked with →). Pay attention to BOTH.
${carry_forward_block}
Output exactly these sections:

## What was happening
(1-3 sentences: the main task or thread)

## Actions taken
(bullet list: concrete things done — files created/edited, branches pushed, PRs opened, commands run)

## Decisions made
(bullet list: choices, preferences, or rules established)

## Pending / unfinished
(bullet list: anything incomplete or next-up. Carry forward unresolved items from previous session memory)

## Context for next session
(anything that would be confusing without this note — why something was done, blockers, relationships between tasks)

TRANSCRIPT:
${transcript}" 2>/dev/null)

  # Strip code fences and meta-commentary that LLMs sometimes add
  if [ -n "$summary" ]; then
    summary=$(echo "$summary" | sed '/^```/d' | sed '/^---$/d' | sed '/^name:/d' | sed '/^description:/d' | sed '/^type:/d' | sed '/^I.ll write/d' | sed '/^Push this/d' | sed '/^Here.s the/d'  | sed '/^Let me/d')
  fi

  # Validate: non-empty AND substantive (at least 20 words with real content)
  local word_count=0
  if [ -n "$summary" ]; then
    word_count=$(echo "$summary" | wc -w)
  fi
  if [ -z "$summary" ] || [ "$word_count" -lt 20 ]; then
    log "MEMORY: summarization failed, empty, or too short (${word_count} words) for $agent — writing fallback"
    summary=$(build_fallback_memory "$transcript" "$existing_context")
  fi

  if [ -z "$summary" ]; then
    log "MEMORY: fallback also empty for $agent — no memory written"
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

  # Write to workspace MEMORY.md (auto-loaded by bootstrap into system prompt)
  # This is the key fix: context is INJECTED, not voluntarily loaded by the agent
  write_workspace_context "$agent" "$summary" "$cli_session_id" "$channel_key" || \
    log "MEMORY: workspace context write failed for $agent (non-fatal)"

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

# Write session context to workspace files that bootstrap auto-loads.
# This is the system-level guarantee: the agent receives context in its system
# prompt without needing to voluntarily read files.
# Args: $1=agent, $2=summary, $3=cli-session-id, $4=channel-key
write_workspace_context() {
  local agent="$1" summary="$2" cli_session_id="$3" channel_key="$4"
  local workspace="${WARDEN_OPENCLAW_HOME}/agents/${agent}"
  local context_file="${workspace}/CONTEXT.md"
  local memory_file="${workspace}/MEMORY.md"
  local ts
  ts=$(date -Iseconds)

  [ -d "$workspace" ] || {
    log "MEMORY: workspace $workspace does not exist — skipping"
    return 1
  }

  # 1. Write standalone CONTEXT.md (used by recovery messages to inline context)
  cat > "$context_file" << CTXEOF
_Last updated: ${ts} | Session: ${cli_session_id} | Channel: ${channel_key}_

${summary}
CTXEOF
  log "MEMORY: wrote CONTEXT.md for $agent ($(stat -c%s "$context_file") bytes)"

  # 2. Inject into workspace MEMORY.md (bootstrap loads this into system prompt)
  local existing=""
  if [ -f "$memory_file" ]; then
    # Strip any previous auto-injected section between markers
    existing=$(awk '
      /^<!-- SESSION-WARDEN-START -->/{skip=1; next}
      /^<!-- SESSION-WARDEN-END -->/{skip=0; next}
      !skip{print}
    ' "$memory_file")
  fi

  cat > "$memory_file" << MEMEOF
<!-- SESSION-WARDEN-START -->
## Previous Session Context (auto-injected by session-warden, do not edit this section)

_Updated: ${ts} | Channel: ${channel_key}_

${summary}

<!-- SESSION-WARDEN-END -->
${existing}
MEMEOF

  log "MEMORY: injected context into workspace MEMORY.md for $agent"
}
