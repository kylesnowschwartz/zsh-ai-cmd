# providers/anthropic.zsh - Anthropic Claude API provider
# Uses structured outputs with JSON schema for reliable command extraction

typeset -g ZSH_AI_CMD_ANTHROPIC_MODEL=${ZSH_AI_CMD_ANTHROPIC_MODEL:-'claude-haiku-4-5-20251001'}

_zsh_ai_cmd_anthropic_call() {
  local input=$1
  local prompt=$2"$_ZSH_AI_CMD_PROMPT_STRUCTURED"

  # max_tokens sized for the full structured payload: primary + 2 alternatives
  # of long commands (ffmpeg/rsync pipelines) plus JSON scaffolding
  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_ANTHROPIC_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    --argjson schema "$_ZSH_AI_CMD_SCHEMA" \
    '{
      model: $model,
      max_tokens: 1024,
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

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [anthropic] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Check for API error (Anthropic format: {"error": {"message": "..."}})
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re '.error.message // empty' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [anthropic]: $error_msg"
    return 1
  fi

  # Extract suggestions from structured output (wire format: D/S<TAB>command per line)
  print -r -- "$response" | command jq -re ".content[0].text | fromjson | $_ZSH_AI_CMD_JQ_EMIT" 2>/dev/null
}

_zsh_ai_cmd_anthropic_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: ANTHROPIC_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export ANTHROPIC_API_KEY='sk-ant-...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'anthropic-api-key' -a '\$USER' -w 'sk-ant-...'"
}
