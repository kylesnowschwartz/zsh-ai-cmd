# providers/anthropic.zsh - Anthropic Claude API provider
# Uses structured outputs with JSON schema for reliable command extraction

typeset -g ZSH_AI_CMD_ANTHROPIC_MODEL=${ZSH_AI_CMD_ANTHROPIC_MODEL:-'claude-haiku-4-5-20251001'}

# Thinking effort (low, medium, high, xhigh, max), sent as output_config.effort.
# Defaults to low, which keeps thinking models fast; set it to empty to send no
# effort. Models that reject the parameter never receive it.
typeset -g ZSH_AI_CMD_ANTHROPIC_EFFORT=${ZSH_AI_CMD_ANTHROPIC_EFFORT-low}

# Haiku and Sonnet 4.5 reject output_config.effort with a 400. Skipping it for
# the whole family is harmless if a later model in it gains support.
_zsh_ai_cmd_anthropic_supports_effort() {
  case $1 in
    claude-haiku-*|claude-sonnet-4-5*) return 1 ;;
    *) return 0 ;;
  esac
}

_zsh_ai_cmd_anthropic_call() {
  local input=$1
  local prompt=$2"$_ZSH_AI_CMD_PROMPT_STRUCTURED"

  local effort=$ZSH_AI_CMD_ANTHROPIC_EFFORT
  _zsh_ai_cmd_anthropic_supports_effort "$ZSH_AI_CMD_ANTHROPIC_MODEL" || effort=""

  # max_tokens covers thinking plus the full structured payload: thinking tokens
  # count toward the limit, and the answer holds a primary + 2 alternatives of
  # long commands (ffmpeg/rsync pipelines) plus JSON scaffolding
  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_ANTHROPIC_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    --argjson schema "$_ZSH_AI_CMD_SCHEMA" \
    --arg effort "$effort" \
    '{
      model: $model,
      max_tokens: 4096,
      system: $system,
      messages: [{role: "user", content: $content}],
      output_config: (
        {format: {type: "json_schema", schema: $schema}}
        + (if $effort != "" then {effort: $effort} else {} end)
      )
    }')

  local response
  response=$(command curl -sS --max-time 30 "https://api.anthropic.com/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "$payload" 2>/dev/null)

  # Debug log
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(command date '+%Y-%m-%d %H:%M:%S') [anthropic] ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # Check for API error (Anthropic format: {"error": {"message": "..."}})
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re '.error.message // empty' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [anthropic]: $error_msg"
    return 1
  fi

  # A truncated or refused response has no usable answer; say why
  local stop_reason
  stop_reason=$(print -r -- "$response" | command jq -r '.stop_reason // empty' 2>/dev/null)
  case $stop_reason in
    max_tokens)
      print -u2 "zsh-ai-cmd [anthropic]: response cut off at max_tokens; lower ZSH_AI_CMD_ANTHROPIC_EFFORT"
      return 1 ;;
    refusal)
      print -u2 "zsh-ai-cmd [anthropic]: model declined the request"
      return 1 ;;
  esac

  # Extract suggestions from structured output (wire format: D/S<TAB>command per line).
  # Thinking blocks can precede the answer, so take the first text block; a
  # response without one yields no output.
  _zsh_ai_cmd_extract "$response" '[.content[] | select(.type == "text")][0].text'
}

_zsh_ai_cmd_anthropic_key_error() {
  print -u2 ""
  print -u2 "zsh-ai-cmd: ANTHROPIC_API_KEY not found"
  print -u2 ""
  print -u2 "Set it via environment variable:"
  print -u2 "  export ANTHROPIC_API_KEY='sk-ant-...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'anthropic-api-key' -a '\$USER' -w 'sk-ant-...'"
}
