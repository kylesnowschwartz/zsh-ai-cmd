#!/usr/bin/env zsh
# test-sanitize.sh - Unit tests for output sanitization
# Usage: ./test-sanitize.sh

set -uo pipefail

SCRIPT_DIR="${0:a:h}"

# Source the sanitize function from the plugin
# We need to define it here since the plugin guards against non-ZLE context
_zsh_ai_cmd_sanitize() {
  setopt local_options extended_glob
  local input=$1
  local sanitized=$input
  local esc=$'\x1b'

  # 1. Strip ANSI CSI escape sequences FIRST: ESC [ params letter
  while [[ $sanitized == *${esc}\[* ]]; do
    sanitized=${sanitized//${esc}\[[0-9;]#[A-Za-z]/}
  done

  # 2. Strip any remaining ESC characters (non-CSI escapes)
  sanitized=${sanitized//${esc}/}

  # 3. Strip control characters (0x00-0x1F except tab 0x09, and DEL 0x7F)
  sanitized=${sanitized//[$'\x00'-$'\x08'$'\x0a'-$'\x1f'$'\x7f']/}

  # 4. Trim leading/trailing whitespace
  sanitized=${sanitized##[[:space:]]##}
  sanitized=${sanitized%%[[:space:]]##}

  print -r -- "$sanitized"
}

PASS=0
FAIL=0

run_test() {
    local name=$1
    local input=$2
    local expected=$3

    local actual
    actual=$(_zsh_ai_cmd_sanitize "$input")

    printf "%-45s " "$name"
    if [[ $actual == $expected ]]; then
        print -P "%F{green}PASS%f"
        ((PASS++))
    else
        print -P "%F{red}FAIL%f"
        print "  input:    $(print -r -- "$input" | cat -v)"
        print "  expected: $(print -r -- "$expected" | cat -v)"
        print "  actual:   $(print -r -- "$actual" | cat -v)"
        ((FAIL++))
    fi
}

main() {
    print "Testing sanitization function"
    print "=============================="
    print ""

    # Basic passthrough
    run_test "clean command passes through" \
        "ls -la" \
        "ls -la"

    run_test "command with pipes" \
        "ps aux | grep nginx | awk '{print \$2}'" \
        "ps aux | grep nginx | awk '{print \$2}'"

    # Newline injection (most critical security issue)
    run_test "strips newlines (multi-command injection)" \
        $'echo hidden\necho visible' \
        "echo hiddenecho visible"

    run_test "strips carriage return" \
        $'malicious\rgood' \
        "maliciousgood"

    # Control characters
    run_test "strips null bytes" \
        $'ls\x00 -la' \
        "ls -la"

    run_test "strips bell character" \
        $'echo\x07test' \
        "echotest"

    run_test "strips backspace (visual deception)" \
        $'echo bad\x08\x08\x08\x08\x08\x08\x08ls' \
        "echo badls"

    # ANSI escape sequences
    run_test "strips ANSI color codes" \
        $'\x1b[31mecho test\x1b[0m' \
        "echo test"

    run_test "strips ANSI cursor movement" \
        $'\x1b[2Ahidden\x1b[2Bvisible' \
        "hiddenvisible"

    run_test "strips complex ANSI sequence" \
        $'\x1b[38;5;196mred text\x1b[0m' \
        "red text"

    # Whitespace trimming
    run_test "trims leading whitespace" \
        "  ls -la" \
        "ls -la"

    run_test "trims trailing whitespace" \
        "ls -la  " \
        "ls -la"

    # Tab is preserved (legitimate in commands)
    run_test "preserves tab characters" \
        $'echo\t"hello"' \
        $'echo\t"hello"'

    # Combined attacks
    run_test "combined: newline + ANSI" \
        $'\x1b[8m\necho hidden\x1b[0m\necho done' \
        "echo hiddenecho done"

    # Empty after sanitization
    run_test "control-only input becomes empty" \
        $'\x00\x01\x02' \
        ""

    print ""
    print "=============================="
    print "Results: $PASS passed, $FAIL failed"

    (( FAIL > 0 )) && exit 1
    exit 0
}

main "$@"
