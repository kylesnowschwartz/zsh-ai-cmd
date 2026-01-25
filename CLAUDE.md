# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

zsh-ai-cmd is a zsh plugin that translates natural language to shell commands using LLM APIs. User types a description, presses `Ctrl+Z`, and sees the suggestion as ghost text. Tab accepts, typing dismisses.

## Architecture

The main plugin lives in @zsh-ai-cmd.plugin.zsh with provider implementations in `providers/`.

### Supported Providers

 | Provider   | File                      | Default Model               | API Key Env Var     |
 | ---------- | ------                    | ---------------             | -----------------   |
 | Anthropic  | `providers/anthropic.zsh` | `claude-haiku-4-5-20251001` | `ANTHROPIC_API_KEY` |
 | OpenAI     | `providers/openai.zsh`    | `gpt-5.2-2025-12-11`        | `OPENAI_API_KEY`    |
 | Gemini     | `providers/gemini.zsh`    | `gemini-3-flash-preview`    | `GEMINI_API_KEY`    |
 | DeepSeek   | `providers/deepseek.zsh`  | `deepseek-chat`             | `DEEPSEEK_API_KEY`  |
 | Ollama     | `providers/ollama.zsh`    | `mistral-small`             | (none - local)      |
 | Copilot    | `providers/copilot.zsh`   | `gpt-4o`                    | (none - local)      |

Set provider via `ZSH_AI_CMD_PROVIDER='openai'` (default: `anthropic`).

**Note:** Copilot requires [copilot-api](https://github.com/ericc-ch/copilot-api) to be running. Install and start with `npx copilot-api start`.

### API Key Retrieval

Keys are retrieved in this order:
1. Environment variables (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.)
2. Custom command (`ZSH_AI_CMD_API_KEY_COMMAND` with `${provider}` expansion) — if configured
3. macOS Keychain (`ZSH_AI_CMD_KEYCHAIN_NAME`)

**Example custom command**:
```sh
export ZSH_AI_CMD_API_KEY_COMMAND='secret-tool lookup service ${provider}'
```

### Provider Implementation

Each provider file exports two functions:
- `_zsh_ai_cmd_<provider>_call "$input" "$prompt"` - Makes API call, prints command to stdout
- `_zsh_ai_cmd_<provider>_key_error` - Prints setup instructions when API key missing

All providers use structured outputs (JSON schema) where supported for reliable command extraction. The system prompt is shared across providers via `$_ZSH_AI_CMD_PROMPT` from `prompt.zsh`.

### Core Components

**Core Flow:**
- **Widget function** `_zsh_ai_cmd_suggest`: Main entry point bound to keybinding. Captures buffer text, shows spinner, calls API, displays result as ghost text via `POSTDISPLAY`.
- **API call** `_zsh_ai_cmd_call_api`: Background curl with animated braille spinner. Uses ZLE redraw for UI updates during blocking wait.
- **Key retrieval** `_zsh_ai_cmd_get_key`: Lazy-loads API key from env var or macOS Keychain.

**Ghost Text System:**
- **`_zsh_ai_cmd_show_ghost`**: Displays suggestion in `POSTDISPLAY`. If suggestion extends current buffer, shows suffix only. Otherwise shows ` ⇥ suggestion`.

**State Machine:**
- **`_zsh_ai_cmd_activate`**: Called after suggestion shown. Captures current Tab/right-arrow bindings, temporarily overrides them.
- **`_zsh_ai_cmd_deactivate`**: Restores original bindings, clears ghost text and state. Called on accept or buffer divergence.
- **`_zsh_ai_cmd_pre_redraw`**: Hook that detects buffer changes. If buffer diverges from suggestion, deactivates.
- **`_zsh_ai_cmd_accept`**: Tab handler. Accepts suggestion into buffer or falls through to original Tab binding.
- **`_zsh_ai_cmd_accept_arrow`**: Right arrow handler. Accepts suggestion or falls through to original binding.

## Testing

API response validation tests live in @test-api.sh:

```sh
# Test default provider (anthropic)
./test-api.sh

# Test specific provider
./test-api.sh --provider openai
./test-api.sh --provider gemini
./test-api.sh --provider ollama
./test-api.sh --provider deepseek
```

Manual testing:
```sh
source ./zsh-ai-cmd.plugin.zsh
# Type natural language, press Ctrl+Z
list files modified today<Ctrl+Z>
```

Enable debug logging:
```sh
ZSH_AI_CMD_DEBUG=true
tail -f ${ZSH_AI_CMD_LOG:-/tmp/zsh-ai-cmd.log}
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
- `read -t 0.1` provides non-blocking sleep without external deps

**Dormant/Active State Machine:**
The plugin uses a state machine to avoid conflicts with other plugins (like zsh-autosuggestions):
- **Dormant** (default): Only `Ctrl+Z` trigger bound. Tab/right-arrow work normally.
- **Active** (after Ctrl+Z shows suggestion): Tab/right-arrow temporarily bound to accept. Uses `zle-line-pre-redraw` hook to detect buffer changes.
- **Deactivate** (on accept/dismiss): Restore original bindings, clear state.

This design avoids permanent widget wrapping, so other plugins' `self-insert` wrappers see buffer changes normally. The idempotency guard at the top prevents double-loading if the plugin is sourced multiple times.
