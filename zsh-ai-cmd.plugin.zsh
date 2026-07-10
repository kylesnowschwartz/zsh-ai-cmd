#!/usr/bin/env zsh
# zsh-ai-cmd.plugin.zsh - AI shell suggestions with ghost text
# Ctrl+Z requests a suggestion; press again to cycle alternatives (or re-roll
# when there is only one). Tab accepts, keep typing to refine/dismiss.
# External deps: curl, jq, security (macOS Keychain)

# Prevent double-loading (creates nested widget wrappers)
(( ${+functions[_zsh_ai_cmd_suggest]} )) && return

# ============================================================================
# Configuration
# ============================================================================
typeset -g ZSH_AI_CMD_KEY=${ZSH_AI_CMD_KEY:-'^z'}
typeset -g ZSH_AI_CMD_DEBUG=${ZSH_AI_CMD_DEBUG:-false}
typeset -g ZSH_AI_CMD_LOG=${ZSH_AI_CMD_LOG:-/tmp/zsh-ai-cmd.log}
typeset -g ZSH_AI_CMD_HIGHLIGHT=${ZSH_AI_CMD_HIGHLIGHT:-'fg=8'}
typeset -g ZSH_AI_CMD_HIGHLIGHT_DESTRUCTIVE=${ZSH_AI_CMD_HIGHLIGHT_DESTRUCTIVE:-'fg=red'}

# Keychain entry name for API key lookup. Single quotes delay ${provider} expansion
# until _zsh_ai_cmd_get_key() runs. Override with a literal name if needed.
typeset -g ZSH_AI_CMD_KEYCHAIN_NAME=${ZSH_AI_CMD_KEYCHAIN_NAME:-'${provider}-api-key'}

# Custom command for API key retrieval. Uses ${provider} expansion at runtime.
# If command returns empty/fails, falls back to macOS Keychain.
# Examples: 'pass ${provider}-api-key', 'secret-tool lookup service ${provider}'
typeset -g ZSH_AI_CMD_API_KEY_COMMAND=${ZSH_AI_CMD_API_KEY_COMMAND:-''}

# Provider selection (anthropic, openai, gemini, deepseek, ollama)
typeset -g ZSH_AI_CMD_PROVIDER=${ZSH_AI_CMD_PROVIDER:-'anthropic'}

# Legacy model variable maps to anthropic model for backwards compatibility
typeset -g ZSH_AI_CMD_MODEL=${ZSH_AI_CMD_MODEL:-'claude-haiku-4-5-20251001'}
typeset -g ZSH_AI_CMD_ANTHROPIC_MODEL=${ZSH_AI_CMD_ANTHROPIC_MODEL:-$ZSH_AI_CMD_MODEL}

# ============================================================================
# Internal State
# ============================================================================
# All suggestions from the last API call (primary + alternatives), with a
# parallel destructive-flag array. Trigger key cycles through them while
# active; the current suggestion is _ZSH_AI_CMD_SUGGESTIONS[_ZSH_AI_CMD_INDEX].
typeset -ga _ZSH_AI_CMD_SUGGESTIONS=()
typeset -ga _ZSH_AI_CMD_DESTRUCTIVE=()
typeset -g _ZSH_AI_CMD_INDEX=1

# OS detection (lazy-loaded on first API call)
typeset -g _ZSH_AI_CMD_OS=""

# Detected tool capabilities (lazy-loaded on first API call)
typeset -g _ZSH_AI_CMD_CAPS=""

# Tools probed for capability grounding. Standard POSIX utilities are assumed
# present and omitted; this list is modern alternatives, GNU coreutils on macOS,
# and common dev/cloud tools the model should only suggest when actually installed.
typeset -ga ZSH_AI_CMD_PROBE_TOOLS=(
  rg fd eza bat fzf delta zoxide sd jq yq
  gdate gsed gawk gtimeout
  gh docker kubectl terraform podman
)

# Dormant/Active state machine
typeset -g _ZSH_AI_CMD_ACTIVE=0
typeset -g _ZSH_AI_CMD_ORIG_TAB=""
typeset -g _ZSH_AI_CMD_ORIG_RIGHT_ARROW=""
typeset -g _ZSH_AI_CMD_BUFFER_AT_SUGGESTION=""
typeset -g _ZSH_AI_CMD_LAST_HIGHLIGHT=""

# ============================================================================
# Security: Sanitize model output
# ============================================================================

_zsh_ai_cmd_sanitize() {
  setopt local_options extended_glob
  local input=$1
  local sanitized=$input
  local esc=$'\x1b'

  # Security sanitization for model output
  # Prevents: newline injection, terminal escape attacks, control char manipulation

  # 1. Strip ANSI CSI escape sequences FIRST: ESC [ params letter
  #    Must happen before control char stripping or ESC gets removed separately
  while [[ $sanitized == *${esc}\[* ]]; do
    sanitized=${sanitized//${esc}\[[0-9;]#[A-Za-z]/}
  done

  # 2. Strip any remaining ESC characters (non-CSI escapes)
  sanitized=${sanitized//${esc}/}

  # 3. Strip control characters (0x00-0x1F except tab 0x09, and DEL 0x7F)
  #    Now safe to remove remaining control chars including orphaned brackets
  sanitized=${sanitized//[$'\x00'-$'\x08'$'\x0a'-$'\x1f'$'\x7f']/}

  # 4. Trim leading/trailing whitespace
  sanitized=${sanitized##[[:space:]]##}
  sanitized=${sanitized%%[[:space:]]##}

  print -r -- "$sanitized"
}

# ============================================================================
# System Prompt and Providers
# ============================================================================
source "${0:a:h}/prompt.zsh"
source "${0:a:h}/providers/anthropic.zsh"
source "${0:a:h}/providers/openai.zsh"
source "${0:a:h}/providers/ollama.zsh"
source "${0:a:h}/providers/lmstudio.zsh"
source "${0:a:h}/providers/deepseek.zsh"
source "${0:a:h}/providers/gemini.zsh"
source "${0:a:h}/providers/copilot.zsh"
source "${0:a:h}/providers/claude-code.zsh"

# ============================================================================
# Ghost Text Display
# ============================================================================

_zsh_ai_cmd_show_ghost() {
  local suggestion=$1
  [[ $ZSH_AI_CMD_DEBUG == true ]] && print -- "show_ghost: suggestion='$suggestion' BUFFER='$BUFFER'" >> $ZSH_AI_CMD_LOG

  # Clear any previous highlight first
  [[ -n $_ZSH_AI_CMD_LAST_HIGHLIGHT ]] && {
    region_highlight=("${(@)region_highlight:#$_ZSH_AI_CMD_LAST_HIGHLIGHT}")
    _ZSH_AI_CMD_LAST_HIGHLIGHT=""
  }

  if [[ -z $suggestion ]]; then
    POSTDISPLAY=""
    return
  fi

  local destructive=${_ZSH_AI_CMD_DESTRUCTIVE[_ZSH_AI_CMD_INDEX]:-0}
  local annot=""
  (( ${#_ZSH_AI_CMD_SUGGESTIONS} > 1 )) && annot="  ⟲ ${_ZSH_AI_CMD_INDEX}/${#_ZSH_AI_CMD_SUGGESTIONS}"

  # ⚠/⟲ annotations are display-only: Tab inserts $suggestion, never POSTDISPLAY
  if [[ $suggestion == "$BUFFER" ]]; then
    # Buffer already is the command - nothing to complete, but keep the
    # destructive verdict and cycle counter visible instead of dropping them
    (( destructive )) && annot="  ⚠${annot}"
    POSTDISPLAY="${annot}"
    [[ -z $annot ]] && return
  elif [[ $suggestion == "$BUFFER"* ]]; then
    # Suggestion is completion of current buffer - show suffix
    (( destructive )) && annot="  ⚠${annot}"
    POSTDISPLAY="${suggestion#"$BUFFER"}${annot}"
  else
    # Suggestion is different - show with tab hint (⚠ marks destructive)
    local warn=""
    (( destructive )) && warn="⚠ "
    POSTDISPLAY="  ⇥  ${warn}${suggestion}${annot}"
  fi

  # Apply highlight (uses tracked entry for clean removal, no collision with other plugins)
  local highlight=$ZSH_AI_CMD_HIGHLIGHT
  (( destructive )) && highlight=$ZSH_AI_CMD_HIGHLIGHT_DESTRUCTIVE
  local start=$#BUFFER
  local end=$(( start + $#POSTDISPLAY ))
  _ZSH_AI_CMD_LAST_HIGHLIGHT="$start $end $highlight"
  region_highlight+=("$_ZSH_AI_CMD_LAST_HIGHLIGHT")
  [[ $ZSH_AI_CMD_DEBUG == true ]] && print -- "show_ghost: POSTDISPLAY='$POSTDISPLAY'" >> $ZSH_AI_CMD_LOG
}

# ============================================================================
# Dormant/Active State Machine
# ============================================================================

_zsh_ai_cmd_activate() {
  (( _ZSH_AI_CMD_ACTIVE )) && return
  _ZSH_AI_CMD_ACTIVE=1
  _ZSH_AI_CMD_BUFFER_AT_SUGGESTION="$BUFFER"

  # Capture current bindings before overwriting
  _ZSH_AI_CMD_ORIG_TAB=$(bindkey -M main '^I' 2>/dev/null | awk '{print $2}')
  [[ $_ZSH_AI_CMD_ORIG_TAB == _zsh_ai_cmd_accept ]] && _ZSH_AI_CMD_ORIG_TAB=""
  _ZSH_AI_CMD_ORIG_RIGHT_ARROW=$(bindkey -M main '^[[C' 2>/dev/null | awk '{print $2}')
  [[ $_ZSH_AI_CMD_ORIG_RIGHT_ARROW == _zsh_ai_cmd_accept_arrow ]] && _ZSH_AI_CMD_ORIG_RIGHT_ARROW=""

  # Bind our accept handlers
  bindkey '^I' _zsh_ai_cmd_accept
  bindkey '^[[C' _zsh_ai_cmd_accept_arrow
}

_zsh_ai_cmd_deactivate() {
  (( ! _ZSH_AI_CMD_ACTIVE )) && return
  _ZSH_AI_CMD_ACTIVE=0
  _ZSH_AI_CMD_SUGGESTIONS=()
  _ZSH_AI_CMD_DESTRUCTIVE=()
  _ZSH_AI_CMD_INDEX=1
  _ZSH_AI_CMD_BUFFER_AT_SUGGESTION=""
  POSTDISPLAY=""

  # Remove our highlight only
  [[ -n $_ZSH_AI_CMD_LAST_HIGHLIGHT ]] && {
    region_highlight=("${(@)region_highlight:#$_ZSH_AI_CMD_LAST_HIGHLIGHT}")
    _ZSH_AI_CMD_LAST_HIGHLIGHT=""
  }

  # Restore original bindings
  if [[ -n $_ZSH_AI_CMD_ORIG_TAB ]]; then
    bindkey '^I' "$_ZSH_AI_CMD_ORIG_TAB"
  else
    bindkey '^I' expand-or-complete
  fi
  if [[ -n $_ZSH_AI_CMD_ORIG_RIGHT_ARROW ]]; then
    bindkey '^[[C' "$_ZSH_AI_CMD_ORIG_RIGHT_ARROW"
  else
    bindkey '^[[C' forward-char
  fi
}

# Advance to the next suggestion and redraw the ghost. Wraps around; no-op
# when there is only one suggestion.
_zsh_ai_cmd_cycle() {
  local count=${#_ZSH_AI_CMD_SUGGESTIONS}
  (( count <= 1 )) && return
  _ZSH_AI_CMD_INDEX=$(( _ZSH_AI_CMD_INDEX % count + 1 ))
  _zsh_ai_cmd_show_ghost "${_ZSH_AI_CMD_SUGGESTIONS[_ZSH_AI_CMD_INDEX]}"
  zle -R
}

_zsh_ai_cmd_pre_redraw() {
  (( ! _ZSH_AI_CMD_ACTIVE )) && return

  # Buffer changed since suggestion was shown
  if [[ $BUFFER != $_ZSH_AI_CMD_BUFFER_AT_SUGGESTION ]]; then
    local current=${_ZSH_AI_CMD_SUGGESTIONS[_ZSH_AI_CMD_INDEX]:-}
    if [[ $current == ${BUFFER}* && -n $BUFFER ]]; then
      # Still a valid prefix - update ghost
      _zsh_ai_cmd_show_ghost "$current"
      _ZSH_AI_CMD_BUFFER_AT_SUGGESTION="$BUFFER"
    else
      # Diverged - deactivate
      _zsh_ai_cmd_deactivate
    fi
  fi
}

# ============================================================================
# API Call Dispatcher
# ============================================================================

_zsh_ai_cmd_call_api() {
  local input=$1

  # Lazy OS detection
  if [[ -z $_ZSH_AI_CMD_OS ]]; then
    if [[ $OSTYPE == darwin* ]]; then
      _ZSH_AI_CMD_OS="macOS $(sw_vers -productVersion 2>/dev/null || print 'unknown')"
    else
      _ZSH_AI_CMD_OS="Linux"
    fi
  fi

  # Lazy capability detection (pure zsh: $commands hash lookup, no subprocesses)
  if [[ -z $_ZSH_AI_CMD_CAPS ]]; then
    local _tool _present=()
    for _tool in $ZSH_AI_CMD_PROBE_TOOLS; do
      (( $+commands[$_tool] )) && _present+=$_tool
    done
    # Sentinel space marks detection as done even when nothing is found,
    # so we don't re-probe on every call.
    _ZSH_AI_CMD_CAPS="${(j:, :)_present} "
  fi

  local context="${(e)_ZSH_AI_CMD_CONTEXT}"
  local prompt="${_ZSH_AI_CMD_PROMPT}"$'\n'"${context}"

  case $ZSH_AI_CMD_PROVIDER in
    anthropic) _zsh_ai_cmd_anthropic_call "$input" "$prompt" ;;
    openai)    _zsh_ai_cmd_openai_call "$input" "$prompt" ;;
    ollama)    _zsh_ai_cmd_ollama_call "$input" "$prompt" ;;
    lmstudio)  _zsh_ai_cmd_lmstudio_call "$input" "$prompt" ;;
    deepseek)  _zsh_ai_cmd_deepseek_call "$input" "$prompt" ;;
    gemini)    _zsh_ai_cmd_gemini_call "$input" "$prompt" ;;
    copilot)     _zsh_ai_cmd_copilot_call "$input" "$prompt" ;;
    claude-code) _zsh_ai_cmd_claude_code_call "$input" "$prompt" ;;
    *) print -u2 "zsh-ai-cmd: Unknown provider '$ZSH_AI_CMD_PROVIDER'"; return 1 ;;
  esac
}

# ============================================================================
# Main Widget: trigger key requests, cycles, or re-rolls suggestions
# ============================================================================

_zsh_ai_cmd_suggest() {
  # While a suggestion is showing, the trigger key cycles through alternatives;
  # with a single suggestion it falls through to a fresh query (re-roll),
  # matching the pre-cycling behavior of repeat Ctrl+Z
  if (( _ZSH_AI_CMD_ACTIVE )); then
    if (( ${#_ZSH_AI_CMD_SUGGESTIONS} > 1 )); then
      _zsh_ai_cmd_cycle
      return
    fi
    _zsh_ai_cmd_deactivate
  fi

  [[ -z $BUFFER ]] && return

  _zsh_ai_cmd_get_key || { BUFFER=""; zle accept-line; return 1; }

  # Show spinner
  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  # Start API call in background (suppress job control noise)
  local tmpfile=$(mktemp)
  setopt local_options no_notify no_monitor clobber
  ( _zsh_ai_cmd_call_api "$BUFFER" > "$tmpfile" ) &!
  local pid=$!

  # Animate spinner while waiting
  while kill -0 $pid 2>/dev/null; do
    POSTDISPLAY=" ${spinner:$((i % 10)):1}"
    zle -R
    read -t 0.1 -k 1 && { kill $pid 2>/dev/null; POSTDISPLAY=""; rm -f "$tmpfile"; return; }
    ((i++))
  done
  wait $pid 2>/dev/null

  # Parse provider wire format: one suggestion per line, "D<TAB>command" for
  # destructive commands, "S<TAB>command" otherwise. Each command is sanitized
  # individually (security: strip control chars, newlines, escapes).
  local raw
  raw=$(<"$tmpfile")
  rm -f "$tmpfile"

  local -a suggestions destructive
  local line flag cmd existing
  for line in "${(@f)raw}"; do
    # Fail closed: every provider emits the flag, so an unmarked line is stray
    # output (CLI noise, partial response) — drop it, never show it as "safe"
    [[ $line != [DS]$'\t'* ]] && continue
    flag=${line[1]}
    cmd=$(_zsh_ai_cmd_sanitize "${line#?$'\t'}")
    [[ -z $cmd ]] && continue
    existing=${suggestions[(Ie)$cmd]}
    if (( existing )); then
      # Duplicate command with contradictory flags: keep the destructive one
      [[ $flag == D ]] && destructive[existing]=1
      continue
    fi
    suggestions+=("$cmd")
    if [[ $flag == D ]]; then destructive+=(1); else destructive+=(0); fi
    (( ${#suggestions} == _ZSH_AI_CMD_MAX_SUGGESTIONS )) && break
  done

  if (( ${#suggestions} )); then
    _ZSH_AI_CMD_SUGGESTIONS=("${(@)suggestions}")
    _ZSH_AI_CMD_DESTRUCTIVE=("${(@)destructive}")
    _ZSH_AI_CMD_INDEX=1
    _zsh_ai_cmd_show_ghost "${suggestions[1]}"
    _zsh_ai_cmd_activate
    zle -R
  else
    POSTDISPLAY=""
    zle -M "zsh-ai-cmd: no suggestion"
  fi
}

# ============================================================================
# Accept/Reject Handling
# ============================================================================

_zsh_ai_cmd_accept() {
  local suggestion=${_ZSH_AI_CMD_SUGGESTIONS[_ZSH_AI_CMD_INDEX]:-}
  if [[ -n $suggestion ]] && (( _ZSH_AI_CMD_ACTIVE )); then
    BUFFER=$suggestion
    CURSOR=$#BUFFER
    _zsh_ai_cmd_deactivate
  elif [[ -n $_ZSH_AI_CMD_ORIG_TAB ]]; then
    zle "$_ZSH_AI_CMD_ORIG_TAB"
  else
    zle expand-or-complete
  fi
}

_zsh_ai_cmd_accept_arrow() {
  local suggestion=${_ZSH_AI_CMD_SUGGESTIONS[_ZSH_AI_CMD_INDEX]:-}
  if [[ -n $suggestion ]] && (( _ZSH_AI_CMD_ACTIVE )); then
    BUFFER=$suggestion
    CURSOR=$#BUFFER
    _zsh_ai_cmd_deactivate
  elif [[ -n $_ZSH_AI_CMD_ORIG_RIGHT_ARROW ]]; then
    zle "$_ZSH_AI_CMD_ORIG_RIGHT_ARROW"
  else
    zle .forward-char
  fi
}

# ============================================================================
# Line Lifecycle
# ============================================================================

_zsh_ai_cmd_line_finish() {
  (( _ZSH_AI_CMD_ACTIVE )) && _zsh_ai_cmd_deactivate
}

# ============================================================================
# Widget Registration
# ============================================================================

zle -N zle-line-finish _zsh_ai_cmd_line_finish
zle -N _zsh_ai_cmd_suggest
zle -N _zsh_ai_cmd_accept
zle -N _zsh_ai_cmd_accept_arrow

# Only permanent binding: the trigger key
bindkey "$ZSH_AI_CMD_KEY" _zsh_ai_cmd_suggest

# Pre-redraw hook for buffer change detection (replaces widget wrapping)
# Use add-zle-hook-widget if available (supports chaining), otherwise direct assignment
autoload -Uz add-zle-hook-widget 2>/dev/null
if (( $+functions[add-zle-hook-widget] )); then
  add-zle-hook-widget line-pre-redraw _zsh_ai_cmd_pre_redraw
else
  zle -N zle-line-pre-redraw _zsh_ai_cmd_pre_redraw
fi

# ============================================================================
# API Key Management
# ============================================================================

_zsh_ai_cmd_get_key() {
  local provider="${(L)ZSH_AI_CMD_PROVIDER}"  # Normalize provider to lowercase

  # LMStudio, Ollama, Copilot, and Claude Code don't need a key
  [[ $provider == lmstudio || $provider == ollama || $provider == copilot || $provider == claude-code ]] && return 0

  local key_var="${(U)provider}_API_KEY"
  local keychain_name="${(e)ZSH_AI_CMD_KEYCHAIN_NAME}"

  # Check env var
  [[ -n ${(P)key_var} ]] && return 0

  # Try custom command if configured
  if [[ -n $ZSH_AI_CMD_API_KEY_COMMAND ]]; then
    local expanded_command="${(e)ZSH_AI_CMD_API_KEY_COMMAND}"

    [[ $ZSH_AI_CMD_DEBUG == true ]] && {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [get_key] ===" >> $ZSH_AI_CMD_LOG
      print -- "provider: $provider" >> $ZSH_AI_CMD_LOG
      print -- "command: $expanded_command" >> $ZSH_AI_CMD_LOG
    }

    local key
    key=$(eval "$expanded_command" 2>/dev/null)

    if [[ $? -eq 0 && -n $key ]]; then
      # Sanitize command output (security: strip control chars, escapes)
      key=$(_zsh_ai_cmd_sanitize "$key")

      [[ $ZSH_AI_CMD_DEBUG == true ]] && {
        print -- "result: success (${#key} chars after sanitization)" >> $ZSH_AI_CMD_LOG
        print "" >> $ZSH_AI_CMD_LOG
      }

      typeset -g "$key_var"="$key"
      return 0
    else
      [[ $ZSH_AI_CMD_DEBUG == true ]] && {
        print -- "result: command failed or returned empty, trying keychain" >> $ZSH_AI_CMD_LOG
        print "" >> $ZSH_AI_CMD_LOG
      }
    fi
  fi

  # Try macOS Keychain
  local key
  key=$(security find-generic-password -s "$keychain_name" -a "$USER" -w 2>/dev/null)
  if [[ -n $key ]]; then
    typeset -g "$key_var"="$key"
    return 0
  fi

  # Show provider-specific error
  "_zsh_ai_cmd_${provider}_key_error"
  return 1
}
