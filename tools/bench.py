#!/usr/bin/env python3
"""Run the headless profiler and compare it against a committed baseline.

The point is a number you can trust between two runs on the same machine, not
an absolute figure: the seed, tick count and entity count are fixed here, and
the best of several repeats is taken rather than the mean of them. A benchmark
that reports the average of its own noise reports the noise.

  make bench          run and compare
  make bench-accept   run and write the result as the new baseline
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "bench" / "baseline.json"

# Fixed so that two runs measure the same work. Changing any of these
# invalidates the baseline - re-accept it in the same commit.
SEED = "0x05a1"
TICKS = 600
ENTITIES = 1000

# What counts as a regression, as a fraction of the baseline. Wide enough that
# a busy laptop does not trip it, narrow enough that a real one does not hide.
FAIL_OVER = 0.25
WARN_OVER = 0.10

TICK_RE = re.compile(r"^tick\s+([\d.]+) us mean")
ROW_RE = re.compile(r"^(\S+)\s+([\d.]+)\s+([\d.]+)%\s+([\d.]+)\s*$")


def run_once(binary: Path) -> dict[str, float]:
    out = subprocess.run(
        [
            str(binary),
            "--headless",
            "--profile",
            f"--seed={SEED}",
            f"--ticks={TICKS}",
            f"--entities={ENTITIES}",
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    result: dict[str, float] = {}
    for line in out.splitlines():
        if m := TICK_RE.match(line):
            result["tick"] = float(m.group(1))
        elif m := ROW_RE.match(line):
            result[m.group(1)] = float(m.group(2))
    if "tick" not in result:
        sys.exit(f"bench: could not parse profiler output:\n{out}")
    return result


def best_of(binary: Path, repeats: int) -> dict[str, float]:
    runs = [run_once(binary) for _ in range(repeats)]
    keys = {k for run in runs for k in run}
    # Per key, not per run: the fastest run is the one least disturbed by the
    # rest of the machine, and that is true system by system.
    return {k: min(run[k] for run in runs if k in run) for k in keys}


def report(current: dict[str, float], baseline: dict[str, float] | None) -> int:
    order = sorted(
        (k for k in current if k != "tick"), key=lambda k: -current[k]
    )
    print(f"\n{'system':<22}{'us/tick':>10}{'baseline':>10}{'delta':>10}")

    worst = 0.0
    for name in ["tick"] + order:
        now = current[name]
        was = (baseline or {}).get(name)
        if was is None or was == 0:
            print(f"{name:<22}{now:>10.3f}{'-':>10}{'new':>10}")
            continue
        delta = (now - was) / was
        if name == "tick":
            worst = delta
        mark = "  <-- regression" if delta > FAIL_OVER else ""
        print(f"{name:<22}{now:>10.3f}{was:>10.3f}{delta:>+9.1%}{mark}")

    if baseline is None:
        print("\nno baseline yet - run `make bench-accept` to record this one")
        return 0
    if worst > FAIL_OVER:
        print(f"\nFAIL: tick cost is {worst:+.1%} against the baseline")
        print("if the change is intended, re-record with `make bench-accept`")
        return 1
    if worst > WARN_OVER:
        print(f"\nwarning: tick cost is {worst:+.1%} against the baseline")
    else:
        print(f"\nok: tick cost {worst:+.1%} against the baseline")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default="bin/osai-bench")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--accept", action="store_true", help="record as baseline")
    args = ap.parse_args()

    binary = ROOT / args.binary
    if not binary.exists():
        sys.exit(f"bench: {binary} not built")

    current = best_of(binary, args.repeats)
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else None

    status = report(current, baseline)

    if args.accept:
        BASELINE.parent.mkdir(exist_ok=True)
        # Ordered by cost, not by name: the file is read by people, and what
        # you want from it is what the step spends its time on. `tick` is the
        # total, so it sorts to the top on its own.
        ordered = dict(sorted(current.items(), key=lambda kv: -kv[1]))
        BASELINE.write_text(json.dumps(ordered, indent=2) + "\n")
        print(f"baseline written to {BASELINE.relative_to(ROOT)}")
        return 0
    return status


if __name__ == "__main__":
    sys.exit(main())
