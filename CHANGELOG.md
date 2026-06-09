# Changelog

All notable changes to zsh-ai-cmd are documented in this file.

## [v0.3.0] - 2026-06-09

### Added
- **Capability grounding** — suggestions are now grounded in the tools actually
  installed on your machine, not the model's training priors
  - Probes a curated set of modern alternatives, GNU coreutils, and dev/cloud
    tools once per shell session (pure-zsh `$commands` lookup, no subprocesses)
  - Detected tools are passed to the model via the `<context>` block; the prompt
    now prefers modern alternatives when available (`rg` over `grep`, `fd` over
    `find`) and never suggests a tool that is neither standard nor installed
  - Probe list is configurable via `ZSH_AI_CMD_PROBE_TOOLS`
  - The benchmark harness pins a fixed synthetic capability set (including
    `rg`/`fd`/`eza`) for cross-machine reproducibility, and `alternates.json`
    carries both standard and modern accepted variants so correct substitutions
    score as exact/review rather than being penalized
- **LM Studio Provider** (`ZSH_AI_CMD_PROVIDER='lmstudio'`)
  - Local inference via LM Studio's OpenAI-compatible API server
  - No API key required — runs entirely on your machine
  - Configurable host via `ZSH_AI_CMD_LMSTUDIO_HOST` (default: `localhost:1234`)
  - Configurable model via `ZSH_AI_CMD_LMSTUDIO_MODEL` (default: `qwen2.5-coder-7b-instruct`)
  - Structured JSON output via `response_format` for reliable command extraction
  - `--max-time 60` on the completion request to prevent terminal hangs on stalled models
  - Surfaces API error responses (model not loaded, unsupported format) instead of returning empty suggestions

### Configuration
```sh
export ZSH_AI_CMD_PROVIDER='lmstudio'

# Optional: change default model
export ZSH_AI_CMD_LMSTUDIO_MODEL='qwen2.5-coder-7b-instruct'

# Optional: custom host/port
export ZSH_AI_CMD_LMSTUDIO_HOST='localhost:1234'
```

LM Studio must be running with its local server started (default `localhost:1234`).

### Credits
Thanks to @marshal-81 for the LM Studio provider (#18).

## [v0.2.0] - 2026-04-08

### Added
- **Claude Code Provider** (`ZSH_AI_CMD_PROVIDER='claude-code'`)
  - Use your Claude subscription (Max/Pro/Enterprise) instead of an API key
  - Routes through the Claude Code CLI (`claude -p`) in pipe mode
  - No API key required — authenticates via `claude login`
  - Optimized startup flags cut latency from ~8s to ~3-5s per call
  - Uses CLI's default model; override with `ZSH_AI_CMD_CLAUDE_CODE_MODEL`
  - Text output mode for faster responses (matches copilot provider approach)

### Configuration
```sh
export ZSH_AI_CMD_PROVIDER='claude-code'

# Optional: pin a specific model (empty = CLI default)
export ZSH_AI_CMD_CLAUDE_CODE_MODEL='haiku'
```

### Performance Notes
Slower than direct API providers (~3-5s vs ~1-3s) due to CLI startup overhead.
Best suited for users who prefer using their existing Claude subscription over
separate API billing.

### Testing
- All 19 API validation tests pass with claude-code provider
- Added claude-code to test-api.sh test suite
- Updated README.md and CLAUDE.md with provider documentation

### Credits
Thanks to @ohare93 for the original implementation in #12 and #17.

---

## [v0.1.0] - 2026-01-26

### Added
- **Custom API Key Command Support** (`ZSH_AI_CMD_API_KEY_COMMAND`)
  - Retrieve API keys via custom commands (e.g., `secret-tool`, `pass`, 1Password CLI, AWS Secrets Manager)
  - Dynamic `${provider}` expansion in command string
  - Case normalization for provider handling (ANTHROPIC, Anthropic, anthropic all work)
  - Automatic output sanitization (strips control chars and escape sequences)
  - Secure debug logging (never logs actual key values)
  - Silent fallback to Keychain if command fails
  - Opt-in feature (empty default, no behavior change without config)

### API Key Retrieval Sequence
Keys are now retrieved in this order:
1. Environment variables (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.)
2. Custom command (`ZSH_AI_CMD_API_KEY_COMMAND` with `${provider}` expansion) — if configured
3. macOS Keychain (`ZSH_AI_CMD_KEYCHAIN_NAME`)

### Examples
```sh
# Linux with GNOME Keyring
export ZSH_AI_CMD_API_KEY_COMMAND='secret-tool lookup service ${provider}'

# pass password manager
export ZSH_AI_CMD_API_KEY_COMMAND='pass show ${provider}-api-key'

# 1Password CLI
export ZSH_AI_CMD_API_KEY_COMMAND='op read op://Private/${provider}-api-key'

# AWS Secrets Manager
export ZSH_AI_CMD_API_KEY_COMMAND='aws secretsmanager get-secret-value --secret-id ${provider}-api-key --query SecretString --output text'
```

### Testing
- Added 21 comprehensive feature tests in `test-api-key-command.sh`
- All 19 existing API validation tests pass
- Full backwards compatibility verified
- Case normalization tests included

### Documentation
- Updated README.md with new "Custom API Key Retrieval" section
- Updated CLAUDE.md with API Key Retrieval details
- Added this CHANGELOG.md
- Created VERSION file for runtime version checking

---

## Release Notes

**Initial Release**: Implements custom command-based API key retrieval as requested in #11. Design emphasizes security, flexibility, and backwards compatibility.
