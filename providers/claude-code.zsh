#!/usr/bin/env zsh
# claude-code.zsh - Provider using claude -p (Claude Code pipe mode)
# Uses Claude Max subscription instead of API key

typeset -g ZSH_AI_CMD_CLAUDE_CODE_MODEL=${ZSH_AI_CMD_CLAUDE_CODE_MODEL:-'haiku'}

_zsh_ai_cmd_claude_code_call() {
  local input=$1
  local prompt=$2

  local json_schema='{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}'

  local response
  response=$(command claude -p \
    --model "$ZSH_AI_CMD_CLAUDE_CODE_MODEL" \
    --tools "" \
    --output-format json \
    --json-schema "$json_schema" \
    --system-prompt "$prompt" \
    "$input" 2>/dev/null)

  [[ $ZSH_AI_CMD_DEBUG == true ]] && {
    print -- "=== $(date) [claude-code] ===" >> $ZSH_AI_CMD_LOG
    print -- "Input: $input" >> $ZSH_AI_CMD_LOG
    print -- "Response: $response" >> $ZSH_AI_CMD_LOG
  }

  # Check for error
  local is_error=$(print -r -- "$response" | command jq -r '.is_error // false' 2>/dev/null)
  if [[ $is_error == "true" ]]; then
    local error_msg=$(print -r -- "$response" | command jq -r '.result // "Unknown error"' 2>/dev/null)
    print -u2 "zsh-ai-cmd [claude-code]: $error_msg"
    return 1
  fi

  # Extract command from structured output
  print -r -- "$response" | command jq -r '.structured_output.command // empty' 2>/dev/null
}

_zsh_ai_cmd_claude_code_key_error() {
  print -u2 "zsh-ai-cmd: Claude Code not found or not authenticated."
  print -u2 ""
  print -u2 "Install Claude Code: npm install -g @anthropic-ai/claude-code"
  print -u2 "Then authenticate:   claude login"
}
