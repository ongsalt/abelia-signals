// Mirror of Sources/Benchmark/Harness.swift — same calibration and sampling, so the numbers line up.

let sink: unknown
export function blackHole(x: unknown): void {
  sink = x
}

type Case = { name: string; setup: () => () => void }
const registry: Case[] = []

export function benchmark(name: string, setup: () => () => void): void {
  registry.push({ name, setup })
}

const g = globalThis as { gc?: () => void; Bun?: { gc(force: boolean): void } }
function collectGarbage(): void {
  if (g.gc) g.gc()
  else g.Bun?.gc(true)
}

function measure(n: number, op: () => void): number {
  const t0 = performance.now()
  for (let i = 0; i < n; i++) op()
  return performance.now() - t0 // ms
}

export function runBenchmarks(filter: string | undefined): void {
  const samples = 15
  const targetSampleMs = 50

  console.log(pad("benchmark", 44), pad("median", 12), pad("min", 12), "iters/sample")
  for (const bench of registry) {
    if (filter && !bench.name.includes(filter)) continue
    collectGarbage()
    const op = bench.setup()

    let iters = 1
    while (true) {
      const t = measure(iters, op)
      if (t >= targetSampleMs / 4 || iters >= 1 << 26) break
      iters *= 2
    }
    const perSample = Math.max(1, Math.floor(iters * (targetSampleMs / measure(iters, op))))

    const results: number[] = []
    for (let i = 0; i < samples; i++) {
      results.push((measure(perSample, op) * 1e6) / perSample) // ns/op
    }
    results.sort((a, b) => a - b)
    console.log(pad(bench.name, 44), pad(format(results[samples >> 1]), 12), pad(format(results[0]), 12), perSample)
  }
}

function format(ns: number): string {
  if (ns < 1_000) return `${Math.round(ns * 10) / 10} ns`
  if (ns < 1_000_000) return `${Math.round(ns / 100) / 10} µs`
  return `${Math.round(ns / 100_000) / 10} ms`
}

function pad(s: string, n: number): string {
  return s.length >= n ? s : s + " ".repeat(n - s.length)
}
