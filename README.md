# zsh-ai-cmd

Natural language to shell commands with ghost text preview.

![Demo](assets/preview.gif)

## Install

Requires `curl`, `jq`, and an API key for your chosen provider.

```sh
# Clone
git clone https://github.com/kylesnowschwartz/zsh-ai-cmd ~/.zsh-ai-cmd

# Add to .zshrc
source ~/.zsh-ai-cmd/zsh-ai-cmd.plugin.zsh

# Choose your provider (default: anthropic)
export ZSH_AI_CMD_PROVIDER='anthropic'  # or: openai, gemini, deepseek, ollama

# Set API key for your chosen provider
export ANTHROPIC_API_KEY='sk-ant-...'
export OPENAI_API_KEY='sk-...'
export GEMINI_API_KEY='...'
export DEEPSEEK_API_KEY='sk-...'
# Ollama needs no key (local)

# Or use macOS Keychain
security add-generic-password -s 'anthropic-api-key' -a "$USER" -w 'sk-ant-...'
```

## Usage

1. Type a natural language description
2. Press `Ctrl+Z` to request a suggestion
3. Ghost text appears showing the command: `find large files → find . -size +100M`
4. Press `Tab` or `→` to accept, or keep typing to dismiss

## Configuration

```sh
ZSH_AI_CMD_PROVIDER='anthropic'              # Provider: anthropic, openai, gemini, deepseek, ollama
ZSH_AI_CMD_KEY='^z'                          # Trigger key (default: Ctrl+Z)
ZSH_AI_CMD_HIGHLIGHT='fg=8'                  # Ghost text style (zsh region_highlight format)
ZSH_AI_CMD_DEBUG=false                       # Enable debug logging
ZSH_AI_CMD_LOG=/tmp/zsh-ai-cmd.log           # Debug log path

# Provider-specific models (defaults shown)
ZSH_AI_CMD_ANTHROPIC_MODEL='claude-haiku-4-5-20251001'
ZSH_AI_CMD_OPENAI_MODEL='gpt-5.2-2025-12-11'
ZSH_AI_CMD_GEMINI_MODEL='gemini-3-flash-preview'
ZSH_AI_CMD_DEEPSEEK_MODEL='deepseek-chat'
ZSH_AI_CMD_OLLAMA_MODEL='mistral-small'
```

## Provider Comparison

All providers pass the test suite (19/19). Full output comparison:

<details>
<summary>Click to expand full comparison table</summary>

```
PROMPT                                                      ANTHROPIC                                    OPENAI                                       GEMINI                                       OLLAMA
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
list files                                                  ls -la                                       ls -la                                       ls -la                                       ls -la
find python files modified today                            find . -name "*.py" -mtime -1                find . -name "*.py" -mtime -1                find . -name "*.py" -mtime -1                find . -name "*.py" -mtime -1
search for TODO in js files                                 grep -r "TODO" --include="*.js" .            grep -r "TODO" --include="*.js" .            grep -r "TODO" --include="*.js" .            grep -r "TODO" --include="*.js" .
show disk usage by folder                                   du -h -d 1 | sort -hr                        du -h -d 1 | sort -hr | head -20             du -h -d 1 | sort -hr                        du -h -d 1 | sort -hr | head -20
kill process on port 3000                                   lsof -ti:3000 | xargs kill -9                lsof -ti:3000 | xargs kill -9                lsof -ti:3000 | xargs kill -9                lsof -t -i :3000 | xargs kill -9
consolidate git worktree into primary repo                  git worktree remove .                        git worktree remove .                        git worktree remove .                        git worktree remove .
find all files larger than 100mb and delete them            find . -type f -size +100m -delete           find . -size +100M -print -delete            find . -size +100M -delete                   find . -size +100M -exec rm {} +
compress all jpg files in current directory                 gzip -k *.jpg                                find ... -exec sips -s formatOptions ...     zip images.zip *.jpg                         find ... -exec sips --setProperty ...
show me the last 5 git commits with stats                   git log --stat -5                            git log -5 --stat                            git log -n 5 --stat                          git log --stat -n 5
what time is it in tokyo                                    TZ="Asia/Tokyo" date "+%H:%M:%S %Z"          TZ="Asia/Tokyo" date "+%H:%M:%S %Z"          TZ="Asia/Tokyo" date "+%H:%M:%S %Z"          TZ="Asia/Tokyo" date "+%H:%M:%S %Z"
recursively find and replace foo with bar in all .txt files find ... -exec sed -i '' 's/foo/bar/g' {} +  find ... -exec perl -pi -e 's/foo/bar/g' {}  find ... -exec sed -i '' 's/foo/bar/g' {} +  find ... -exec sed -i '' 's/foo/bar/g' {} +
list running docker containers sorted by memory usage       docker stats --no-stream --sort mem          docker stats --format ... | sort -hr         docker stats --format ... | sort -k 3 -hr    docker ps --format ... | sort -k 3 -h
show modification time of README.md                         stat -f "%Sm" README.md                      stat -f "%Sm" -t "%Y-%m-%d" README.md        stat -f "%Sm" README.md                      stat -f "%Sm %N" README.md
show the date 3 days ago                                    date -u -v-3d +"%Y-%m-%d"                    date -v-3d "+%Y-%m-%d"                       date -v-3d                                   date -v-3d
replace localhost with 127.0.0.1 in config.ini              sed -i '' 's/localhost/127.0.0.1/g' ...      perl -pi -e 's/localhost/127.0.0.1/g' ...    sed -i '' 's/localhost/127.0.0.1/g' ...      sed -i '' 's/localhost/127.0.0.1/g' ...
find empty directories                                      find . -type d -empty                        find . -type d -empty 2>/dev/null            find . -type d -empty                        find . -type d -empty
create a tar.gz of the src directory                        tar -czf src.tar.gz src                      tar -czf src.tar.gz src                      tar -czf src.tar.gz src                      tar czf src.tar.gz src
convert video.mp4 to animated gif                           ffmpeg ... | convert -delay 10 -loop 0 ...   ffmpeg -vf lanczos -loop 0 video.gif         ffmpeg -i video.mp4 video.gif                ffmpeg -i video.mp4 output.gif
extract audio from movie.mkv as mp3                         ffmpeg -q:a 0 -map a audio.mp3               ffmpeg -vn -c:a libmp3lame movie.mp3         ffmpeg -vn movie.mp3                         ffmpeg -q:a 0 -map a output.mp3
```

</details>
