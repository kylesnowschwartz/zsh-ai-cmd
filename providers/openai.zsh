# providers/openai.zsh - OpenAI API provider
# Uses structured outputs with JSON schema for reliable command extraction

typeset -g ZSH_AI_CMD_OPENAI_MODEL=${ZSH_AI_CMD_OPENAI_MODEL:-'gpt-5.2-2025-12-11'}
# Note: OPENAI_API_KEY is sent as Authorization header to this endpoint
typeset -g ZSH_AI_CMD_OPENAI_BASE_URL=${ZSH_AI_CMD_OPENAI_BASE_URL:-'https://api.openai.com/v1/chat/completions'}

_zsh_ai_cmd_openai_call() {
  local input=$1
  local prompt=$2"$_ZSH_AI_CMD_PROMPT_STRUCTURED"

  # max_completion_tokens sized for primary + 2 alternatives of long commands
  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_OPENAI_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    --argjson schema "$_ZSH_AI_CMD_SCHEMA" \
    '{
      model: $model,
      max_completion_tokens: 1024,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ],
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "shell_command",
          schema: $schema,
          strict: true
        }
      }
    }')

  local response
  response=$(command curl -sS --max-time 30 "$ZSH_AI_CMD_OPENAI_BASE_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [openai] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Check for API error (OpenAI format: {"error": {"message": "..."}})
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re '.error.message // empty' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [openai]: $error_msg"
    return 1
  fi

  # Extract suggestions from response (wire format: D/S<TAB>command per line)
  print -r -- "$response" | command jq -re ".choices[0].message.content | fromjson | $_ZSH_AI_CMD_JQ_EMIT" 2>/dev/null
}

_zsh_ai_cmd_openai_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: OPENAI_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export OPENAI_API_KEY='sk-...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'openai-api-key' -a '\$USER' -w 'sk-...'"
}
