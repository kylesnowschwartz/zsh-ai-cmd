# providers/ollama.zsh - Ollama local inference provider
# No API key required, runs locally. Uses structured outputs since Ollama v0.5.

typeset -g ZSH_AI_CMD_OLLAMA_MODEL=${ZSH_AI_CMD_OLLAMA_MODEL:-'mistral-small'}
typeset -g ZSH_AI_CMD_OLLAMA_HOST=${ZSH_AI_CMD_OLLAMA_HOST:-'localhost:11434'}

_zsh_ai_cmd_ollama_call() {
  local input=$1
  local prompt=$2

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_OLLAMA_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ],
      stream: false,
      format: {
        type: "object",
        properties: {
          command: {type: "string", description: "The shell command"}
        },
        required: ["command"]
      }
    }')

  local response
  response=$(command curl -sS --max-time 60 "http://${ZSH_AI_CMD_OLLAMA_HOST}/api/chat" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [ollama] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Extract command - structured output ensures valid JSON in .message.content
  local content
  content=$(print -r -- "$response" | command jq -re '.message.content // empty' 2>/dev/null)
  [[ -z $content ]] && return 1

  # Parse JSON - structured output should guarantee valid JSON
  print -r -- "$content" | command jq -re '.command // empty' 2>/dev/null && return 0

  # Fallback: extract with sed if JSON parsing fails (older Ollama versions)
  local cmd
  cmd=$(print -r -- "$content" | command sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)
  [[ -n $cmd ]] && { print -r -- "$cmd"; return 0; }
}

_zsh_ai_cmd_ollama_key_error() {
  # Ollama doesn't need a key, but the server must be running
  print -u2 ""
  print -u2 "zsh-ai-cmd: Cannot connect to Ollama at ${ZSH_AI_CMD_OLLAMA_HOST}"
  print -u2 ""
  print -u2 "Make sure Ollama is installed and running:"
  print -u2 "  brew install ollama"
  print -u2 "  ollama serve"
  print -u2 ""
  print -u2 "Or set a custom host:"
  print -u2 "  export ZSH_AI_CMD_OLLAMA_HOST='192.168.1.100:11434'"
}

# Check if Ollama is available (used for validation)
_zsh_ai_cmd_ollama_available() {
  command curl -sS --max-time 2 "http://${ZSH_AI_CMD_OLLAMA_HOST}/api/tags" >/dev/null 2>&1
}
