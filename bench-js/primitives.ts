import { signal, computed, effect, setActiveSub } from "alien-signals"
import { benchmark, blackHole } from "./harness.ts"

// MARK: 1. Primitives — mirror of Sources/Benchmark/Primitives.swift

export function registerPrimitives(): void {
  benchmark("prim/signal read (untracked)", () => {
    const s = signal(0)
    return () => blackHole(s())
  })

  benchmark("prim/signal peek", () => {
    const s = signal(0)
    return () => {
      const prev = setActiveSub(undefined)
      blackHole(s())
      setActiveSub(prev)
    }
  })

  benchmark("prim/signal read (tracked, 1×)", () => {
    const s = signal(0)
    const c = computed(() => s())
    return () => {
      s(s() + 1)
      blackHole(c())
    }
  })

  benchmark("prim/signal read (tracked, same ×100)", () => {
    const s = signal(0)
    const c = computed(() => {
      let acc = 0
      for (let i = 0; i < 100; i++) acc += s()
      return acc
    })
    return () => {
      s(s() + 1)
      blackHole(c())
    }
  })

  benchmark("prim/signal write (same value, equals cutoff)", () => {
    const s = signal(0)
    const c = computed(() => s())
    blackHole(c())
    return () => s(0)
  })

  for (const n of [0, 1, 10, 100]) {
    benchmark(`prim/signal write (${n} subscribers)`, () => {
      const s = signal(0)
      const subs = Array.from({ length: n }, () => computed(() => s()))
      for (const c of subs) blackHole(c())
      return () => {
        s(s() + 1)
        blackHole(subs)
      }
    })
  }

  benchmark("prim/create Signal", () => {
    return () => blackHole(signal(0))
  })

  benchmark("prim/create Computed + first read", () => {
    const s = signal(0)
    return () => {
      const c = computed(() => s() + 1)
      blackHole(c())
    }
  })

  // Swift drops the Effect at end of scope; alien-signals needs an explicit dispose
  benchmark("prim/create Effect.immediate", () => {
    const s = signal(0)
    return () => {
      const dispose = effect(() => blackHole(s()))
      dispose()
    }
  })
}
