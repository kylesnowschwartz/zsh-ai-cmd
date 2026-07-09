#!/usr/bin/env zsh
# prompt.zsh - Shared system prompt for zsh-ai-cmd
# Sourced by both the plugin and test script

typeset -g _ZSH_AI_CMD_PROMPT='Translate natural language to a single shell command.

RULES:
- Output EXACTLY ONE command, nothing else
- No explanations, no alternatives, no markdown
- No code blocks, no backticks
- If ambiguous, pick the most reasonable interpretation
- Prefix standard tools with `command` to bypass aliases

EFFICIENCY:
- Avoid spawning processes per item: use -exec {} + not -exec {} \;
- Use built-in formatting where available (not piping to awk/sed)
- Add limits on unbounded searches: head, -maxdepth, 2>/dev/null for errors
- Prefer human-readable output where appropriate (-h flags for sizes)

PLATFORM:
- Check <context> for OS before suggesting commands
- Use BSD-compatible flags on macOS, GNU flags on Linux - they are not interchangeable
- Prefer POSIX-compatible commands when platform-agnostic alternatives exist

TOOLS:
- A tool may be used ONLY if it is a standard POSIX/system utility or it appears in <context> Available
- When a modern alternative is listed in Available, prefer it: rg over grep, fd over find, eza over ls, bat over cat
- On macOS, if a GNU variant is listed in Available (gdate, gsed, gawk), use it instead of working around BSD flag limitations
- Never suggest a tool that is neither a standard utility nor listed in Available

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

User: what time is it in tokyo
TZ="Asia/Tokyo" command date "+%H:%M:%S %Z"

User: sort file fast by byte order
LC_ALL=C command sort file.txt

User: edit crontab with nano
EDITOR=nano command crontab -e
</examples>'

# Extra guidance for providers with structured (JSON) output. Text-mode
# providers (copilot, claude-code) must NOT receive this: they rely on the
# base prompt's single-command rule.
typeset -g _ZSH_AI_CMD_PROMPT_STRUCTURED='
ALTERNATIVES:
- Fill "alternatives" with up to 2 meaningfully different approaches (a different tool or strategy, not flag variations)
- When both a standard utility and a modern tool from Available can do the job, the primary uses one and "alternatives" offers the other
- Order by preference; "command" holds the best option
- Leave "alternatives" empty only when no genuinely different approach exists

DESTRUCTIVE:
- Mark "destructive": true for any command that deletes or overwrites data, kills processes, rewrites git history, or is otherwise hard to undo'

# Shared structured-output JSON schema — single source of truth for the five
# schema-capable providers. Gemini's responseSchema dialect rejects
# additionalProperties; its provider strips those keys inline (see gemini.zsh).
typeset -g _ZSH_AI_CMD_SCHEMA='{
  "type": "object",
  "properties": {
    "command": {"type": "string", "description": "The best shell command"},
    "destructive": {"type": "boolean", "description": "True when the command deletes/overwrites data, kills processes, or is otherwise hard to undo"},
    "alternatives": {
      "type": "array",
      "description": "Up to 2 meaningfully different alternative commands; empty when one approach is clearly best",
      "items": {
        "type": "object",
        "properties": {
          "command": {"type": "string"},
          "destructive": {"type": "boolean"}
        },
        "required": ["command", "destructive"],
        "additionalProperties": false
      }
    }
  },
  "required": ["command", "destructive", "alternatives"],
  "additionalProperties": false
}'

# Shared jq filter: converts the structured JSON object into the provider wire
# format consumed by the widget — one suggestion per line, "D<TAB>command" for
# destructive commands, "S<TAB>command" otherwise. Hardened against shape drift
# (DeepSeek's json_object mode has no server-side schema): non-array
# alternatives and non-object elements are ignored rather than aborting the
# whole stream, non-string commands are skipped, and string booleans count as
# destructive.
typeset -g _ZSH_AI_CMD_JQ_EMIT='([{command, destructive}]
    + ((.alternatives // []) | if type == "array" then map(select(type == "object")) else [] end))
  | .[]
  | select((.command | type) == "string" and (.command | length) > 0)
  | (if .destructive == true or .destructive == "true" then "D" else "S" end) + "\t" + (.command | gsub("\n"; " "))'

typeset -g _ZSH_AI_CMD_CONTEXT='<context>
OS: $_ZSH_AI_CMD_OS
Shell: ${SHELL:t}
PWD: $PWD
Available: $_ZSH_AI_CMD_CAPS
</context>'
