# providers/synthetic.zsh - Synthetic API provider
# Generic OpenAI-compatible API provider
# Endpoint: https://api.synthetic.new/openai/v1/chat/completions

typeset -g ZSH_AI_CMD_SYNTHETIC_MODEL=${ZSH_AI_CMD_SYNTHETIC_MODEL:-'hf:moonshotai/Kimi-K2.5'}
typeset -g ZSH_AI_CMD_SYNTHETIC_BASE_URL=${ZSH_AI_CMD_SYNTHETIC_BASE_URL:-'https://api.synthetic.new/openai/v1/chat/completions'}

_zsh_ai_cmd_synthetic_call() {
  local input=$1
  local prompt=$2

  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_SYNTHETIC_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $content}
      ]
    }')

  local response curl_exit http_status
  local tmpfile=$(mktemp)
  local errfile=$(mktemp)

  http_status=$(command curl -sS --max-time 30 -w "%{http_code}" "$ZSH_AI_CMD_SYNTHETIC_BASE_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $SYNTHETIC_API_KEY" \
    -d "$payload" \
    -o "$tmpfile" 2>"$errfile")
  curl_exit=$?

  response=$(<"$tmpfile")
  local curl_err=$(<"$errfile")
  rm -f "$tmpfile" "$errfile"

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [synthetic] ==="
      print -- "curl exit: $curl_exit"
      print -- "HTTP status: $http_status"
      [[ -n $curl_err ]] && print -- "curl error: $curl_err"
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      if [[ -n $response ]]; then
        command jq . <<< "$response" 2>/dev/null || print -r -- "$response"
      else
        print -- "(empty response)"
      fi
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Check for failures
  if [[ $curl_exit -ne 0 ]]; then
    [[ $ZSH_AI_CMD_DEBUG != true ]] && print -u2 "zsh-ai-cmd [synthetic]: curl failed (exit $curl_exit)"
    return 1
  fi

  if [[ $http_status != 200 ]]; then
    [[ $ZSH_AI_CMD_DEBUG != true ]] && print -u2 "zsh-ai-cmd [synthetic]: HTTP $http_status"
    return 1
  fi

  # Check for API error
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re '.error.message // empty' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [synthetic]: $error_msg"
    return 1
  fi

  # Extract content
  print -r -- "$response" | command jq -re '.choices[0].message.content // empty' 2>/dev/null
}

_zsh_ai_cmd_synthetic_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: SYNTHETIC_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export SYNTHETIC_API_KEY='...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'synthetic-api-key' -a '\$USER' -w '...'"
  print -u2 ""
  print -u2 "Current configuration:"
  print -u2 "  Model: $ZSH_AI_CMD_SYNTHETIC_MODEL"
  print -u2 "  Base URL: $ZSH_AI_CMD_SYNTHETIC_BASE_URL"
}
