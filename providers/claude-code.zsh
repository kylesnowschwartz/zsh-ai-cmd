# providers/claude-code.zsh - Claude Code CLI provider (pipe mode)
# Uses Claude subscription (Max/Pro/Enterprise) instead of an API key.
# Requires Claude Code CLI: npm install -g @anthropic-ai/claude-code

# Empty default: uses the CLI's own default model. Override to pin a specific model.
typeset -g ZSH_AI_CMD_CLAUDE_CODE_MODEL=${ZSH_AI_CMD_CLAUDE_CODE_MODEL:-''}

_zsh_ai_cmd_claude_code_call() {
  local input=$1
  local prompt=$2

  # Text output mode is ~1.5x faster than JSON structured output because
  # --output-format json + --json-schema adds overhead to CLI startup.
  # The system prompt already enforces single-command output, matching
  # the approach used by the copilot provider.
  local -a cmd=(command claude -p
    --no-session-persistence
    --effort low
    --disable-slash-commands
    --strict-mcp-config
    --setting-sources ""
    --no-chrome
    --tools ""
    --system-prompt "$prompt"
  )
  [[ -n $ZSH_AI_CMD_CLAUDE_CODE_MODEL ]] && cmd+=(--model "$ZSH_AI_CMD_CLAUDE_CODE_MODEL")

  local response
  response=$("${cmd[@]}" "$input" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [claude-code] ==="
      print -- "--- REQUEST ---"
      print -- "Model: ${ZSH_AI_CMD_CLAUDE_CODE_MODEL:-default}"
      print -- "Input: $input"
      print -- "--- RESPONSE ---"
      print -- "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  [[ -z $response ]] && return 1

  # Text mode returns the command directly (no JSON to parse).
  # Error messages from the CLI are suppressed by 2>/dev/null above;
  # an empty response is the only failure signal.
  print -r -- "$response"
}

_zsh_ai_cmd_claude_code_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: Claude Code not found or not authenticated."
  print -u2 ""
  print -u2 "Install Claude Code:"
  print -u2 "  npm install -g @anthropic-ai/claude-code"
  print -u2 ""
  print -u2 "Then authenticate:"
  print -u2 "  claude login"
}
