# providers/groq.zsh - Groq API provider
# OpenAI-compatible Chat Completions endpoint

typeset -g ZSH_AI_CMD_GROQ_MODEL=${ZSH_AI_CMD_GROQ_MODEL:-'llama-3.3-70b-versatile'}
typeset -g ZSH_AI_CMD_GROQ_BASE_URL=${ZSH_AI_CMD_GROQ_BASE_URL:-'https://api.groq.com/openai/v1/chat/completions'}

_zsh_ai_cmd_groq_call() {
  local input=$1
  local prompt=$2

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_GROQ_MODEL" \
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
  response=$(command curl -sS --max-time 30 "$ZSH_AI_CMD_GROQ_BASE_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [groq] ==="
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
    print -u2 "zsh-ai-cmd [groq]: $error_msg"
    return 1
  fi

  # Extract content from response
  print -r -- "$response" | command jq -re '.choices[0].message.content // empty' 2>/dev/null
}

_zsh_ai_cmd_groq_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: GROQ_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export GROQ_API_KEY='gsk_...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'groq-api-key' -a '\$USER' -w 'gsk_...'"
  print -u2 ""
  print -u2 "Current configuration:"
  print -u2 "  Model: $ZSH_AI_CMD_GROQ_MODEL"
  print -u2 "  Base URL: $ZSH_AI_CMD_GROQ_BASE_URL"
}
