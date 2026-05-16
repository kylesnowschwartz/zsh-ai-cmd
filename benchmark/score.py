#!/usr/bin/env python3
"""Score a zsh-ai-cmd benchmark run, optionally compared against a baseline.

Tiers:
  exact   match one of the accepted answers exactly (after normalization)
  review  right base command, different flags/args
  wrong   different base command
  error   empty / timeout / non-zero exit

The plugin's `command ` alias-bypass prefix is post-stripped before comparison
so it doesn't penalize otherwise-correct answers.

Usage:
  python3 benchmark/score.py anthropic
  python3 benchmark/score.py anthropic --failures
  python3 benchmark/score.py anthropic --category flags
  python3 benchmark/score.py candidate --baseline baseline
"""
from __future__ import annotations
import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
PROMPTS_FILE = HERE / "prompts.jsonl"
ALTERNATES_FILE = HERE / "alternates.json"
RESULTS_DIR = HERE / "results"

TIERS = ("exact", "review", "wrong", "error")


def load_prompts() -> dict[int, dict]:
    out = {}
    with open(PROMPTS_FILE) as f:
        for line in f:
            p = json.loads(line)
            out[p["id"]] = p
    return out


def load_alternates() -> dict[int, list[str]]:
    with open(ALTERNATES_FILE) as f:
        return {int(k): v for k, v in json.load(f).items()}


def strip_command_prefix(cmd: str) -> str:
    return re.sub(r"\bcommand\s+", "", cmd).strip()


def normalize(cmd: str) -> str:
    cmd = strip_command_prefix(cmd)
    cmd = cmd.replace('"', "'")
    cmd = re.sub(r"\s+", " ", cmd)
    return cmd.strip()


def extract_base(cmd: str) -> str:
    for p in strip_command_prefix(cmd).split():
        if p in ("sudo", "env"):
            continue
        if "=" in p:
            continue
        return p
    return ""


def commands_match(got: str, accepted: list[str]) -> bool:
    g = normalize(got)
    for a in accepted:
        if normalize(a) == g:
            return True
    placeholder = re.compile(r"\b(file\S*|dir\S*|path\S*|host\S*|user\S*)\b")
    g_gen = placeholder.sub("X", g)
    for a in accepted:
        if placeholder.sub("X", normalize(a)) == g_gen:
            return True
    return False


def score_one(result: dict, info: dict, alternates: dict) -> str:
    got = (result.get("result") or "").strip()
    accepted = alternates.get(info["id"], [info["expected"]])
    if not got or got.startswith("[") or got == "ERROR":
        return "error"
    if commands_match(got, accepted):
        return "exact"
    exp_bases = {extract_base(a) for a in accepted} - {""}
    got_base = extract_base(got)
    if got_base and got_base in exp_bases:
        return "review"
    return "wrong"


def score_run(name: str, category: str | None = None):
    prompts = load_prompts()
    alternates = load_alternates()
    path = RESULTS_DIR / f"{name}.jsonl"
    if not path.exists():
        print(f"No results at {path}", file=sys.stderr)
        sys.exit(1)
    results = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]

    stats = {t: 0 for t in TIERS} | {"total": 0}
    by_cat: dict[str, dict[str, int]] = defaultdict(
        lambda: {t: 0 for t in TIERS} | {"total": 0}
    )
    by_id: dict[int, str] = {}
    times: list[float] = []
    failures = []

    for r in results:
        info = prompts.get(r["id"])
        if not info:
            continue
        if category and info["category"] != category:
            continue
        tier = score_one(r, info, alternates)
        by_id[r["id"]] = tier
        stats["total"] += 1
        stats[tier] += 1
        c = info["category"]
        by_cat[c]["total"] += 1
        by_cat[c][tier] += 1
        if r.get("total_time"):
            times.append(r["total_time"])
        if tier != "exact":
            failures.append((info, r, tier))

    return {
        "name": name,
        "stats": stats,
        "by_cat": dict(by_cat),
        "by_id": by_id,
        "times": times,
        "failures": failures,
    }


def print_summary(s: dict) -> None:
    name = s["name"]
    stats = s["stats"]
    total = stats["total"]
    print(f"\n{'=' * 70}\n  {name.upper()}\n{'=' * 70}")
    print(f"  Total prompts: {total}")
    for tier in TIERS:
        pct = (stats[tier] / total * 100) if total else 0
        print(f"  {tier:8s}: {stats[tier]:3d} ({pct:5.1f}%)")
    if s["times"]:
        print(f"  Avg time:  {sum(s['times']) / len(s['times']):.2f}s")
    usable = stats["exact"] + stats["review"]
    usable_pct = (usable / total * 100) if total else 0
    print(f"  Usable (exact+review): {usable} ({usable_pct:.1f}%)")
    print()
    print(f"  {'category':10s} {'exact':>5} {'revw':>5} {'wrong':>5} {'err':>5} {'tot':>5}")
    for c in sorted(s["by_cat"]):
        v = s["by_cat"][c]
        print(f"  {c:10s} {v['exact']:5d} {v['review']:5d} {v['wrong']:5d} {v['error']:5d} {v['total']:5d}")


def print_failures(failures) -> None:
    print(f"\n--- FAILURES ({len(failures)}) ---")
    for info, r, tier in failures:
        print(f"[{tier:5s}] #{info['id']:3d} ({info['category']})")
        print(f"  prompt:   {info['prompt']}")
        print(f"  expected: {info['expected']}")
        print(f"  got:      {(r.get('result') or '').strip()}")
        print()


def print_baseline_diff(candidate: dict, baseline: dict) -> None:
    cs, bs = candidate["stats"], baseline["stats"]
    print(f"\n{'=' * 70}\n  {candidate['name']}  vs  {baseline['name']}\n{'=' * 70}")
    print(f"  {'tier':10s} {'baseline':>10} {'candidate':>10} {'delta':>10}")
    for tier in TIERS:
        d = cs[tier] - bs[tier]
        sign = "+" if d > 0 else ""
        print(f"  {tier:10s} {bs[tier]:10d} {cs[tier]:10d} {sign + str(d):>10}")
    bu = bs["exact"] + bs["review"]
    cu = cs["exact"] + cs["review"]
    du = cu - bu
    sign = "+" if du > 0 else ""
    print(f"  {'usable':10s} {bu:10d} {cu:10d} {sign + str(du):>10}")

    if baseline["times"] and candidate["times"]:
        bt = sum(baseline["times"]) / len(baseline["times"])
        ct = sum(candidate["times"]) / len(candidate["times"])
        print(f"  {'avg time':10s} {bt:10.2f} {ct:10.2f} {ct - bt:+10.2f}")

    moves = []
    rank = {"exact": 0, "review": 1, "wrong": 2, "error": 3}
    for pid, c_tier in candidate["by_id"].items():
        b_tier = baseline["by_id"].get(pid)
        if b_tier is None or b_tier == c_tier:
            continue
        direction = "↑" if rank[c_tier] < rank[b_tier] else "↓"
        moves.append((direction, pid, b_tier, c_tier))
    if moves:
        moves.sort(key=lambda m: (m[0] == "↓", m[1]))
        prompts = load_prompts()
        print(f"\n  Per-prompt changes ({len(moves)}):")
        for direction, pid, b_t, c_t in moves:
            p = prompts.get(pid, {})
            print(f"    {direction} #{pid:3d} {b_t:6s} -> {c_t:6s}  {p.get('prompt', '')[:50]}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("name", help="Results basename (without .jsonl)")
    ap.add_argument("--baseline", help="Baseline basename to diff against")
    ap.add_argument("--category", help="Filter by category")
    ap.add_argument("--failures", action="store_true")
    args = ap.parse_args()

    candidate = score_run(args.name, args.category)
    print_summary(candidate)
    if args.failures:
        print_failures(candidate["failures"])

    if args.baseline:
        baseline = score_run(args.baseline, args.category)
        print_summary(baseline)
        print_baseline_diff(candidate, baseline)


if __name__ == "__main__":
    main()
