# providers/copilot.zsh - GitHub Copilot via copilot-api proxy
# Uses OpenAI-compatible endpoint. No API key required (copilot-api handles GitHub OAuth).

typeset -g ZSH_AI_CMD_COPILOT_MODEL=${ZSH_AI_CMD_COPILOT_MODEL:-'gpt-4o'}
typeset -g ZSH_AI_CMD_COPILOT_HOST=${ZSH_AI_CMD_COPILOT_HOST:-'localhost:4141'}

_zsh_ai_cmd_copilot_call() {
  local input=$1
  local prompt=$2

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_COPILOT_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    '{
      model: $model,
      max_completion_tokens: 256,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ]
    }')

  local response
  response=$(command curl -sS --max-time 30 "http://${ZSH_AI_CMD_COPILOT_HOST}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [copilot] ==="
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
    print -u2 "zsh-ai-cmd [copilot]: $error_msg"
    return 1
  fi

  # Extract command from response
  # Try structured JSON first, fall back to plain text (copilot-api returns plain text)
  local content
  content=$(print -r -- "$response" | command jq -re '.choices[0].message.content // empty' 2>/dev/null)
  if [[ -n $content ]]; then
    print -r -- "$content" | command jq -re '.command // empty' 2>/dev/null || print -r -- "$content"
  fi
}

_zsh_ai_cmd_copilot_key_error() {
  # Copilot doesn't need an API key, but copilot-api server must be running
  print -u2 ""
  print -u2 "zsh-ai-cmd: Cannot connect to copilot-api at ${ZSH_AI_CMD_COPILOT_HOST}"
  print -u2 ""
  print -u2 "Make sure copilot-api is installed and running:"
  print -u2 "  npx copilot-api start"
  print -u2 ""
  print -u2 "Or set a custom host:"
  print -u2 "  export ZSH_AI_CMD_COPILOT_HOST='localhost:8080'"
  print -u2 ""
  print -u2 "Learn more: https://github.com/ericc-ch/copilot-api"
}

# Check if copilot-api is available (used for validation)
_zsh_ai_cmd_copilot_available() {
  command curl -sS --max-time 2 "http://${ZSH_AI_CMD_COPILOT_HOST}/v1/models" >/dev/null 2>&1
}
