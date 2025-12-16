# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

zsh-ai-cmd is a single-file zsh plugin that translates natural language to shell commands using the Anthropic API. User types a description, presses `Ctrl+Z`, and gets executable shell output.

## Architecture

The entire plugin lives in @zsh-ai-cmd.plugin.zsh . Key components:

- **Widget function** `_zsh_ai_cmd_suggest`: Main entry point bound to keybinding. Captures buffer text, builds API payload, calls API, replaces buffer with suggestion.
- **API call** `_zsh_ai_cmd_call_api`: Background curl with animated braille spinner. Uses ZLE redraw for UI updates during blocking wait.
- **Key retrieval** `_zsh_ai_cmd_get_key`: Lazy-loads API key from env var or macOS Keychain.

## Testing

Replicated prompt and API tests live in @test-api.sh

```sh
# Source the plugin directly
source ./zsh-ai-cmd.plugin.zsh

# Type natural language, press Ctrl+Z
list files modified today<Ctrl+Z>
```

Enable debug logging:
```sh
ZSH_AI_CMD_DEBUG=true
tail -f /tmp/zsh-ai-cmd.log
```

## Code Conventions

- Uses `command` prefix (e.g., `command curl`, `command jq`) to bypass user aliases
- All configuration via `typeset -g` globals with `ZSH_AI_CMD_` prefix
- Internal functions/variables use `_zsh_ai_cmd_` or `_ZSH_AI_CMD_` prefix
- Pure zsh where possible; external deps limited to `curl`, `jq`, `security` (macOS)

## ZLE Widget Constraints

When modifying the spinner or UI code:
- `zle -R` forces redraw within widget context
- `zle -M` shows messages in minibuffer
- Background jobs need `NO_NOTIFY NO_MONITOR` to suppress job control noise
- `read -t 0.08` provides non-blocking sleep without external deps
