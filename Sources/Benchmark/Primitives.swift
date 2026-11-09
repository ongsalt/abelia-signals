import AbeliaSignals

// MARK: 1. Primitives — raw per-operation overhead

func registerPrimitives() {
    benchmark("prim/signal read (untracked)") {
        let s = Signal(0)
        return { blackHole(s.value) }
    }

    benchmark("prim/signal peek") {
        let s = Signal(0)
        return { blackHole(s.peek) }
    }

    // a dirty computed reading one signal: cost of track + recompute
    benchmark("prim/signal read (tracked, 1×)") {
        let s = Signal(0)
        let c = Computed { s.value }
        return {
            s.value &+= 1
            blackHole(c.value)
        }
    }

    // same signal read 100× in one computation: exposes duplicate dependency tracking
    benchmark("prim/signal read (tracked, same ×100)") {
        let s = Signal(0)
        let c = Computed {
            var acc = 0
            for _ in 0..<100 { acc &+= s.value }
            return acc
        }
        return {
            s.value &+= 1
            blackHole(c.value)
        }
    }

    benchmark("prim/signal write (same value, equals cutoff)") {
        let s = Signal(0)
        let c = Computed { s.value }
        blackHole(c.value)
        return { s.value = 0 }
    }

    // subscribers are computeds that are never read: measures notify fan-out only
    for n in [0, 1, 10, 100] {
        benchmark("prim/signal write (\(n) subscribers)") {
            let s = Signal(0)
            let subs = (0..<n).map { _ in Computed { s.value } }
            for c in subs { blackHole(c.value) }
            return {
                s.value &+= 1
                blackHole(subs)
            }
        }
    }

    benchmark("prim/create Signal") {
        return { blackHole(Signal(0)) }
    }

    benchmark("prim/create Computed + first read") {
        let s = Signal(0)
        return {
            let c = Computed { s.value &+ 1 }
            blackHole(c.value)
        }
    }

    benchmark("prim/create Effect.immediate") {
        let s = Signal(0)
        return {
            let e = Effect.immediate { blackHole(s.value) }
            blackHole(e)
        }
    }
}
