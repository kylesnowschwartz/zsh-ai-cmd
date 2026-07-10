# providers/lmstudio.zsh - LM Studio local inference provider
# No API key required, runs locally.

typeset -g ZSH_AI_CMD_LMSTUDIO_MODEL=${ZSH_AI_CMD_LMSTUDIO_MODEL:-'qwen2.5-coder-7b-instruct'}
typeset -g ZSH_AI_CMD_LMSTUDIO_HOST=${ZSH_AI_CMD_LMSTUDIO_HOST:-'localhost:1234'}

_zsh_ai_cmd_lmstudio_key_error() {
  print -u2 "Error: LM Studio provider configurations missing."
  print -u2 "Ensure ZSH_AI_CMD_LMSTUDIO_HOST is correct."
  return 1
}

_zsh_ai_cmd_lmstudio_available() {
  if [[ -z "$ZSH_AI_CMD_LMSTUDIO_HOST" ]]; then
    return 1
  fi

  command curl -sS --max-time 2 "http://$ZSH_AI_CMD_LMSTUDIO_HOST/v1/models" >/dev/null 2>&1
}

_zsh_ai_cmd_lmstudio_call() {
  local input="$1"
  local prompt="$2$_ZSH_AI_CMD_PROMPT_STRUCTURED"

  if [[ -z "$ZSH_AI_CMD_LMSTUDIO_HOST" ]]; then
    _zsh_ai_cmd_lmstudio_key_error
    return 1
  fi

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_LMSTUDIO_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    --argjson schema "$_ZSH_AI_CMD_SCHEMA" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ],
      stream: false,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "shell_command",
          strict: true,
          schema: $schema
        }
      }
    }')

  local response
  response=$(command curl -sS --max-time 60 -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "http://$ZSH_AI_CMD_LMSTUDIO_HOST/v1/chat/completions" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [lmstudio] ==="
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
    print -u2 "zsh-ai-cmd [lmstudio]: $error_msg"
    return 1
  fi

  # Wire format: D/S<TAB>command per line
  _zsh_ai_cmd_extract "$response" '.choices[0].message.content'
}
