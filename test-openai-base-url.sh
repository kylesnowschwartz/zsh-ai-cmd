#!/usr/bin/env zsh
# test-openai-base-url.sh - Integration tests for ZSH_AI_CMD_OPENAI_BASE_URL feature
# Tests that the custom base URL variable defaults correctly and is used for requests
# Usage: ./test-openai-base-url.sh

set -o pipefail

SCRIPT_DIR="${0:a:h}"
PASS=0
FAIL=0

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

# ============================================================================
# Test 1: Default value
# ============================================================================

print "=== Default Value Test ==="
print ""

# Unset any existing value so the default kicks in
unset ZSH_AI_CMD_OPENAI_BASE_URL

# Source provider file directly (not the full plugin - avoids ZLE widget setup)
source "${SCRIPT_DIR}/providers/openai.zsh" 2>/dev/null

assert_equals \
  "ZSH_AI_CMD_OPENAI_BASE_URL defaults to OpenAI endpoint" \
  "https://api.openai.com/v1/chat/completions" \
  "$ZSH_AI_CMD_OPENAI_BASE_URL"

# ============================================================================
# Test 2: Override is respected (typeset -g ${VAR:-default} pattern)
# ============================================================================

print ""
print "=== Override Test ==="
print ""

# Set a custom URL before sourcing - the ${VAR:-default} pattern must not overwrite it
unset ZSH_AI_CMD_OPENAI_BASE_URL
export ZSH_AI_CMD_OPENAI_BASE_URL='http://localhost:9999/v1/chat/completions'

# Re-source to simulate what happens when plugin loads after user sets the var
source "${SCRIPT_DIR}/providers/openai.zsh" 2>/dev/null

assert_equals \
  "Pre-set ZSH_AI_CMD_OPENAI_BASE_URL is preserved after sourcing" \
  "http://localhost:9999/v1/chat/completions" \
  "$ZSH_AI_CMD_OPENAI_BASE_URL"

# ============================================================================
# Test 3: Integration - request routes to custom URL
# ============================================================================

print ""
print "=== Integration Test: Request Routes to Custom URL ==="
print ""

# Check python3 is available
if ! command -v python3 &>/dev/null; then
  print -P "%F{yellow}⚠ SKIP%f: Integration test requires python3"
  print ""
  print "================================"
  print "Results: $PASS passed, $FAIL failed (1 skipped)"
  (( FAIL > 0 )) && exit 1 || exit 0
fi

MOCK_PORT=19876
MOCK_REQUEST_FILE=$(mktemp)
MOCK_SCRIPT=$(mktemp /tmp/mock_server_XXXXXX.py)
MOCK_PID=""

# Clean up on exit
trap 'kill $MOCK_PID 2>/dev/null; rm -f "$MOCK_REQUEST_FILE" "$MOCK_SCRIPT"' EXIT INT TERM

# Write Python mock server to a temp file (avoids heredoc/shell-expansion conflicts)
python3 -c "
import sys, json
script = '''
import sys, json
from http.server import HTTPServer, BaseHTTPRequestHandler

port = int(sys.argv[1])
request_file = sys.argv[2]

class MockHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get(\"Content-Length\", 0))
        body = self.rfile.read(length).decode()
        with open(request_file, \"w\") as f:
            f.write(body)
        response = json.dumps({
            \"choices\": [{\"message\": {\"content\": json.dumps({\"command\": \"ls -la\"})}}]
        }).encode()
        self.send_response(200)
        self.send_header(\"Content-Type\", \"application/json\")
        self.send_header(\"Content-Length\", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, fmt, *args):
        pass

HTTPServer((\"127.0.0.1\", port), MockHandler).serve_forever()
'''
print(script)
" > "$MOCK_SCRIPT"

# Start mock server in background
python3 "$MOCK_SCRIPT" "$MOCK_PORT" "$MOCK_REQUEST_FILE" &
MOCK_PID=$!

# Give server a moment to start
sleep 0.4

# Verify server is up before testing
if ! kill -0 $MOCK_PID 2>/dev/null; then
  print -P "%F{red}✗ FAIL%f: Mock server failed to start"
  ((FAIL++))
else
  # Source prompt and provider (reset guard variable so re-source works)
  unfunction _zsh_ai_cmd_suggest 2>/dev/null || true
  unset ZSH_AI_CMD_OPENAI_BASE_URL

  export ZSH_AI_CMD_OPENAI_BASE_URL="http://127.0.0.1:${MOCK_PORT}/v1/chat/completions"
  export OPENAI_API_KEY="test-key-for-mock"
  export ZSH_AI_CMD_DEBUG=false

  source "${SCRIPT_DIR}/prompt.zsh" 2>/dev/null
  source "${SCRIPT_DIR}/providers/openai.zsh" 2>/dev/null

  # Call the provider directly
  result=$(_zsh_ai_cmd_openai_call "list files" "$_ZSH_AI_CMD_PROMPT" 2>/dev/null)

  assert_equals \
    "Provider returns command parsed from mock response" \
    "ls -la" \
    "$result"

  # Verify the request actually hit our mock
  if [[ -s $MOCK_REQUEST_FILE ]]; then
    request_body=$(<$MOCK_REQUEST_FILE)
    assert_contains \
      "Request body contains the user input" \
      "list files" \
      "$request_body"
  else
    print -P "%F{red}✗ FAIL%f: Request body captured from mock (file empty - server not hit)"
    ((FAIL++))
  fi
fi

# ============================================================================
# Summary
# ============================================================================

print ""
print "================================"
print "Results: $PASS passed, $FAIL failed"

(( FAIL > 0 )) && exit 1 || exit 0
