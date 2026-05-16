# benchmark

Regression suite for zsh-ai-cmd prompt and provider changes. 100 natural-language
prompts (31 simple, 51 flag-heavy, 18 composed). Each scored against an accepted
answer set with multiple acceptable variants per prompt.

## Workflow

```sh
# 1. Capture a baseline before changing anything
python3 benchmark/run.py --name baseline

# 2. Make a prompt or provider change

# 3. Run the candidate
python3 benchmark/run.py --name candidate

# 4. Compare
python3 benchmark/score.py candidate --baseline baseline
```

The compare view shows per-tier deltas and per-prompt moves so a regression
isn't masked by an offsetting gain elsewhere.

## Run options

```sh
python3 benchmark/run.py                    # provider=anthropic, full 100
python3 benchmark/run.py --provider openai
python3 benchmark/run.py --limit 5          # smoke test
python3 benchmark/run.py --ids 1,2,3
python3 benchmark/run.py --name custom
```

## Score options

```sh
python3 benchmark/score.py anthropic
python3 benchmark/score.py anthropic --failures
python3 benchmark/score.py anthropic --category flags
python3 benchmark/score.py candidate --baseline baseline
```

## Scoring tiers

| Tier   | Meaning                                              |
|--------|------------------------------------------------------|
| exact  | matches an accepted answer after normalization       |
| review | right base command, different flags/args             |
| wrong  | different base command                               |
| error  | empty output, timeout, or non-zero exit              |

The plugin's `command ` alias-bypass prefix is stripped before comparison so it
never penalizes an otherwise-correct answer.

## Files

| File                | Purpose                                          |
|---------------------|--------------------------------------------------|
| `call.zsh`          | Headless single-shot invoker for the plugin      |
| `run.py`            | Loops `call.zsh` over all prompts, writes JSONL  |
| `score.py`          | Scores a results file; optional baseline diff    |
| `prompts.jsonl`     | 100 input prompts with expected answers          |
| `alternates.json`   | Accepted-answer variants keyed by prompt id      |
| `results/*.jsonl`   | Saved runs (named by `--name`, default provider) |

## Caveats

- Latency includes API round-trip; meaningful only as a relative number between runs.
- The accepted-answer set is finite. A novel-but-correct answer can score as
  `review` or `wrong`. Inspect `--failures` after large prompt changes.
- macOS-flavored prompts (`pbcopy`, `caffeinate`, `sips`). Numbers don't transfer
  to a Linux baseline without curating the accepted set.
