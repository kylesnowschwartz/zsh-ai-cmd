# providers/gemini.zsh - Google Gemini API provider
# Uses system_instruction for system prompt, structured outputs for JSON

typeset -g ZSH_AI_CMD_GEMINI_MODEL=${ZSH_AI_CMD_GEMINI_MODEL:-'gemini-3-flash-preview'}

_zsh_ai_cmd_gemini_call() {
  local input=$1
  local prompt=$2"$_ZSH_AI_CMD_PROMPT_STRUCTURED"

  # Gemini's responseSchema dialect rejects additionalProperties — strip it
  # from the shared schema inside jq (recursive del, no extra fork)
  local payload
  payload=$(command jq -nc \
    --arg system "$prompt" \
    --arg content "$input" \
    --argjson schema "$_ZSH_AI_CMD_SCHEMA" \
    '{
      system_instruction: {
        parts: [{text: $system}]
      },
      contents: [{
        parts: [{text: $content}]
      }],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: ($schema | del(.. | .additionalProperties?))
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

  # Check for API error (Gemini format: {"error": {"message": "..."}})
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re '.error.message // empty' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [gemini]: $error_msg"
    return 1
  fi

  # Extract suggestions from response (wire format: D/S<TAB>command per line)
  _zsh_ai_cmd_extract "$response" '.candidates[0].content.parts[0].text'
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
