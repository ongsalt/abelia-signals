#!/usr/bin/env python3
"""Interleaved A/B(/C...) comparison of benchmark binaries, so drift (battery, thermals,
background load) hits every binary the same way.

    compare.py [--rounds N] [--cpu K] [--filter SUBSTR] name=path/to/binary ...

Every round runs each case on each binary back to back, rotating the binary order between
rounds. A case's result is the median of its per-round medians. Ratios are against the first
binary (> 1 means slower than it). Cases a binary doesn't have show as "—".

The binaries must use the shared harness: `--list` prints case names, `=<name>` runs exactly
one case.
"""

import argparse
import re
import statistics
import subprocess
import sys

ROW = re.compile(r"^((?:prim|shape)/.+?)\s+([\d.]+) ?([nµm]?s)\s+([\d.]+) ?([nµm]?s)\s+\d+\s*$")
UNIT = {"ns": 1.0, "µs": 1e3, "ms": 1e6, "s": 1e9}


def fmt(ns):
    if ns < 1e3:
        return f"{ns:.1f} ns"
    if ns < 1e6:
        return f"{ns / 1e3:.2f} µs"
    return f"{ns / 1e6:.2f} ms"


def run(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--cpu", type=int, help="pin every run to this CPU (taskset)")
    ap.add_argument("--filter", help="only cases whose name contains this")
    ap.add_argument("binaries", nargs="+", help="name=path")
    args = ap.parse_args()

    bins = [tuple(b.split("=", 1)) for b in args.binaries]
    prefix = ["taskset", "-c", str(args.cpu)] if args.cpu is not None else []

    cases_of = {name: run([path, "--list"]).split("\n") for name, path in bins}
    cases = []
    for name, _ in bins:
        for c in cases_of[name]:
            if c and c not in cases and (args.filter is None or args.filter in c):
                cases.append(c)

    results = {(c, name): [] for c in cases for name, _ in bins}
    for r in range(args.rounds):
        order = bins[r % len(bins):] + bins[: r % len(bins)]
        for i, case in enumerate(cases):
            print(f"\rround {r + 1}/{args.rounds}  {i + 1}/{len(cases)}  {case[:50]:<50}", end="", file=sys.stderr)
            for name, path in order:
                if case not in cases_of[name]:
                    continue
                for line in run(prefix + [path, "=" + case]).splitlines():
                    m = ROW.match(line)
                    if m and m.group(1).strip() == case:
                        results[(case, name)].append(float(m.group(2)) * UNIT[m.group(3)])
    print(file=sys.stderr)

    names = [n for n, _ in bins]
    head = ["case"] + names + [f"{n} / {names[0]}" for n in names[1:]]
    print("| " + " | ".join(head) + " |")
    print("|---" * len(head) + "|")
    for case in cases:
        med = {n: statistics.median(results[(case, n)]) if results[(case, n)] else None for n in names}
        cells = [fmt(med[n]) if med[n] is not None else "—" for n in names]
        base = med[names[0]]
        for n in names[1:]:
            cells.append(f"{med[n] / base:.2f}" if base and med[n] else "—")
        print(f"| {case.split('/', 1)[1]} | " + " | ".join(cells) + " |")
    print(f"\n{args.rounds} rounds, interleaved" + (f", pinned to CPU {args.cpu}" if args.cpu is not None else ""))


if __name__ == "__main__":
    main()
