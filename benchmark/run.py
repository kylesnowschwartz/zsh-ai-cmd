#!/usr/bin/env python3
"""Run zsh-ai-cmd against the 100-prompt benchmark and write a results JSONL.

Usage:
  python3 benchmark/run.py                          # 100 prompts, anthropic
  python3 benchmark/run.py --provider openai
  python3 benchmark/run.py --limit 5                # smoke test
  python3 benchmark/run.py --ids 1,2,3
  python3 benchmark/run.py --name baseline          # custom output name
"""
from __future__ import annotations
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).parent
PROMPTS_FILE = HERE / "prompts.jsonl"
WRAPPER = HERE / "call.zsh"
RESULTS_DIR = HERE / "results"
RESULTS_DIR.mkdir(exist_ok=True)
TIMEOUT = 30


def call(prompt: str, provider: str) -> tuple[str, float]:
    t0 = time.time()
    try:
        out = subprocess.run(
            ["zsh", str(WRAPPER), prompt],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            env={**os.environ, "ZSH_AI_CMD_PROVIDER": provider},
        )
    except subprocess.TimeoutExpired:
        return "[TIMEOUT]", TIMEOUT
    elapsed = round(time.time() - t0, 2)
    if out.returncode != 0:
        last_err = (out.stderr or "").strip().splitlines()[-1:] or [""]
        return f"[ERROR rc={out.returncode}: {last_err[0][:120]}]", elapsed
    return out.stdout.strip(), elapsed


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default=None,
                    help="Output basename (default: <provider>)")
    ap.add_argument("--provider", default="anthropic")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--ids", help="Comma-separated prompt IDs")
    args = ap.parse_args()

    name = args.name or args.provider
    out_path = RESULTS_DIR / f"{name}.jsonl"

    ids: set[int] | None = None
    if args.ids:
        ids = {int(x) for x in args.ids.split(",")}

    prompts = []
    with open(PROMPTS_FILE) as f:
        for line in f:
            p = json.loads(line)
            if ids is not None and p["id"] not in ids:
                continue
            prompts.append(p)
    if args.limit:
        prompts = prompts[: args.limit]

    print(
        f"Running {len(prompts)} prompts | provider={args.provider} | -> {out_path}",
        file=sys.stderr,
    )
    with open(out_path, "w") as f:
        for i, p in enumerate(prompts):
            result, elapsed = call(p["prompt"], args.provider)
            rec = {
                "id": p["id"],
                "prompt": p["prompt"],
                "result": result,
                "total_time": elapsed,
            }
            f.write(json.dumps(rec) + "\n")
            f.flush()
            status = "OK " if result and not result.startswith("[") else "ERR"
            print(
                f"[{i+1:3d}/{len(prompts)}] #{p['id']:3d} {status} {elapsed:5.1f}s | "
                f"{p['prompt'][:48]:<48} | {result[:70]}",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
