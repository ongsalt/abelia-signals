import { signal, computed, effect, effectScope, startBatch, endBatch } from "alien-signals"
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

  // MARK: SwiftUI / AttributeGraph-style

  benchmark("shape/fan-out 1→1000 via root (one read)", () => {
    const s = signal(0)
    const subs = Array.from({ length: 1000 }, (_, i) => computed(() => s() + i))
    const root = computed(() => { let acc = 0; for (const c of subs) acc += c(); return acc })
    blackHole(root())
    return () => {
      s(s() + 1)
      blackHole(root())
    }
  })

  benchmark("shape/batched writes ×10, one read", () => {
    const sources = Array.from({ length: 10 }, (_, i) => signal(i))
    const mids = sources.map((s) => computed(() => s() * 2))
    const root = computed(() => { let acc = 0; for (const m of mids) acc += m(); return acc })
    blackHole(root())
    return () => {
      startBatch()
      for (const s of sources) s(s() + 1)
      endBatch()
      blackHole(root())
    }
  })

  benchmark("shape/subgraph churn (build 10, read, drop)", () => {
    const input = signal(0)
    return () => {
      let node = computed(() => input() + 1)
      for (let i = 1; i < 10; i++) {
        const p = node
        node = computed(() => p() + 1)
      }
      blackHole(node())
    }
  })

  // MARK: Solid-style: a rendered list, one effect per row

  benchmark("solid/create + dispose 1000 rows", () => {
    return () => {
      const dispose = effectScope(() => {
        for (let i = 0; i < 1000; i++) {
          const label = signal(i)
          effect(() => { blackHole(label()) })
        }
      })
      dispose()
    }
  })

  benchmark("solid/update every 10th row (1000 rows, batched)", () => {
    const labels = Array.from({ length: 1000 }, (_, i) => signal(i))
    let sink = 0
    const dispose = effectScope(() => {
      for (const label of labels) effect(() => { sink += label() })
    })
    return () => {
      startBatch()
      for (let i = 0; i < 1000; i += 10) labels[i](labels[i]() + 1)
      endBatch()
      blackHole(sink)
      blackHole(dispose)
    }
  })

  benchmark("solid/select row (1000 rows)", () => {
    const selected = signal(-1)
    let sink = 0
    const dispose = effectScope(() => {
      for (let i = 0; i < 1000; i++) {
        const isSelected = computed(() => selected() === i)
        effect(() => { if (isSelected()) sink += 1 })
      }
    })
    let next = 0
    return () => {
      selected(next)
      next = (next + 1) % 1000
      blackHole(sink)
      blackHole(dispose)
    }
  })
}
