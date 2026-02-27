# providers/openrouter.zsh - OpenRouter API provider
# OpenRouter provides a unified API for multiple LLM providers
# Uses OpenAI-compatible format

typeset -g ZSH_AI_CMD_OPENROUTER_MODEL=${ZSH_AI_CMD_OPENROUTER_MODEL:-'openai/gpt-oss-120b:free'}
typeset -g ZSH_AI_CMD_OPENROUTER_BASE_URL=${ZSH_AI_CMD_OPENROUTER_BASE_URL:-'https://openrouter.ai/api/v1/chat/completions'}

_zsh_ai_cmd_openrouter_call() {
  local input=$1
  local prompt=$2

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_OPENROUTER_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ]
    }')

  local response
  response=$(command curl -sS --max-time 30 "$ZSH_AI_CMD_OPENROUTER_BASE_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "HTTP-Referer: https://github.com/npv12/zsh-ai-cmd" \
    -H "X-Title: zsh-ai-cmd" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [openrouter] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response" 2>/dev/null || print -r -- "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Check for API error (OpenRouter format: {"error": {"message": "..."}})
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re '.error.message // empty' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [openrouter]: $error_msg"
    return 1
  fi

  # Extract content from response
  print -r -- "$response" | command jq -re '.choices[0].message.content // empty' 2>/dev/null
}

_zsh_ai_cmd_openrouter_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: OPENROUTER_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export OPENROUTER_API_KEY='sk-or-v1-...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'openrouter-api-key' -a '\$USER' -w 'sk-or-v1-...'"
  print -u2 ""
  print -u2 "Get your API key at: https://openrouter.ai/keys"
}
