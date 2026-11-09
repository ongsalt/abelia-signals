import { signal, computed, effect, startBatch, endBatch } from "alien-signals"
import { blackHole } from "./harness.ts"

// MARK: 3. Correctness counters — mirror of Sources/Benchmark/Correctness.swift

const checks: { name: string; expected: number; actual: number }[] = []

function check(name: string, expected: number, body: () => number): void {
  checks.push({ name, expected, actual: body() })
}

export function runChecks(): void {
  check("diamond: D recomputes once per write", 1, () => {
    const a = signal(0)
    const b = computed(() => a() + 1)
    const c = computed(() => a() * 2)
    let runs = 0
    const d = computed(() => { runs++; return b() + c() })
    blackHole(d())
    runs = 0
    a(a() + 1)
    blackHole(d())
    return runs
  })

  check("diamond: immediate effect reruns once per write", 1, () => {
    const a = signal(0)
    const b = computed(() => a() + 1)
    const c = computed(() => a() * 2)
    const d = computed(() => b() + c())
    let runs = 0
    const dispose = effect(() => { runs++; blackHole(d()) })
    runs = 0
    a(a() + 1)
    dispose()
    return runs
  })

  check("diamond: effect never sees glitch (count of inconsistent observations)", 0, () => {
    const a = signal(0)
    const b = computed(() => a())
    const c = computed(() => a())
    let glitches = 0
    const dispose = effect(() => { if (b() !== c()) glitches++ })
    for (let i = 0; i < 10; i++) a(a() + 1)
    dispose()
    return glitches
  })

  check("equality cutoff: unchanged B does not recompute D", 0, () => {
    const a = signal(0)
    const b = computed(() => Math.floor(a() / 1000))
    let runs = 0
    const d = computed(() => { runs++; return b() + 1 })
    blackHole(d())
    runs = 0
    a(a() + 1)
    blackHole(d())
    return runs
  })

  check("equality cutoff: deep chain below unchanged node (runs of 10 nodes)", 0, () => {
    const a = signal(0)
    const gate = computed(() => a() * 0)
    let runs = 0
    let prev = gate
    for (let i = 0; i < 10; i++) {
      const p = prev
      prev = computed(() => { runs++; return p() + 1 })
    }
    const tail = prev
    blackHole(tail())
    runs = 0
    a(a() + 1)
    blackHole(tail())
    return runs
  })

  check("equality cutoff: effect behind unchanged computed does not rerun", 0, () => {
    const a = signal(0)
    const b = computed(() => Math.floor(a() / 1000))
    let runs = 0
    const dispose = effect(() => { runs++; blackHole(b()) })
    runs = 0
    a(a() + 1)
    dispose()
    return runs
  })

  check("lazy: never-read computed does not run", 0, () => {
    const a = signal(0)
    let runs = 0
    const c = computed(() => { runs++; return a() })
    for (let i = 0; i < 10; i++) a(a() + 1)
    blackHole(c)
    return runs
  })

  check("lazy: computed recomputes once for 10 writes then 1 read", 1, () => {
    const a = signal(0)
    let runs = 0
    const c = computed(() => { runs++; return a() })
    blackHole(c())
    runs = 0
    for (let i = 0; i < 10; i++) a(a() + 1)
    blackHole(c())
    return runs
  })

  check("dynamic deps: stale branch no longer triggers recompute", 0, () => {
    const flag = signal(true)
    const x = signal(0)
    const y = signal(0)
    let runs = 0
    const c = computed(() => { runs++; return flag() ? x() : y() })
    blackHole(c())
    flag(false)
    blackHole(c())
    runs = 0
    x(x() + 1)
    blackHole(c())
    return runs
  })

  check("repeated reads: effect reading a signal 3× reruns once", 1, () => {
    const a = signal(0)
    let runs = 0
    const dispose = effect(() => { runs++; blackHole(a() + a() + a()) })
    runs = 0
    a(a() + 1)
    dispose()
    return runs
  })

  // alien-signals has no scheduler; batching is the equivalent
  check("scheduler: 100 writes then flush reruns effect once", 1, () => {
    const a = signal(0)
    let runs = 0
    const dispose = effect(() => { runs++; blackHole(a()) })
    runs = 0
    startBatch()
    for (let i = 0; i < 100; i++) a(a() + 1)
    endBatch()
    dispose()
    return runs
  })

  console.log("check                                                                    expected  actual")
  let failed = 0
  for (const c of checks) {
    const ok = c.expected === c.actual
    if (!ok) failed++
    console.log(`${ok ? "✓" : "✗"} ${c.name.padEnd(72)} ${c.expected}         ${c.actual}`)
  }
  console.log(`${checks.length - failed}/${checks.length} passed\n`)
}
