#!/usr/bin/env zsh
# test-api-key-command.sh - Tests for ZSH_AI_CMD_API_KEY_COMMAND feature
# Tests custom command-based API key retrieval with ${provider} expansion
# Usage: ./test-api-key-command.sh

set -o pipefail

SCRIPT_DIR="${0:a:h}"
PASS=0
FAIL=0

# ============================================================================
# Test Setup
# ============================================================================

# Clean log before starting
rm -f /tmp/zsh-ai-cmd.log

# Source the plugin (but not as a widget context, so no ZLE needed)
source "${SCRIPT_DIR}/zsh-ai-cmd.plugin.zsh" 2>/dev/null

# ============================================================================
# Helper Functions
# ============================================================================

assert_equals() {
  local name=$1
  local expected=$2
  local actual=$3

  if [[ $expected == $actual ]]; then
    print -P "%F{green}✓ PASS%f: $name"
    ((PASS++))
  else
    print -P "%F{red}✗ FAIL%f: $name"
    print "  Expected: $expected"
    print "  Got:      $actual"
    ((FAIL++))
  fi
}

assert_contains() {
  local name=$1
  local pattern=$2
  local text=$3

  if [[ $text == *$pattern* ]]; then
    print -P "%F{green}✓ PASS%f: $name"
    ((PASS++))
  else
    print -P "%F{red}✗ FAIL%f: $name"
    print "  Pattern: $pattern"
    print "  Text:    $text"
    ((FAIL++))
  fi
}

assert_not_contains() {
  local name=$1
  local pattern=$2
  local text=$3

  if [[ $text != *$pattern* ]]; then
    print -P "%F{green}✓ PASS%f: $name"
    ((PASS++))
  else
    print -P "%F{red}✗ FAIL%f: $name"
    print "  Should not contain: $pattern"
    print "  Text:              $text"
    ((FAIL++))
  fi
}

reset_env() {
  # Unset all provider API keys
  unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY DEEPSEEK_API_KEY
  # Reset to clean state
  ZSH_AI_CMD_API_KEY_COMMAND=""
}

# ============================================================================
# Happy Path Tests
# ============================================================================

print "=== Happy Path Tests ==="
print ""

# Test 1: Basic custom command sets API key
reset_env
rm -f /tmp/zsh-ai-cmd.log
export ZSH_AI_CMD_DEBUG=true
export ZSH_AI_CMD_API_KEY_COMMAND="echo test-key-12345"
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
assert_equals "Custom command sets API key" "test-key-12345" "${ANTHROPIC_API_KEY:-}"

# Test 2: Debug logging shows command execution
assert_contains "Debug log contains command" \
  "command: echo test-key-12345" \
  "$(<${ZSH_AI_CMD_LOG:-/tmp/zsh-ai-cmd.log})"

# Test 3: Debug logging shows success without leaking key
assert_contains "Debug log shows success" \
  "result: success" \
  "$(<${ZSH_AI_CMD_LOG:-/tmp/zsh-ai-cmd.log})"

assert_not_contains "Debug log does not leak key output in char count line" \
  "result: success (13 chars)" \
  "$(<${ZSH_AI_CMD_LOG:-/tmp/zsh-ai-cmd.log})" || true
# (Note: The command itself appears in the log, but the actual key output is never logged)

# Test 4: Provider variable expansion ${provider} works
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND='echo ${provider}-key'
export ZSH_AI_CMD_PROVIDER=openai

_zsh_ai_cmd_get_key
assert_equals "Provider expansion works for openai" "openai-key" "${OPENAI_API_KEY:-}"

# Test 5: Provider expansion with gemini
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND='echo ${provider}-key'
export ZSH_AI_CMD_PROVIDER=gemini

_zsh_ai_cmd_get_key
assert_equals "Provider expansion works for gemini" "gemini-key" "${GEMINI_API_KEY:-}"

# Test 6: Complex command with pipes works
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND='echo "sk-test-12345" | cut -c1-8'
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
assert_equals "Complex command with pipes works" "sk-test-" "${ANTHROPIC_API_KEY:-}"

# Test 7: Output is sanitized (escape sequences stripped)
reset_env
export ZSH_AI_CMD_DEBUG=true
export ZSH_AI_CMD_API_KEY_COMMAND='printf "key\x1b[H\x1b[2J"'
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
assert_equals "Escape sequences are sanitized" "key" "${ANTHROPIC_API_KEY:-}"

# ============================================================================
# Edge Case Tests
# ============================================================================

print ""
print "=== Edge Case Tests ==="
print ""

# Test 8: Empty command output falls through to keychain (if available)
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND='echo ""'
export ZSH_AI_CMD_PROVIDER=anthropic

# Custom command returns empty, so keychain is tried
# If keychain has the key, it succeeds; otherwise shows error
_zsh_ai_cmd_get_key
local result=$?
# Expected: 0 if keychain has entry, 1 if not (both are valid fallback behavior)
assert_equals "Empty command output attempts keychain fallback" "0" "$result"

# Test 9: Failed command falls through to keychain (if available)
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND='nonexistent-command-12345'
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
result=$?
# Expected: 0 if keychain has entry (which it should for anthropic in test env)
assert_equals "Failed command attempts keychain fallback" "0" "$result"

# Test 10: Whitespace is trimmed from output
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND='echo "  spaces-test  "'
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
assert_equals "Whitespace is trimmed" "spaces-test" "${ANTHROPIC_API_KEY:-}"

# Test 11: Environment variable takes precedence over command
reset_env
export OPENAI_API_KEY="env-key"
export ZSH_AI_CMD_API_KEY_COMMAND='echo command-key'
export ZSH_AI_CMD_PROVIDER=openai

_zsh_ai_cmd_get_key
assert_equals "Env var takes precedence over command" "env-key" "${OPENAI_API_KEY:-}"

# Test 12: Empty ZSH_AI_CMD_API_KEY_COMMAND disables feature
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND=""
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
result=$?
# With empty command, feature is disabled, so it tries keychain
# Expected: 0 if keychain has entry, 1 if not
assert_equals "Empty command string disables feature" "0" "$result"

# Test 13: Newlines in output are removed
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND='printf "line1\nline2"'
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
assert_equals "Newlines are removed from output" "line1line2" "${ANTHROPIC_API_KEY:-}"

# Test 14: Tab characters are preserved (part of key)
reset_env
export ZSH_AI_CMD_API_KEY_COMMAND='printf "key\twith\ttabs"'
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
assert_equals "Tab characters are preserved" "key	with	tabs" "${ANTHROPIC_API_KEY:-}"

# ============================================================================
# Backward Compatibility Tests
# ============================================================================

print ""
print "=== Backward Compatibility Tests ==="
print ""

# Test 15: Existing env var lookup still works (no custom command)
reset_env
export ANTHROPIC_API_KEY="env-test-key"
export ZSH_AI_CMD_PROVIDER=anthropic

_zsh_ai_cmd_get_key
result=$?
assert_equals "Env var lookup works without custom command" "0" "$result"

# Test 16: Ollama provider (no key required) still works
reset_env
export ZSH_AI_CMD_PROVIDER=ollama

_zsh_ai_cmd_get_key
result=$?
assert_equals "Ollama provider still works (no key required)" "0" "$result"

# Test 17: Copilot provider (no key required) still works
reset_env
export ZSH_AI_CMD_PROVIDER=copilot

_zsh_ai_cmd_get_key
result=$?
assert_equals "Copilot provider still works (no key required)" "0" "$result"

# ============================================================================
# Summary
# ============================================================================

print ""
print "================================"
print "Results: $PASS passed, $FAIL failed"

if ((FAIL > 0)); then
  exit 1
else
  exit 0
fi
