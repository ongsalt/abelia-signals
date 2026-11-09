import { signal, computed, effect } from "alien-signals"
import { benchmark, blackHole } from "./harness.ts"

// MARK: 2. Graph shapes — mirror of Sources/Benchmark/Shapes.swift

export function registerShapes(): void {
  for (const depth of [10, 100, 1000]) {
    benchmark(`shape/deep chain ×${depth}`, () => {
      const head = signal(0)
      const nodes = [computed(() => head() + 1)]
      for (let i = 1; i < depth; i++) {
        const prev = nodes[i - 1]
        nodes.push(computed(() => prev() + 1))
      }
      const tail = nodes[nodes.length - 1]
      blackHole(tail())
      return () => {
        head(head() + 1)
        blackHole(tail())
      }
    })
  }

  benchmark("shape/fan-out 1→1000 computeds (read all)", () => {
    const s = signal(0)
    const subs = Array.from({ length: 1000 }, (_, i) => computed(() => s() + i))
    return () => {
      s(s() + 1)
      for (const c of subs) blackHole(c())
    }
  })

  benchmark("shape/fan-out 1→1000 effects (immediate)", () => {
    const s = signal(0)
    let acc = 0
    const effects = Array.from({ length: 1000 }, () => effect(() => { acc += s() }))
    return () => {
      s(s() + 1)
      blackHole(effects)
      blackHole(acc)
    }
  })

  benchmark("shape/fan-in 1000→1 (write one)", () => {
    const sources = Array.from({ length: 1000 }, (_, i) => signal(i))
    const sum = computed(() => sources.reduce((a, s) => a + s(), 0))
    blackHole(sum())
    let i = 0
    return () => {
      sources[i](sources[i]() + 1)
      i = (i + 1) % 1000
      blackHole(sum())
    }
  })

  benchmark("shape/diamond 1→2→1", () => {
    const a = signal(0)
    const b = computed(() => a() + 1)
    const c = computed(() => a() * 2)
    const d = computed(() => b() + c())
    blackHole(d())
    return () => {
      a(a() + 1)
      blackHole(d())
    }
  })

  benchmark("shape/wide diamond 1→100→1", () => {
    const a = signal(0)
    const mids = Array.from({ length: 100 }, (_, i) => computed(() => a() + i))
    const d = computed(() => mids.reduce((acc, m) => acc + m(), 0))
    blackHole(d())
    return () => {
      a(a() + 1)
      blackHole(d())
    }
  })

  benchmark("shape/layered grid 10×100", () => {
    const width = 100
    const sources = Array.from({ length: width }, (_, i) => signal(i))
    let layer = Array.from({ length: width }, (_, i) =>
      computed(() => sources[i]() + sources[(i + 1) % width]()))
    for (let l = 1; l < 10; l++) {
      const prev = layer
      layer = Array.from({ length: width }, (_, i) => computed(() => prev[i]() + prev[(i + 1) % width]()))
    }
    const last = layer
    for (const c of last) blackHole(c())
    let i = 0
    return () => {
      sources[i](sources[i]() + 1)
      i = (i + 1) % width
      for (const c of last) blackHole(c())
    }
  })

  benchmark("shape/dynamic deps (switch 50↔50)", () => {
    const flag = signal(true)
    const xs = Array.from({ length: 100 }, (_, i) => signal(i))
    const c = computed(() => {
      const [lo, hi] = flag() ? [0, 50] : [50, 100]
      let acc = 0
      for (let i = lo; i < hi; i++) acc += xs[i]()
      return acc
    })
    blackHole(c())
    return () => {
      flag(!flag())
      blackHole(c())
    }
  })
}
