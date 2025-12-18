#!/usr/bin/env zsh
# zsh-ai-cmd.plugin.zsh - AI shell suggestions with ghost text
# Ctrl+Z to request suggestion, Tab to accept, keep typing to refine
# External deps: curl, jq, security (macOS Keychain)

# ============================================================================
# Configuration
# ============================================================================
typeset -g ZSH_AI_CMD_DEBUG=${ZSH_AI_CMD_DEBUG:-false}
typeset -g ZSH_AI_CMD_MODEL=${ZSH_AI_CMD_MODEL:-'claude-haiku-4-5-20251001'}

# ============================================================================
# Internal State
# ============================================================================
typeset -g _ZSH_AI_CMD_SUGGESTION=""
typeset -g _ZSH_AI_CMD_ORIGINAL_BUFFER=""

# Cache OS at load time
typeset -g _ZSH_AI_CMD_OS
if [[ $OSTYPE == darwin* ]]; then
  _ZSH_AI_CMD_OS="macOS $(sw_vers -productVersion 2>/dev/null || print 'unknown')"
else
  _ZSH_AI_CMD_OS="Linux"
fi

# ============================================================================
# System Prompt
# ============================================================================
typeset -g _ZSH_AI_CMD_PROMPT='Complete the user intent as a shell command.

RULES:
- Output EXACTLY ONE command, nothing else
- Complete partial intents speculatively
- If input looks like a command already, output it unchanged
- If input is natural language, translate to shell
- Prefix standard tools with `command` to bypass aliases

<examples>
User: list files
command ls -la

User: find py
command find . -name "*.py"

User: git st
git status

User: show disk
command df -h

User: kill port 3000
command lsof -ti:3000 | xargs kill -9

User: grep TODO
command grep -r "TODO" .
</examples>'

typeset -g _ZSH_AI_CMD_CONTEXT='<context>
OS: $_ZSH_AI_CMD_OS
Shell: ${SHELL:t}
PWD: $PWD
</context>'

# ============================================================================
# Ghost Text Display
# ============================================================================

_zsh_ai_cmd_show_ghost() {
  local suggestion=$1
  [[ $ZSH_AI_CMD_DEBUG == true ]] && print -- "show_ghost: suggestion='$suggestion' BUFFER='$BUFFER'" >> /tmp/zsh-ai-cmd.log

  if [[ -n $suggestion && $suggestion != $BUFFER ]]; then
    if [[ $suggestion == ${BUFFER}* ]]; then
      # Suggestion is completion of current buffer - show suffix
      POSTDISPLAY="${suggestion#$BUFFER}"
    else
      # Suggestion is different - show with arrow
      POSTDISPLAY=" → $suggestion"
    fi
    [[ $ZSH_AI_CMD_DEBUG == true ]] && print -- "show_ghost: POSTDISPLAY='$POSTDISPLAY'" >> /tmp/zsh-ai-cmd.log
  else
    POSTDISPLAY=""
  fi
}

_zsh_ai_cmd_clear_ghost() {
  POSTDISPLAY=""
  _ZSH_AI_CMD_SUGGESTION=""
  _ZSH_AI_CMD_ORIGINAL_BUFFER=""
}

# ============================================================================
# API Call (synchronous with spinner - runs in widget context)
# ============================================================================

_zsh_ai_cmd_call_api() {
  local input=$1

  local context="${(e)_ZSH_AI_CMD_CONTEXT}"
  local prompt="${_ZSH_AI_CMD_PROMPT}"$'\n'"${context}"

  local schema='{
    "type": "object",
    "properties": {
      "command": {"type": "string", "description": "The shell command"}
    },
    "required": ["command"],
    "additionalProperties": false
  }'

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    --argjson schema "$schema" \
    '{
      model: $model,
      max_tokens: 128,
      system: $system,
      messages: [{role: "user", content: $content}],
      output_format: {type: "json_schema", schema: $schema}
    }')

  local response
  response=$(command curl -sS --max-time 10 "https://api.anthropic.com/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: structured-outputs-2025-11-13" \
    -d "$payload" 2>/dev/null)

  # Extract command from structured output
  print -r -- "$response" | command jq -re '.content[0].text | fromjson | .command // empty' 2>/dev/null
}

# ============================================================================
# Main Widget: Ctrl+Z to request suggestion
# ============================================================================

_zsh_ai_cmd_suggest() {
  [[ -z $BUFFER ]] && return

  _zsh_ai_cmd_get_key || {
    zle -M "zsh-ai-cmd: API key not found"
    return 1
  }

  # Save original buffer
  _ZSH_AI_CMD_ORIGINAL_BUFFER=$BUFFER

  # Show spinner
  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  # Start API call in background
  local tmpfile=$(mktemp)
  ( _zsh_ai_cmd_call_api "$BUFFER" > "$tmpfile" ) &
  local pid=$!

  # Animate spinner while waiting
  while kill -0 $pid 2>/dev/null; do
    POSTDISPLAY=" ${spinner:$((i % 10)):1}"
    zle -R
    read -t 0.1 -k 1 && { kill $pid 2>/dev/null; POSTDISPLAY=""; rm -f "$tmpfile"; return; }
    ((i++))
  done
  wait $pid

  # Read result
  local suggestion=$(<"$tmpfile")
  rm -f "$tmpfile"

  [[ $ZSH_AI_CMD_DEBUG == true ]] && print -- "suggest: got '$suggestion'" >> /tmp/zsh-ai-cmd.log

  if [[ -n $suggestion ]]; then
    _ZSH_AI_CMD_SUGGESTION=$suggestion
    _zsh_ai_cmd_show_ghost "$suggestion"
    zle -R
  else
    POSTDISPLAY=""
    zle -M "zsh-ai-cmd: no suggestion"
  fi
}

# ============================================================================
# Accept/Reject Handling
# ============================================================================

_zsh_ai_cmd_accept() {
  if [[ -n $_ZSH_AI_CMD_SUGGESTION ]]; then
    BUFFER=$_ZSH_AI_CMD_SUGGESTION
    CURSOR=$#BUFFER
    _zsh_ai_cmd_clear_ghost
  else
    zle expand-or-complete
  fi
}

# Wrapper for self-insert: typing clears ghost or refines
_zsh_ai_cmd_self_insert() {
  zle .self-insert

  # If we have a suggestion, update ghost based on new buffer
  if [[ -n $_ZSH_AI_CMD_SUGGESTION ]]; then
    if [[ $_ZSH_AI_CMD_SUGGESTION == ${BUFFER}* ]]; then
      # User is typing toward the suggestion - update ghost
      _zsh_ai_cmd_show_ghost "$_ZSH_AI_CMD_SUGGESTION"
    else
      # User diverged - clear ghost
      _zsh_ai_cmd_clear_ghost
    fi
  fi
}

_zsh_ai_cmd_backward_delete_char() {
  zle .backward-delete-char

  if [[ -n $_ZSH_AI_CMD_SUGGESTION ]]; then
    if [[ $_ZSH_AI_CMD_SUGGESTION == ${BUFFER}* ]]; then
      _zsh_ai_cmd_show_ghost "$_ZSH_AI_CMD_SUGGESTION"
    else
      _zsh_ai_cmd_clear_ghost
    fi
  fi
}

# ============================================================================
# Line Lifecycle
# ============================================================================

_zsh_ai_cmd_line_init() {
  _zsh_ai_cmd_clear_ghost
}

_zsh_ai_cmd_line_finish() {
  _zsh_ai_cmd_clear_ghost
}

# ============================================================================
# Widget Registration
# ============================================================================

zle -N zle-line-init _zsh_ai_cmd_line_init
zle -N zle-line-finish _zsh_ai_cmd_line_finish
zle -N self-insert _zsh_ai_cmd_self_insert
zle -N backward-delete-char _zsh_ai_cmd_backward_delete_char
zle -N _zsh_ai_cmd_suggest
zle -N _zsh_ai_cmd_accept

bindkey '^Z' _zsh_ai_cmd_suggest
bindkey '^I' _zsh_ai_cmd_accept

# ============================================================================
# API Key Management
# ============================================================================

_zsh_ai_cmd_get_key() {
  [[ -n $ANTHROPIC_API_KEY ]] && return 0
  ANTHROPIC_API_KEY=$(security find-generic-password \
    -s "anthropic-api-key" -a "$USER" -w 2>/dev/null) || return 1
}
