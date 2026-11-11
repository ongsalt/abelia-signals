#!/usr/bin/env python3
"""Merge benchmark outputs into one markdown table (medians).

    table.py "v2=out/v2.txt" "AG=out/ag.txt" "alien (node)=out/node.txt" ...

Each file is the raw output of a suite (Swift harness or bench-js); lines that aren't
benchmark rows (checks, headers, logs) are ignored. A missing or empty file becomes a
column of "—", so a failed optional run doesn't break the table.
"""

import re
import sys

ROW = re.compile(r"^((?:prim|shape)/.+?)\s+([\d.]+ ?[nµm]?s)\s+([\d.]+ ?[nµm]?s)\s+\d+\s*$")


def parse(path):
    medians = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = ROW.match(line.rstrip("\n"))
                if m:
                    medians[m.group(1).strip()] = m.group(2)
    except OSError:
        pass
    return medians


def main(args):
    columns = []
    for arg in args:
        name, _, path = arg.partition("=")
        columns.append((name, parse(path)))

    # row order: first appearance across the columns, in argument order
    order = []
    for _, medians in columns:
        for case in medians:
            if case not in order:
                order.append(case)

    print("| case | " + " | ".join(name for name, _ in columns) + " |")
    print("|---|" + "---|" * len(columns))
    for case in order:
        cells = [medians.get(case, "—") for _, medians in columns]
        print(f"| {case.split('/', 1)[1]} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main(sys.argv[1:])
