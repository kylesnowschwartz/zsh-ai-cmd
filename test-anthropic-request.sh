#!/usr/bin/env zsh
# test-anthropic-request.sh - Offline tests for the Anthropic provider's request
# payload and response parsing. A fake curl first on PATH records the request
# and replays a canned response, so no network call or API key is needed.
# Usage: ./test-anthropic-request.sh

set -uo pipefail

SCRIPT_DIR="${0:a:h}"
PASS=0
FAIL=0

MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT INT TERM

# The provider calls `command curl`, which bypasses shell functions but still
# searches PATH, so the fake has to be an executable file.
print -r -- '#!/usr/bin/env zsh
: > "$MOCK_DIR/headers"
while (( $# )); do
  case $1 in
    -d) print -r -- "$2" > "$MOCK_DIR/payload"; shift ;;
    -H) print -r -- "$2" >> "$MOCK_DIR/headers"; shift ;;
  esac
  shift
done
cat "$MOCK_DIR/response"' > "$MOCK_DIR/curl"
chmod +x "$MOCK_DIR/curl"
export MOCK_DIR
path=("$MOCK_DIR" $path)
rehash

export ANTHROPIC_API_KEY="test-key-for-mock"
ZSH_AI_CMD_DEBUG=false
unset ZSH_AI_CMD_ANTHROPIC_EFFORT
source "$SCRIPT_DIR/prompt.zsh"
source "$SCRIPT_DIR/providers/anthropic.zsh"

assert_equals() {
  local name=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    print -P "%F{green}✓ PASS%f: $name"
    ((PASS++))
  else
    print -P "%F{red}✗ FAIL%f: $name"
    print -r -- "  Expected: $expected"
    print -r -- "  Got:      $actual"
    ((FAIL++))
  fi
}

# Writes a canned Messages API response whose content array is CONTENT_JSON,
# with STOP_REASON (default end_turn).
mock_response() {
  command jq -nc --argjson content "$1" --arg stop "${2:-end_turn}" \
    '{type: "message", role: "assistant", content: $content, stop_reason: $stop}' \
    > "$MOCK_DIR/response"
}

assert_contains() {
  local name=$1 pattern=$2 text=$3
  if [[ $text == *"$pattern"* ]]; then
    print -P "%F{green}✓ PASS%f: $name"
    ((PASS++))
  else
    print -P "%F{red}✗ FAIL%f: $name"
    print -r -- "  Pattern: $pattern"
    print -r -- "  Text:    $text"
    ((FAIL++))
  fi
}

answer_json=$(command jq -nc '{
  command: "rm -rf build",
  destructive: true,
  alternatives: [{command: "git clean -fdX", destructive: true}, {command: "ls build", destructive: false}]
} | tojson')
text_block=$(command jq -nc --argjson text "$answer_json" '{type: "text", text: $text}')
thinking_block='{"type":"thinking","thinking":"The user wants to delete build output.","signature":"sig"}'
expected_wire="D"$'\t'"rm -rf build"$'\n'"D"$'\t'"git clean -fdX"$'\n'"S"$'\t'"ls build"

payload_field() {
  command jq -c "$1" "$MOCK_DIR/payload"
}

print "=== Response parsing ==="

mock_response "[$thinking_block,$text_block]"
result=$(_zsh_ai_cmd_anthropic_call "delete build dir" "$_ZSH_AI_CMD_PROMPT")
assert_equals "thinking block before text block yields the text answer" "$expected_wire" "$result"

mock_response "[$text_block]"
result=$(_zsh_ai_cmd_anthropic_call "delete build dir" "$_ZSH_AI_CMD_PROMPT")
assert_equals "text block alone yields the answer" "$expected_wire" "$result"

mock_response "[$thinking_block]"
result=$(_zsh_ai_cmd_anthropic_call "delete build dir" "$_ZSH_AI_CMD_PROMPT")
rc=$?
assert_equals "thinking block alone yields no output" "" "$result"
assert_equals "thinking block alone returns nonzero" "1" "$(( rc != 0 ))"

print ""
print "=== Stop reasons ==="

stderr_file="$MOCK_DIR/stderr"

mock_response "[$thinking_block]" max_tokens
result=$(_zsh_ai_cmd_anthropic_call "delete build dir" "$_ZSH_AI_CMD_PROMPT" 2>"$stderr_file")
rc=$?
assert_equals "max_tokens stop returns nonzero" "1" "$(( rc != 0 ))"
assert_equals "max_tokens stop yields no output" "" "$result"
assert_contains "max_tokens stop explains the cutoff" "response cut off at max_tokens; lower ZSH_AI_CMD_ANTHROPIC_EFFORT" "$(cat "$stderr_file")"

mock_response '[]' refusal
result=$(_zsh_ai_cmd_anthropic_call "delete build dir" "$_ZSH_AI_CMD_PROMPT" 2>"$stderr_file")
rc=$?
assert_equals "refusal returns nonzero" "1" "$(( rc != 0 ))"
assert_contains "refusal explains the decline" "model declined the request" "$(cat "$stderr_file")"

mock_response "[$thinking_block,$text_block]" end_turn
result=$(_zsh_ai_cmd_anthropic_call "delete build dir" "$_ZSH_AI_CMD_PROMPT" 2>"$stderr_file")
rc=$?
assert_equals "end_turn returns zero" "0" "$rc"
assert_equals "end_turn yields the answer" "$expected_wire" "$result"
assert_equals "end_turn writes nothing to stderr" "" "$(cat "$stderr_file")"

print ""
print "=== Request payload ==="

mock_response "[$text_block]"
_zsh_ai_cmd_anthropic_call "delete build dir" "$_ZSH_AI_CMD_PROMPT" >/dev/null
assert_equals "no deprecated output_format" "false" "$(payload_field 'has("output_format")')"
assert_equals "structured output sent as output_config.format" '"json_schema"' "$(payload_field '.output_config.format.type')"
assert_equals "schema sent in output_config.format" "$(command jq -c . <<< "$_ZSH_AI_CMD_SCHEMA")" "$(payload_field '.output_config.format.schema')"
assert_equals "max_tokens leaves room for thinking" "4096" "$(payload_field '.max_tokens')"
assert_equals "no thinking param" "false" "$(payload_field 'has("thinking")')"
beta_headers=$(command grep -ci '^anthropic-beta:' "$MOCK_DIR/headers")
assert_equals "no anthropic-beta header" "0" "$beta_headers"

print ""
print "=== Effort setting ==="

UNSET='<unset>'

# Prints the request's output_config (compact JSON) for MODEL with the effort
# setting EFFORT, where $UNSET leaves the variable unset. The provider applies
# its effort default when sourced, so each case re-sources it in a subshell.
request_output_config() {
  local model=$1 effort=$2
  (
    if [[ $effort == "$UNSET" ]]; then
      unset ZSH_AI_CMD_ANTHROPIC_EFFORT
    else
      ZSH_AI_CMD_ANTHROPIC_EFFORT=$effort
    fi
    ZSH_AI_CMD_ANTHROPIC_MODEL=$model
    source "$SCRIPT_DIR/providers/anthropic.zsh"
    _zsh_ai_cmd_anthropic_call "delete build dir" "$_ZSH_AI_CMD_PROMPT" >/dev/null
    payload_field '.output_config'
  )
}

opus_default=$(request_output_config claude-opus-5-5 "$UNSET")
assert_equals "default effort is low for Opus" '"low"' "$(command jq -c '.effort' <<< "$opus_default")"
assert_equals "format kept alongside effort" '"json_schema"' "$(command jq -c '.format.type' <<< "$opus_default")"

assert_equals "default effort not sent to Haiku 4.5" "false" \
  "$(request_output_config claude-haiku-4-5-20251001 "$UNSET" | command jq -c 'has("effort")')"
assert_equals "default effort not sent to Sonnet 4.5" "false" \
  "$(request_output_config claude-sonnet-4-5-20250929 "$UNSET" | command jq -c 'has("effort")')"
assert_equals "explicitly empty effort sends none to Opus" "false" \
  "$(request_output_config claude-opus-5-5 '' | command jq -c 'has("effort")')"
assert_equals "medium effort sent to Opus" '"medium"' \
  "$(request_output_config claude-opus-5-5 medium | command jq -c '.effort')"

print ""
print "================================"
print "Results: $PASS passed, $FAIL failed"

((FAIL > 0)) && exit 1 || exit 0
