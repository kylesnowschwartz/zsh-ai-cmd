#!/usr/bin/env zsh
# test-api.sh - Validate API responses for format compliance
# Usage: ./test-api.sh [--provider anthropic|openai|ollama]

set -uo pipefail

SCRIPT_DIR="${0:a:h}"

# Parse args
typeset -g ZSH_AI_CMD_PROVIDER=${ZSH_AI_CMD_PROVIDER:-'anthropic'}
while [[ $# -gt 0 ]]; do
  case $1 in
    --provider|-p) ZSH_AI_CMD_PROVIDER=$2; shift 2 ;;
    --help|-h) print "Usage: $0 [--provider anthropic|openai|ollama|deepseek|gemini]"; exit 0 ;;
    *) print -u2 "Unknown option: $1"; exit 1 ;;
  esac
done

# OS detection
typeset -g _ZSH_AI_CMD_OS
if [[ $OSTYPE == darwin* ]]; then
  _ZSH_AI_CMD_OS="macOS $(sw_vers -productVersion 2>/dev/null || print 'unknown')"
else
  _ZSH_AI_CMD_OS="Linux"
fi

# Debug mode
typeset -g ZSH_AI_CMD_DEBUG=${ZSH_AI_CMD_DEBUG:-false}
typeset -g ZSH_AI_CMD_LOG=${ZSH_AI_CMD_LOG:-/tmp/zsh-ai-cmd.log}

# Source prompt and providers
source "${SCRIPT_DIR}/prompt.zsh"
source "${SCRIPT_DIR}/providers/anthropic.zsh"
source "${SCRIPT_DIR}/providers/openai.zsh"
source "${SCRIPT_DIR}/providers/ollama.zsh"
source "${SCRIPT_DIR}/providers/deepseek.zsh"
source "${SCRIPT_DIR}/providers/gemini.zsh"

# Get API key for current provider
get_api_key() {
  local provider=$ZSH_AI_CMD_PROVIDER

  # Ollama doesn't need a key
  [[ $provider == ollama ]] && return 0

  local key_var="${(U)provider}_API_KEY"
  local keychain_name="${provider}-api-key"

  # Check env var (use :- to avoid set -u error)
  [[ -n ${(P)key_var:-} ]] && return 0

  # Try macOS Keychain
  local key
  key=$(security find-generic-password -s "$keychain_name" -a "$USER" -w 2>/dev/null)
  if [[ -n $key ]]; then
    typeset -g "$key_var"="$key"
    return 0
  fi

  print -u2 "${(U)provider}_API_KEY not found in env or keychain"
  return 1
}

PASS=0
FAIL=0

# Test cases
typeset -A TESTS=(
  ["list files"]="simple"
  ["find python files modified today"]="simple"
  ["search for TODO in js files"]="simple"
  ["show disk usage"]="simple"
  ["kill process on port 3000"]="pipe"
  ["consolidate git worktree into primary repo"]="ambiguous"
  ["find all files larger than 100mb and delete them"]="dangerous"
  ["compress all jpg files in current directory"]="archive"
  ["show me the last 5 git commits with stats"]="git"
  ["what time is it in tokyo"]="edge_case"
  ["recursively find and replace foo with bar in all .txt files"]="complex"
  ["list running docker containers sorted by memory usage"]="pipe"
  ["show modification time of README.md"]="bsd_stat"
  ["show the date 3 days ago"]="bsd_date"
  ["replace localhost with 127.0.0.1 in config.ini"]="bsd_sed"
  ["find empty directories"]="find_edge"
  ["create a tar.gz of the src directory"]="archive"
  ["convert video.mp4 to animated gif"]="ffmpeg"
  ["extract audio from movie.mkv as mp3"]="ffmpeg"
)

validate_output() {
  local output=$1
  local errors=()

  [[ -z $output ]] && errors+=("empty output")
  [[ $output == *'```'* ]] && errors+=("contains code fence")
  [[ $output == *'`'* ]] && errors+=("contains backticks")
  [[ $output == *$'\n'* ]] && errors+=("multi-line output")
  [[ $output == *"Or "* ]] && errors+=("contains alternatives")
  [[ $output == *"you can"* ]] && errors+=("contains explanation")
  [[ $output == *"Note:"* ]] && errors+=("contains note")
  [[ $output == *"#"* && $output != *"xargs"* ]] && errors+=("contains comment")
  [[ ! $output =~ ^[a-zA-Z./\(] ]] && errors+=("doesn't start like a command")

  if (( ${#errors[@]} > 0 )); then
    print -r -- "${(j:, :)errors}"
    return 1
  fi
  return 0
}

call_api() {
  local input=$1

  local context="<context>
OS: $_ZSH_AI_CMD_OS
Shell: zsh
PWD: /tmp/test
</context>"

  local prompt="${_ZSH_AI_CMD_PROMPT}"$'\n'"${context}"

  # Dispatch to provider
  case $ZSH_AI_CMD_PROVIDER in
    anthropic) _zsh_ai_cmd_anthropic_call "$input" "$prompt" ;;
    openai)    _zsh_ai_cmd_openai_call "$input" "$prompt" ;;
    ollama)    _zsh_ai_cmd_ollama_call "$input" "$prompt" ;;
    deepseek)  _zsh_ai_cmd_deepseek_call "$input" "$prompt" ;;
    gemini)    _zsh_ai_cmd_gemini_call "$input" "$prompt" ;;
    *) print -u2 "Unknown provider: $ZSH_AI_CMD_PROVIDER"; return 1 ;;
  esac
}

run_test() {
  local input=$1
  local category=$2

  printf "%-50s " "$input"

  local output
  output=$(call_api "$input")

  if [[ -z $output ]]; then
    print -P "%F{red}FAIL%f (no response)"
    ((FAIL++))
    return 1
  fi

  local validation
  validation=$(validate_output "$output")
  local valid_status=$?

  if (( valid_status == 0 )); then
    print -P "%F{green}PASS%f"
    print "  -> $output"
    ((PASS++))
  else
    print -P "%F{red}FAIL%f ($validation)"
    print "  -> $output"
    ((FAIL++))
  fi
}

get_model_name() {
  case $ZSH_AI_CMD_PROVIDER in
    anthropic) print "$ZSH_AI_CMD_ANTHROPIC_MODEL" ;;
    openai)    print "$ZSH_AI_CMD_OPENAI_MODEL" ;;
    ollama)    print "$ZSH_AI_CMD_OLLAMA_MODEL" ;;
    deepseek)  print "$ZSH_AI_CMD_DEEPSEEK_MODEL" ;;
    gemini)    print "$ZSH_AI_CMD_GEMINI_MODEL" ;;
  esac
}

main() {
  print "Testing zsh-ai-cmd API responses"
  print "Provider: $ZSH_AI_CMD_PROVIDER"
  print "Model: $(get_model_name)"
  print "================================"
  print ""

  get_api_key || exit 1

  for input category in "${(@kv)TESTS}"; do
    run_test "$input" "$category"
  done

  print ""
  print "================================"
  print "Results: $PASS passed, $FAIL failed"

  (( FAIL > 0 )) && exit 1
  exit 0
}

main "$@"
