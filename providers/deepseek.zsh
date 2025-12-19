# providers/deepseek.zsh - DeepSeek API provider
# OpenAI-compatible but only supports json_object mode (no json_schema)

typeset -g ZSH_AI_CMD_DEEPSEEK_MODEL=${ZSH_AI_CMD_DEEPSEEK_MODEL:-'deepseek-chat'}

_zsh_ai_cmd_deepseek_call() {
  local input=$1
  local prompt=$2

  # DeepSeek requires "json" in prompt when using json_object mode
  local json_prompt="$prompt

Respond with valid JSON only. Format: {\"command\": \"your shell command here\"}"

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_DEEPSEEK_MODEL" \
    --arg system "$json_prompt" \
    --arg content "$input" \
    '{
      model: $model,
      max_tokens: 256,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ],
      response_format: {type: "json_object"}
    }')

  local response
  response=$(command curl -sS --max-time 30 "https://api.deepseek.com/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [deepseek] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Extract command from response (OpenAI-compatible format)
  local content
  content=$(print -r -- "$response" | command jq -re '.choices[0].message.content // empty' 2>/dev/null)
  [[ -z $content ]] && return 1

  # Parse JSON
  print -r -- "$content" | command jq -re '.command // empty' 2>/dev/null && return 0

  # Fallback: extract with sed if JSON parsing fails
  local cmd
  cmd=$(print -r -- "$content" | command sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)
  [[ -n $cmd ]] && { print -r -- "$cmd"; return 0; }
}

_zsh_ai_cmd_deepseek_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: DEEPSEEK_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export DEEPSEEK_API_KEY='sk-...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'deepseek-api-key' -a '\$USER' -w 'sk-...'"
}
