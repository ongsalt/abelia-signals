#!/bin/bash
# Runs the Swift benchmarks and the same cases on alien-signals in bun and node
# (whichever are installed), then prints ns/op side by side. Each case is the
# median of 5 samples of ~100ms. Laptop power and thermal state move the numbers
# a lot: compare runs from the same session.
set -e
cd "$(dirname "$0")"
out=.results
mkdir -p "$out"

swift build -c release --product Benchmarks 2>&1 | grep -E "error|warning: " || true
.build/release/Benchmarks > "$out/swift.tsv"

if command -v bun >/dev/null || command -v node >/dev/null; then
    [ -d js/node_modules ] || (cd js && npm install --ignore-scripts --silent)
fi
runtimes=(swift)
for js in bun node; do
    if command -v $js >/dev/null; then
        $js js/bench.mjs > "$out/$js.tsv"
        runtimes+=($js)
    fi
done

python3 - "$out" "${runtimes[@]}" <<'PY'
import sys
out, runtimes = sys.argv[1], sys.argv[2:]
def load(name):
    rows = (l.rstrip("\n").split("\t") for l in open(f"{out}/{name}.tsv"))
    return {k: float(v) for k, v in rows if k != "sink"}
results = {r: load(r) for r in runtimes}
js = [r for r in runtimes if r != "swift"]
header = f"{'case':38}" + "".join(f"{r:>11}" for r in runtimes)
if js: header += f"  {'vs best JS':>10}"
print(header)
for case, ns in results["swift"].items():
    line = f"{case:38}" + "".join(f"{results[r][case]:11.1f}" for r in runtimes)
    if js: line += f"  {min(results[r][case] for r in js) / ns:9.2f}x"
    print(line)
PY
