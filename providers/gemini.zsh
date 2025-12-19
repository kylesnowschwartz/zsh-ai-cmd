# providers/gemini.zsh - Google Gemini API provider
# Uses system_instruction for system prompt, structured outputs for JSON

typeset -g ZSH_AI_CMD_GEMINI_MODEL=${ZSH_AI_CMD_GEMINI_MODEL:-'gemini-2.5-flash'}

_zsh_ai_cmd_gemini_call() {
  local input=$1
  local prompt=$2

  local payload
  payload=$(command jq -nc \
    --arg system "$prompt" \
    --arg content "$input" \
    '{
      system_instruction: {
        parts: [{text: $system}]
      },
      contents: [{
        parts: [{text: $content}]
      }],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: {
          type: "object",
          properties: {
            command: {type: "string", description: "The shell command"}
          },
          required: ["command"]
        }
      }
    }')

  local response
  response=$(command curl -sS --max-time 30 \
    "https://generativelanguage.googleapis.com/v1beta/models/${ZSH_AI_CMD_GEMINI_MODEL}:generateContent" \
    -H "Content-Type: application/json" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [gemini] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Extract command from response (structured output ensures valid JSON)
  local content
  content=$(print -r -- "$response" | command jq -re '.candidates[0].content.parts[0].text // empty' 2>/dev/null)
  [[ -z $content ]] && return 1

  # Parse JSON - structured output should guarantee valid JSON
  print -r -- "$content" | command jq -re '.command // empty' 2>/dev/null && return 0

  # Fallback: extract with sed if JSON parsing fails
  local cmd
  cmd=$(print -r -- "$content" | command sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)
  [[ -n $cmd ]] && { print -r -- "$cmd"; return 0; }
}

_zsh_ai_cmd_gemini_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: GEMINI_API_KEY not found"
  print -u2 ""
  print -u2 "Get your API key from: https://aistudio.google.com/app/apikey"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export GEMINI_API_KEY='AI...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'gemini-api-key' -a '\$USER' -w 'AI...'"
}
