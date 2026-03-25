# Contributing

## Setup

1. Clone the repo
2. Source the plugin: `source ./zsh-ai-cmd.plugin.zsh`
3. Type a natural language description, press Ctrl+Z

## Testing

Tests are integration tests that hit real APIs. Run them locally before
submitting:

    ./test-api.sh                      # default (anthropic)
    ./test-api.sh --provider openai    # specific provider
    ./test-api-key-command.sh          # API key retrieval
    ./test-openai-base-url.sh          # custom base URL
    ./test-sanitize.sh                 # output sanitization

Run whichever scripts are relevant to your change.

Enable debug logging:

    ZSH_AI_CMD_DEBUG=true
    tail -f /tmp/zsh-ai-cmd.log

## What makes a good PR

- **Small and focused.** One feature or fix per PR. Bulk changes get closed.
- **Tested.** Show test output and describe manual testing in the PR.
- **Considered.** Think about edge cases: what happens when the API is
  slow, returns unexpected output, or is unreachable?
- **Conventional.** Read the existing code first. Use `command` prefix for
  external calls, `_zsh_ai_cmd_` for internal names, `typeset -g` for
  config. Pure zsh where possible.

## Adding a provider

Look at the existing providers in `providers/`. Each one exports two
functions:

- `_zsh_ai_cmd_<provider>_call "$input" "$prompt"` - API call, prints
  command to stdout
- `_zsh_ai_cmd_<provider>_key_error` - prints setup instructions

Use structured output (JSON schema) where the API supports it.

Files to update when adding a provider:

- `providers/<name>.zsh` - provider implementation
- `zsh-ai-cmd.plugin.zsh` - add `source` line and case in
  `_zsh_ai_cmd_call_api`
- `test-api.sh` - add provider to test suite
