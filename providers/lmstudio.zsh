# providers/lmstudio.zsh - LM Studio local inference provider
# No API key required, runs locally. 

typeset -g ZSH_AI_CMD_LMSTUDIO_MODEL=${ZSH_AI_CMD_LMSTUDIO_MODEL:-'meta-llama-3-8b-instruct'}
typeset -g ZSH_AI_CMD_LMSTUDIO_HOST=${ZSH_AI_CMD_LMSTUDIO_HOST:-'localhost:1234'}

_zsh_ai_cmd_lmstudio_key_error() {
  print "Error: LM Studio provider configurations missing." >&2
  print "Ensure ZSH_AI_CMD_LMSTUDIO_HOST is correct." >&2
  return 1
}

_zsh_ai_cmd_lmstudio_available() {
  if [[ -z "$ZSH_AI_CMD_LMSTUDIO_HOST" ]]; then
    return 1
  fi

  command curl -s -m 2 "http://$ZSH_AI_CMD_LMSTUDIO_HOST/v1/models" >/dev/null 2>&1
}

_zsh_ai_cmd_lmstudio_call() {
  local input="$1"
  local prompt="$2"

  if [[ -z "$ZSH_AI_CMD_LMSTUDIO_HOST" ]]; then
    _zsh_ai_cmd_lmstudio_key_error
    return 1
  fi

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_LMSTUDIO_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
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
          schema: {
            type: "object",
            properties: {
              command: {type: "string", description: "The shell command"}
            },
            required: ["command"],
            additionalProperties: false
          }
        }
      }
    }')

  local response
  response=$(command curl -sS \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "http://$ZSH_AI_CMD_LMSTUDIO_HOST/v1/chat/completions" 2>/dev/null)

  if [[ $? -ne 0 || -z "$response" ]]; then
    print "Error: Failed to connect to LM Studio at $ZSH_AI_CMD_LMSTUDIO_HOST" >&2
    return 1
  fi

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

  local command_output
  command_output=$(print "$response" | command jq -r '.choices[0].message.content // empty' 2>/dev/null)

  print -r -- "$response" | command jq -re '.choices[0].message.content | fromjson | .command // empty' 2>/dev/null
}
