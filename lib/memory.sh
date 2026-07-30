#!/usr/bin/env bash
# memory.sh — write session memory to Claude Code's native memory system

MEMORY_MODEL="${WARDEN_SUMMARY_MODEL:-claude-haiku-4-5-20251001}"
MEMORY_MAX_FILE_BYTES="${WARDEN_MEMORY_MAX_BYTES:-16384}"

# Portable stat helpers (stat_size)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable.sh"

# Source channel-history for crash buffer support
if [ -f "${WARDEN_HOME}/lib/channel-history.sh" ]; then
  source "${WARDEN_HOME}/lib/channel-history.sh"
fi

# Resolve the Claude Code memory directory for an agent
claude_memory_dir() {
  local agent="$1"
  local dir
  dir="${WARDEN_CLAUDE_PROJECTS}/-home-$(whoami)--openclaw-agents-${agent}/memory"
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

## Lessons candidates
(ONLY if this session contained a lesson-worthy event: a notable failure, a wrong assumption that got corrected, a repeated mistake, or a non-obvious discovery. 1-3 bullets, each phrased as a candidate GENERAL rule that would change future behavior — not a restatement of what happened. The nightly reflector reads these summaries and picks candidates up from this section. Omit the section entirely for routine sessions.)

## Entities
(wikilinks to the named people, projects, repos, companies, or products this session touched, for the knowledge graph. One per line, using [[type/slug]] form with a lowercase-kebab slug. Allowed types: project, company, person, deal, repo. Examples: [[project/billing-migration]], [[company/acme]], [[person/jane-doe]], [[repo/session-warden]]. Only real named entities, max 8. Omit the section entirely if none.)

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
  file_size=$(stat_size "$mem_file")
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
  compacted=$(timeout 60 claude -p --model "$MEMORY_MODEL" "Compact this session memory file to ~40% of its current length. Keep the frontmatter block (--- to ---) exactly as-is. Preserve concrete details (paths, branches, decisions). Drop completed items. Keep pending items and context.

${content}" 2>/dev/null)

  # Only overwrite if the result is plausibly a compaction: non-trivial length
  # and actually smaller than the original. A timeout, refusal, or one-line
  # apology must never clobber real memory.
  local compacted_words original_bytes compacted_bytes
  compacted_words=$(echo "$compacted" | wc -w)
  original_bytes=${#content}
  compacted_bytes=${#compacted}
  if [ -z "$compacted" ] || [ "$compacted_words" -lt 30 ] || [ "$compacted_bytes" -ge "$original_bytes" ]; then
    log "MEMORY: compaction rejected (${compacted_words} words, ${compacted_bytes}B vs ${original_bytes}B) — keeping original"
    return 1
  fi
  echo "$compacted" > "$mem_file"
}

# Write $2 to $1 only if the content differs, ignoring the timestamp line.
#
# These files are part of the agent's system prompt, and context-sync rewrites
# them every few minutes. Any changed byte invalidates the provider's cached
# prefix from that point on, so stamping a fresh time when nothing else moved
# costs a full prefix re-write and buys nothing. Returns 0 if written, 1 if the
# file was left alone.
write_if_content_changed() {
  local file="$1" content="$2" cur new
  # Blank the clock but keep the rest of the header — session id and channel
  # live on that line too, and a change in either is a real change.
  local strip='s/^(_(Last updated|Updated): )[^|]*/\1<ts>/'
  if [ -f "$file" ]; then
    cur=$(sed -E "$strip" "$file")
    new=$(printf '%s' "$content" | sed -E "$strip")
    [ "$cur" = "$new" ] && return 1
  fi
  printf '%s' "$content" > "$file"
  return 0
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
  # Include crash buffer if it exists (unprocessed messages from before the crash)
  local crash_buffer_content=""
  if type read_crash_buffer &>/dev/null; then
    crash_buffer_content=$(read_crash_buffer "$agent" "$channel_key")
  fi

  local context_content
  context_content="_Last updated: ${ts} | Session: ${cli_session_id} | Channel: ${channel_key}_

${summary}
"
  if [ -n "$crash_buffer_content" ]; then
    context_content="${context_content}
${crash_buffer_content}
"
  fi

  if write_if_content_changed "$context_file" "$context_content"; then
    log "MEMORY: wrote CONTEXT.md for $agent ($(stat_size "$context_file") bytes, crash_buffer=$([ -n "$crash_buffer_content" ] && echo "yes" || echo "no"))"
  else
    log "MEMORY: CONTEXT.md unchanged for $agent — left alone to keep the prompt cache warm"
  fi

  # 2. Inject into workspace MEMORY.md (bootstrap loads this into system prompt)
  local existing=""
  if [ -f "$memory_file" ]; then
    # Strip any previous auto-injected sections between markers
    existing=$(awk '
      /^<!-- SESSION-WARDEN-START -->/{skip=1; next}
      /^<!-- SESSION-WARDEN-END -->/{skip=0; next}
      /^<!-- CRASH-BUFFER-START -->/{skip=1; next}
      /^<!-- CRASH-BUFFER-END -->/{skip=0; next}
      !skip{print}
    ' "$memory_file")
  fi

  # Build crash buffer block for MEMORY.md
  local crash_buffer_block=""
  if [ -n "$crash_buffer_content" ]; then
    crash_buffer_block="<!-- CRASH-BUFFER-START -->
${crash_buffer_content}
<!-- CRASH-BUFFER-END -->

"
  fi

  # The injected block goes AFTER the agent's own memory, not before it. A
  # prompt cache is invalidated from the first differing byte onward, so
  # anything above this block survives a re-write and anything below it does
  # not. This block is the only part that changes every few minutes, so it is
  # the last thing in the file. Existing files migrate on their next write.
  local memory_content=""
  if [ -n "$existing" ]; then
    memory_content="${existing}

"
  fi
  memory_content="${memory_content}${crash_buffer_block}<!-- SESSION-WARDEN-START -->
## Previous Session Context (auto-injected by session-warden, do not edit this section)

_Updated: ${ts} | Channel: ${channel_key}_

${summary}

<!-- SESSION-WARDEN-END -->
"

  if write_if_content_changed "$memory_file" "$memory_content"; then
    log "MEMORY: injected context into workspace MEMORY.md for $agent"
  else
    log "MEMORY: MEMORY.md unchanged for $agent — left alone to keep the prompt cache warm"
  fi
  return 0
}
