# providers/nvidia.zsh - NVIDIA NIM API provider
# OpenAI-compatible API endpoint for NVIDIA-hosted models
# Uses guided_json for structured outputs

typeset -g ZSH_AI_CMD_NVIDIA_MODEL=${ZSH_AI_CMD_NVIDIA_MODEL:-'openai/gpt-oss-120b'}
typeset -g ZSH_AI_CMD_NVIDIA_BASE_URL=${ZSH_AI_CMD_NVIDIA_BASE_URL:-'https://integrate.api.nvidia.com/v1/chat/completions'}

_zsh_ai_cmd_nvidia_call() {
  local input=$1
  local prompt=$2

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_NVIDIA_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ],
      extra_body: {
        guided_json: {
          type: "object",
          properties: {
            command: {type: "string", description: "The shell command"}
          },
          required: ["command"],
          additionalProperties: false
        }
      }
    }')

  local response
  response=$(command curl -sS --max-time 30 "$ZSH_AI_CMD_NVIDIA_BASE_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $NVIDIA_API_KEY" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [nvidia] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response" 2>/dev/null || print -r -- "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Check for API error (NVIDIA/OpenAI format: {"error": {"message": "..."}})
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re '.error.message // empty' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [nvidia]: $error_msg"
    return 1
  fi

  # Extract content from response
  # NVIDIA returns JSON with literal newlines inside string values (invalid JSON)
  local content
  content=$(print -r -- "$response" | command jq -r '.choices[0].message.content // empty' 2>/dev/null)

  # Debug: log what we extracted
  [[ $ZSH_AI_CMD_DEBUG == true ]] && {
    print -- "[nvidia] extracted content: $content" >> $ZSH_AI_CMD_LOG
  }

  local escaped_content
  escaped_content=$(print -r -- "$content" | command sed 's/\n/\\n/g')
  print -r -- "$escaped_content"
}

_zsh_ai_cmd_nvidia_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: NVIDIA_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export NVIDIA_API_KEY='nvapi-...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'nvidia-api-key' -a '\$USER' -w 'nvapi-...'"
  print -u2 ""
  print -u2 "Get your API key at: https://build.nvidia.com"
  print -u2 ""
  print -u2 "Current configuration:"
  print -u2 "  Model: $ZSH_AI_CMD_NVIDIA_MODEL"
  print -u2 "  Base URL: $ZSH_AI_CMD_NVIDIA_BASE_URL"
}
