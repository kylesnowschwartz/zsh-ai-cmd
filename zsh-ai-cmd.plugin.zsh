#!/usr/bin/env zsh
# zsh-ai-cmd.plugin.zsh - AI shell suggestions with ghost text
# Ctrl+Z to request suggestion, Tab to accept, keep typing to refine
# External deps: curl, jq, security (macOS Keychain)

# Prevent double-loading (creates nested widget wrappers)
(( ${+functions[_zsh_ai_cmd_suggest]} )) && return

# ============================================================================
# Configuration
# ============================================================================
typeset -g ZSH_AI_CMD_KEY=${ZSH_AI_CMD_KEY:-'^z'}
typeset -g ZSH_AI_CMD_DEBUG=${ZSH_AI_CMD_DEBUG:-false}
typeset -g ZSH_AI_CMD_MODEL=${ZSH_AI_CMD_MODEL:-'claude-haiku-4-5-20251001'}
typeset -g ZSH_AI_CMD_LOG=${ZSH_AI_CMD_LOG:-/tmp/zsh-ai-cmd.log}

# ============================================================================
# Internal State
# ============================================================================
typeset -g _ZSH_AI_CMD_SUGGESTION=""

# OS detection (lazy-loaded on first API call)
typeset -g _ZSH_AI_CMD_OS=""

# ============================================================================
# Security: Sanitize model output
# ============================================================================

_zsh_ai_cmd_sanitize() {
  setopt local_options extended_glob
  local input=$1
  local sanitized=$input
  local esc=$'\x1b'

  # Security sanitization for model output
  # Prevents: newline injection, terminal escape attacks, control char manipulation

  # 1. Strip ANSI CSI escape sequences FIRST: ESC [ params letter
  #    Must happen before control char stripping or ESC gets removed separately
  while [[ $sanitized == *${esc}\[* ]]; do
    sanitized=${sanitized//${esc}\[[0-9;]#[A-Za-z]/}
  done

  # 2. Strip any remaining ESC characters (non-CSI escapes)
  sanitized=${sanitized//${esc}/}

  # 3. Strip control characters (0x00-0x1F except tab 0x09, and DEL 0x7F)
  #    Now safe to remove remaining control chars including orphaned brackets
  sanitized=${sanitized//[$'\x00'-$'\x08'$'\x0a'-$'\x1f'$'\x7f']/}

  # 4. Trim leading/trailing whitespace
  sanitized=${sanitized##[[:space:]]##}
  sanitized=${sanitized%%[[:space:]]##}

  print -r -- "$sanitized"
}

# ============================================================================
# System Prompt (sourced from shared file)
# ============================================================================
source "${0:a:h}/prompt.zsh"

# ============================================================================
# Ghost Text Display
# ============================================================================

_zsh_ai_cmd_show_ghost() {
  local suggestion=$1
  [[ $ZSH_AI_CMD_DEBUG == true ]] && print -- "show_ghost: suggestion='$suggestion' BUFFER='$BUFFER'" >> $ZSH_AI_CMD_LOG

  if [[ -n $suggestion && $suggestion != $BUFFER ]]; then
    if [[ $suggestion == ${BUFFER}* ]]; then
      # Suggestion is completion of current buffer - show suffix
      POSTDISPLAY="${suggestion#$BUFFER}"
    else
      # Suggestion is different - show with tab hint
      POSTDISPLAY="  ⇥  ${suggestion}"
    fi
    # Apply grey highlighting via region_highlight (like zsh-autosuggestions)
    local start=$#BUFFER
    local end=$(( start + $#POSTDISPLAY ))
    region_highlight+=("$start $end fg=8")
    [[ $ZSH_AI_CMD_DEBUG == true ]] && print -- "show_ghost: POSTDISPLAY='$POSTDISPLAY'" >> $ZSH_AI_CMD_LOG
  else
    POSTDISPLAY=""
  fi
}

_zsh_ai_cmd_clear_ghost() {
  POSTDISPLAY=""
  _ZSH_AI_CMD_SUGGESTION=""
  # Remove our highlight (filter out any fg=8 entries we added)
  region_highlight=("${(@)region_highlight:#*fg=8}")
}

_zsh_ai_cmd_update_ghost_on_edit() {
  [[ -z $_ZSH_AI_CMD_SUGGESTION ]] && return
  if [[ $_ZSH_AI_CMD_SUGGESTION == ${BUFFER}* ]]; then
    _zsh_ai_cmd_show_ghost "$_ZSH_AI_CMD_SUGGESTION"
  else
    _zsh_ai_cmd_clear_ghost
  fi
}

# ============================================================================
# API Call (synchronous with spinner - runs in widget context)
# ============================================================================

_zsh_ai_cmd_call_api() {
  local input=$1

  # Lazy OS detection (avoids sw_vers on every shell startup)
  if [[ -z $_ZSH_AI_CMD_OS ]]; then
    if [[ $OSTYPE == darwin* ]]; then
      _ZSH_AI_CMD_OS="macOS $(sw_vers -productVersion 2>/dev/null || print 'unknown')"
    else
      _ZSH_AI_CMD_OS="Linux"
    fi
  fi

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
      max_tokens: 256,
      system: $system,
      messages: [{role: "user", content: $content}],
      output_format: {type: "json_schema", schema: $schema}
    }')

  local response
  response=$(command curl -sS --max-time 30 "https://api.anthropic.com/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: structured-outputs-2025-11-13" \
    -d "$payload" 2>/dev/null)

  # Debug log (full request/response for inspection)
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Extract command from structured output
  print -r -- "$response" | command jq -re '.content[0].text | fromjson | .command // empty' 2>/dev/null
}

# ============================================================================
# Main Widget: Ctrl+Z to request suggestion
# ============================================================================

_zsh_ai_cmd_suggest() {
  [[ -z $BUFFER ]] && return

  _zsh_ai_cmd_get_key || { BUFFER=""; zle accept-line; return 1; }

  # Show spinner
  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  # Start API call in background (suppress job control noise)
  local tmpfile=$(mktemp)
  setopt local_options no_notify no_monitor
  ( _zsh_ai_cmd_call_api "$BUFFER" > "$tmpfile" ) &!
  local pid=$!

  # Animate spinner while waiting
  while kill -0 $pid 2>/dev/null; do
    POSTDISPLAY=" ${spinner:$((i % 10)):1}"
    zle -R
    read -t 0.1 -k 1 && { kill $pid 2>/dev/null; POSTDISPLAY=""; rm -f "$tmpfile"; return; }
    ((i++))
  done
  wait $pid 2>/dev/null

  # Read and sanitize result (security: strip control chars, newlines, escapes)
  local suggestion
  suggestion=$(_zsh_ai_cmd_sanitize "$(<"$tmpfile")")
  rm -f "$tmpfile"

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

_zsh_ai_cmd_self_insert() {
  zle .self-insert
  _zsh_ai_cmd_update_ghost_on_edit
}

_zsh_ai_cmd_backward_delete_char() {
  zle .backward-delete-char
  _zsh_ai_cmd_update_ghost_on_edit
}

_zsh_ai_cmd_forward_char() {
  _zsh_ai_cmd_clear_ghost
  zle .forward-char
}

# ============================================================================
# Line Lifecycle
# ============================================================================

_zsh_ai_cmd_line_finish() {
  _zsh_ai_cmd_clear_ghost
}

# ============================================================================
# Widget Registration
# ============================================================================

zle -N zle-line-finish _zsh_ai_cmd_line_finish
zle -N self-insert _zsh_ai_cmd_self_insert
zle -N backward-delete-char _zsh_ai_cmd_backward_delete_char
zle -N _zsh_ai_cmd_forward_char
zle -N _zsh_ai_cmd_suggest
zle -N _zsh_ai_cmd_accept

bindkey "$ZSH_AI_CMD_KEY" _zsh_ai_cmd_suggest
bindkey '^I' _zsh_ai_cmd_accept
bindkey '^[[C' _zsh_ai_cmd_forward_char  # Right arrow - clear ghost, move cursor

# ============================================================================
# API Key Management
# ============================================================================

_zsh_ai_cmd_get_key() {
  [[ -n $ANTHROPIC_API_KEY ]] && return 0
  ANTHROPIC_API_KEY=$(security find-generic-password \
    -s "anthropic-api-key" -a "$USER" -w 2>/dev/null) || {
    print -u2 ""
    print -u2 "zsh-ai-cmd: ANTHROPIC_API_KEY not found"
    print -u2 ""
    print -u2 "Set it via environment variable:"
    print -u2 "  export ANTHROPIC_API_KEY='sk-ant-...'"
    print -u2 ""
    print -u2 "Or store in macOS Keychain:"
    print -u2 "  security add-generic-password -s 'anthropic-api-key' -a '\$USER' -w 'sk-ant-...'"
    return 1
  }
}
