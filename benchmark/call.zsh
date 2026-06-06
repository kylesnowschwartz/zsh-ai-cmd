#!/usr/bin/env zsh
# call.zsh — headless single-shot caller for zsh-ai-cmd
# Used by the benchmark runner; also useful for manual probes.
#
# Usage: zsh benchmark/call.zsh "<natural language prompt>"
# Env:   ZSH_AI_CMD_PROVIDER (default: anthropic)

set -uo pipefail

PLUGIN_DIR="${0:a:h:h}"

typeset -g ZSH_AI_CMD_PROVIDER=${ZSH_AI_CMD_PROVIDER:-anthropic}
typeset -g ZSH_AI_CMD_DEBUG=${ZSH_AI_CMD_DEBUG:-false}
typeset -g ZSH_AI_CMD_LOG=${ZSH_AI_CMD_LOG:-/tmp/zsh-ai-cmd-bench.log}

typeset -g _ZSH_AI_CMD_OS
if [[ $OSTYPE == darwin* ]]; then
  _ZSH_AI_CMD_OS="macOS $(sw_vers -productVersion 2>/dev/null || print 'unknown')"
else
  _ZSH_AI_CMD_OS="Linux"
fi

source "${PLUGIN_DIR}/prompt.zsh"
source "${PLUGIN_DIR}/providers/anthropic.zsh"
source "${PLUGIN_DIR}/providers/openai.zsh"
source "${PLUGIN_DIR}/providers/ollama.zsh"
source "${PLUGIN_DIR}/providers/deepseek.zsh"
source "${PLUGIN_DIR}/providers/gemini.zsh"
source "${PLUGIN_DIR}/providers/copilot.zsh"
source "${PLUGIN_DIR}/providers/claude-code.zsh"

provider="${(L)ZSH_AI_CMD_PROVIDER}"
if [[ $provider != ollama && $provider != copilot && $provider != claude-code ]]; then
  key_var="${(U)provider}_API_KEY"
  if [[ -z ${(P)key_var:-} ]]; then
    keychain_name="${provider}-api-key"
    key=$(security find-generic-password -s "$keychain_name" -a "$USER" -w 2>/dev/null)
    if [[ -n $key ]]; then
      typeset -g "$key_var"="$key"
    else
      print -u2 "${key_var} not found in env or keychain"
      exit 1
    fi
  fi
fi

input="$*"
[[ -z $input ]] && { print -u2 "usage: zsh benchmark/call.zsh '<prompt>'"; exit 2; }

# Pinned synthetic capability set for reproducibility across machines.
# Deliberately excludes standard-tool competitors (rg/fd/eza/bat) and GNU
# variants (gdate/gsed) so the suite keeps scoring against its BSD/standard
# answer key. Validating rg/fd substitution would require expanding
# alternates.json first — tracked as follow-up.
typeset -g _ZSH_AI_CMD_CAPS="jq, gh, docker, fzf"

context_template='<context>
OS: $_ZSH_AI_CMD_OS
Shell: zsh
PWD: ${ZSH_AI_CMD_BENCH_PWD:-/tmp}
Available: $_ZSH_AI_CMD_CAPS
</context>'
context="${(e)context_template}"
prompt="${_ZSH_AI_CMD_PROMPT}"$'\n'"${context}"

case $ZSH_AI_CMD_PROVIDER in
  anthropic)   _zsh_ai_cmd_anthropic_call "$input" "$prompt" ;;
  openai)      _zsh_ai_cmd_openai_call "$input" "$prompt" ;;
  ollama)      _zsh_ai_cmd_ollama_call "$input" "$prompt" ;;
  deepseek)    _zsh_ai_cmd_deepseek_call "$input" "$prompt" ;;
  gemini)      _zsh_ai_cmd_gemini_call "$input" "$prompt" ;;
  copilot)     _zsh_ai_cmd_copilot_call "$input" "$prompt" ;;
  claude-code) _zsh_ai_cmd_claude_code_call "$input" "$prompt" ;;
  *) print -u2 "Unknown provider: $ZSH_AI_CMD_PROVIDER"; exit 1 ;;
esac
