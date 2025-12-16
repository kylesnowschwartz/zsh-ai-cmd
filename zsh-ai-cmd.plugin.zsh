#!/usr/bin/env zsh
# zsh-ai-cmd.plugin.zsh - Minimal AI shell suggestions
# External deps: curl, jq, security (macOS Keychain)

# Configuration
typeset -g ZSH_AI_CMD_KEY=${ZSH_AI_CMD_KEY:-'^z'}
typeset -g ZSH_AI_CMD_DEBUG=${ZSH_AI_CMD_DEBUG:-false}
typeset -g ZSH_AI_CMD_MODEL=${ZSH_AI_CMD_MODEL:-'claude-haiku-4-5-20251001'}

# Cache OS at load time
typeset -g _ZSH_AI_CMD_OS
if [[ $OSTYPE == darwin* ]]; then
  _ZSH_AI_CMD_OS="macOS $(sw_vers -productVersion 2>/dev/null || print 'unknown')"
else
  _ZSH_AI_CMD_OS="Linux"
fi

# System prompt
typeset -g _ZSH_AI_CMD_PROMPT='Translate natural language to a single shell command.

RULES:
- Output EXACTLY ONE command, nothing else
- No explanations, no alternatives, no markdown
- No code blocks, no backticks
- If ambiguous, pick the most reasonable interpretation
- Prefix standard tools with `command` to bypass aliases

EFFICIENCY:
- Avoid spawning processes per item: use -exec {} + not -exec {} \;
- Use built-in formatting: find -printf, stat -c (not piping to awk/sed)
- Add limits on unbounded searches: head, -maxdepth, 2>/dev/null for errors
- Prefer human-readable output where appropriate (-h flags for sizes)

<examples>
User: list files
command ls -la

User: find 10 largest files
command find . -type f -exec stat -f "%z %N" {} + 2>/dev/null | sort -rn | head -10

User: find python files modified today
command find . -name "*.py" -mtime -1

User: search for TODO in js files
command grep -r "TODO" --include="*.js" .

User: consolidate git worktree into primary repo
git worktree remove .

User: kill process on port 3000
command lsof -ti:3000 | xargs kill -9

User: show disk usage by folder sorted by size
command du -h -d 1 | sort -hr | head -20

User: what is listening on port 8080
command lsof -i :8080

User: show processes sorted by memory
command ps aux -m | head -15
</examples>'

# Context template (variables expanded at call time)
typeset -g _ZSH_AI_CMD_CONTEXT='<context>
OS: $_ZSH_AI_CMD_OS
Shell: ${SHELL:t}
PWD: $PWD
</context>'

# Spinner frames (braille dots)
typeset -ga _ZSH_AI_CMD_SPINNER=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# Main widget
_zsh_ai_cmd_suggest() {
  _zsh_ai_cmd_get_key || return 1

  # Get text up to cursor
  local input=${BUFFER[1,CURSOR]}

  local context="${(e)_ZSH_AI_CMD_CONTEXT}"
  local prompt="${_ZSH_AI_CMD_PROMPT}"$'\n'"${context}"

  # JSON schema for structured output (guarantees single command string)
  local schema='{
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "description": "The shell command to execute"
      }
    },
    "required": ["command"],
    "additionalProperties": false
  }'

  # Build payload with jq (handles all escaping correctly)
  local payload
  payload=$(command jq -nc \
    --arg model "$ZSH_AI_CMD_MODEL" \
    --arg system "$prompt" \
    --arg content "$input" \
    --argjson schema "$schema" \
    '{
      model: $model,
      max_tokens: 256,
      system: $system,
      messages: [{role: "user", content: $content}],
      output_format: {type: "json_schema", schema: $schema}
    }')

  # Call API with spinner animation
  _zsh_ai_cmd_call_api "$payload" || return 1

  local suggestion
  # Structured output returns JSON in text field, extract the command
  suggestion=$(print -r -- "$_ZSH_AI_CMD_RESPONSE" | command jq -re '.content[0].text | fromjson | .command // empty') || {
    local err=$(print -r -- "$_ZSH_AI_CMD_RESPONSE" | command jq -r '.error.message // "Unknown error"')
    zle -M "zsh-ai-cmd: $err"
    return 1
  }

  # Debug log (full request/response for inspection)
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
      print -- "--- REQUEST ---"
      command jq . <<< "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$_ZSH_AI_CMD_RESPONSE"
      print ""
    } >>/tmp/zsh-ai-cmd.log
  fi

  # Clear autosuggestions if loaded
  (( $+functions[_zsh_autosuggest_clear] )) && _zsh_autosuggest_clear

  BUFFER=$suggestion
  CURSOR=$#BUFFER
}

# Background API call with animated spinner
_zsh_ai_cmd_call_api() {
  local payload=$1
  local tmpfile="/tmp/zsh_ai_cmd_$$"

  # Suppress job notifications, restore on exit
  setopt LOCAL_OPTIONS NO_NOTIFY NO_MONITOR

  command curl -sS --max-time 30 "https://api.anthropic.com/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: structured-outputs-2025-11-13" \
    -d "$payload" >"$tmpfile" 2>&1 &
  local curl_pid=$!

  # Animate spinner while curl runs (foreground loop has ZLE context)
  local i=1
  while kill -0 $curl_pid 2>/dev/null; do
    zle -R -- "${_ZSH_AI_CMD_SPINNER[$i]}"
    i=$(((i % ${#_ZSH_AI_CMD_SPINNER[@]}) + 1))
    read -t 0.08 -k 1 2>/dev/null # Non-blocking sleep
  done

  wait $curl_pid
  local curl_status=$?
  typeset -g _ZSH_AI_CMD_RESPONSE=$(<"$tmpfile")
  rm -f "$tmpfile"

  # Force full redraw to clear spinner artifacts
  zle -R

  [[ $curl_status -ne 0 ]] && {
    zle -M "zsh-ai-cmd: curl failed"
    return 1
  }
  return 0
}

# Lazy-load API key (cached after first call)
_zsh_ai_cmd_get_key() {
  [[ -n $ANTHROPIC_API_KEY ]] && return 0
  ANTHROPIC_API_KEY=$(security find-generic-password \
    -s "anthropic-api-key" -a "$USER" -w 2>/dev/null) || {
    print -u2 "zsh-ai-cmd: ANTHROPIC_API_KEY not found"
    print -u2 ""
    print -u2 "Set it via environment variable:"
    print -u2 "  export ANTHROPIC_API_KEY='sk-ant-...'"
    print -u2 ""
    print -u2 "Or store in macOS Keychain:"
    print -u2 "  security add-generic-password -s 'anthropic-api-key' -a '\$USER' -w 'sk-ant-...'"
    return 1
  }
}

zle -N _zsh_ai_cmd_suggest
bindkey "$ZSH_AI_CMD_KEY" _zsh_ai_cmd_suggest
