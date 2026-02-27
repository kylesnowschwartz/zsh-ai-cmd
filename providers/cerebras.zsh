# providers/cerebras.zsh - Cerebras API provider
# OpenAI-compatible Chat Completions endpoint

typeset -g ZSH_AI_CMD_CEREBRAS_MODEL=${ZSH_AI_CMD_CEREBRAS_MODEL:-'gpt-oss-120b'}
typeset -g ZSH_AI_CMD_CEREBRAS_BASE_URL=${ZSH_AI_CMD_CEREBRAS_BASE_URL:-'https://api.cerebras.ai/v1/chat/completions'}

_zsh_ai_cmd_cerebras_call() {
  local input=$1
  local prompt=$2

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_CEREBRAS_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    '{
      model: $model,
      stream: false,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ],
      temperature: 0,
      top_p: 1,
      seed: 0
    }')

  local response
  response=$(command curl -sS --max-time 30 "$ZSH_AI_CMD_CEREBRAS_BASE_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $CEREBRAS_API_KEY" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [cerebras] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response" 2>/dev/null || print -r -- "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Check for API error
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re '.error.message // empty' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [cerebras]: $error_msg"
    return 1
  fi

  # Extract content from response
  print -r -- "$response" | command jq -re '.choices[0].message.content // empty' 2>/dev/null
}

_zsh_ai_cmd_cerebras_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: CEREBRAS_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export CEREBRAS_API_KEY='...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'cerebras-api-key' -a '\$USER' -w '...'"
  print -u2 ""
  print -u2 "Current configuration:"
  print -u2 "  Model: $ZSH_AI_CMD_CEREBRAS_MODEL"
  print -u2 "  Base URL: $ZSH_AI_CMD_CEREBRAS_BASE_URL"
}
