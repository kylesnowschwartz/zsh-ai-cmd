#!/usr/bin/env zsh
# test-api.sh - Validate API responses for format compliance
# Usage: ./test-api.sh

set -uo pipefail

SCRIPT_DIR="${0:a:h}"

# Source plugin for config (ignore ZLE errors)
typeset -g ZSH_AI_CMD_MODEL=${ZSH_AI_CMD_MODEL:-'claude-haiku-4-5-20251001'}

# Load prompt and OS detection from plugin
typeset -g _ZSH_AI_CMD_OS
if [[ $OSTYPE == darwin* ]]; then
    _ZSH_AI_CMD_OS="macOS $(sw_vers -productVersion 2>/dev/null || print 'unknown')"
else
    _ZSH_AI_CMD_OS="Linux"
fi

# System prompt (duplicated from plugin to avoid ZLE dependency)
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

# Get API key
get_api_key() {
    [[ -n ${ANTHROPIC_API_KEY:-} ]] && return 0
    ANTHROPIC_API_KEY=$(security find-generic-password \
        -s "anthropic-api-key" -a "$USER" -w 2>/dev/null) || {
        print -u2 "ANTHROPIC_API_KEY not found in env or keychain"
        return 1
    }
}
typeset -g ANTHROPIC_API_KEY

PASS=0
FAIL=0

# Test cases: description -> expected characteristics
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
)

validate_output() {
    local output=$1
    local errors=()

    # Must not be empty
    [[ -z $output ]] && errors+=("empty output")

    # No markdown code blocks
    [[ $output == *'```'* ]] && errors+=("contains code fence")

    # No backticks at all
    [[ $output == *'`'* ]] && errors+=("contains backticks")

    # Single line only
    [[ $output == *$'\n'* ]] && errors+=("multi-line output")

    # No explanatory text patterns
    [[ $output == *"Or "* ]] && errors+=("contains alternatives")
    [[ $output == *"you can"* ]] && errors+=("contains explanation")
    [[ $output == *"Note:"* ]] && errors+=("contains note")
    [[ $output == *"#"* && $output != *"xargs"* ]] && errors+=("contains comment")

    # Should look like a command (starts with word char or path)
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

    local response
    response=$(command curl -sS --max-time 30 "https://api.anthropic.com/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: structured-outputs-2025-11-13" \
        -d "$payload")

    # Check for API error
    local err=$(print -r -- "$response" | command jq -r '.error.message // empty')
    if [[ -n $err ]]; then
        print -r -- "API_ERROR: $err"
        return 1
    fi

    # Extract command from structured output
    local cmd=$(print -r -- "$response" | command jq -re '.content[0].text | fromjson | .command // empty' 2>/dev/null)
    if [[ -z $cmd ]]; then
        # Fallback: try plain text extraction
        cmd=$(print -r -- "$response" | command jq -re '.content[0].text // empty' 2>/dev/null)
    fi

    print -r -- "$cmd"
}

run_test() {
    local input=$1
    local category=$2

    printf "%-50s " "$input"

    local output
    output=$(call_api "$input")
    local api_status=$?

    if [[ $output == API_ERROR:* ]]; then
        print -P "%F{red}API ERROR%f: ${output#API_ERROR: }"
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

main() {
    print "Testing zsh-ai-cmd API responses"
    print "Model: $ZSH_AI_CMD_MODEL"
    print "================================"
    print ""

    # Ensure API key is available
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
