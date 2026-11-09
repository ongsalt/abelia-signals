#if ALIEN
import AlienSignals
#else
import AbeliaSignals
#endif

// MARK: 3. Correctness counters — "does it do the minimal amount of work?"

private nonisolated(unsafe) var checks: [(name: String, expected: Int, actual: Int)] = []

private func check(_ name: String, expected: Int, _ body: () -> Int) {
    checks.append((name, expected, body()))
}

func runChecks() {
    check("diamond: D recomputes once per write", expected: 1) {
        let a = Signal(0)
        let b = Computed { a.value &+ 1 }
        let c = Computed { a.value &* 2 }
        var runs = 0
        let d = Computed { runs += 1; return b.value &+ c.value }
        blackHole(d.value)
        runs = 0
        a.value += 1
        blackHole(d.value)
        return runs
    }

    check("diamond: immediate effect reruns once per write", expected: 1) {
        let a = Signal(0)
        let b = Computed { a.value &+ 1 }
        let c = Computed { a.value &* 2 }
        let d = Computed { b.value &+ c.value }
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(d.value) }
        runs = 0
        a.value += 1
        blackHole(e)
        return runs
    }

    check("diamond: effect never sees glitch (count of inconsistent observations)", expected: 0) {
        let a = Signal(0)
        let b = Computed { a.value }
        let c = Computed { a.value }
        var glitches = 0
        let e = Effect.immediate { if b.value != c.value { glitches += 1 } }
        for _ in 0..<10 { a.value += 1 }
        blackHole(e)
        return glitches
    }

    check("equality cutoff: unchanged B does not recompute D", expected: 0) {
        let a = Signal(0)
        let b = Computed { a.value / 1000 }  // stays 0 for small a
        var runs = 0
        let d = Computed { runs += 1; return b.value &+ 1 }
        blackHole(d.value)
        runs = 0
        a.value += 1
        blackHole(d.value)
        return runs
    }

    check("equality cutoff: deep chain below unchanged node (runs of 10 nodes)", expected: 0) {
        let a = Signal(0)
        let gate = Computed { a.value * 0 }
        var runs = 0
        var prev = gate
        for _ in 0..<10 {
            let p = prev
            prev = Computed { runs += 1; return p.value &+ 1 }
        }
        let tail = prev
        blackHole(tail.value)
        runs = 0
        a.value += 1
        blackHole(tail.value)
        return runs
    }

    check("equality cutoff: effect behind unchanged computed does not rerun", expected: 0) {
        let a = Signal(0)
        let b = Computed { a.value / 1000 }
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(b.value) }
        runs = 0
        a.value += 1
        blackHole(e)
        return runs
    }

    check("lazy: never-read computed does not run", expected: 0) {
        let a = Signal(0)
        var runs = 0
        let c = Computed { runs += 1; return a.value }
        for _ in 0..<10 { a.value += 1 }
        blackHole(c)
        return runs
    }

    check("lazy: computed recomputes once for 10 writes then 1 read", expected: 1) {
        let a = Signal(0)
        var runs = 0
        let c = Computed { runs += 1; return a.value }
        blackHole(c.value)
        runs = 0
        for _ in 0..<10 { a.value += 1 }
        blackHole(c.value)
        return runs
    }

    check("dynamic deps: stale branch no longer triggers recompute", expected: 0) {
        let flag = Signal(true)
        let x = Signal(0)
        let y = Signal(0)
        var runs = 0
        let c = Computed { runs += 1; return flag.value ? x.value : y.value }
        blackHole(c.value)
        flag.value = false
        blackHole(c.value)
        runs = 0
        x.value += 1  // x is no longer a dependency
        blackHole(c.value)
        return runs
    }

    check("repeated reads: effect reading a signal 3× reruns once", expected: 1) {
        let a = Signal(0)
        var runs = 0
        let e = Effect.immediate {
            runs += 1
            blackHole(a.value &+ a.value &+ a.value)
        }
        runs = 0
        a.value += 1
        blackHole(e)
        return runs
    }

    check("scheduler: 100 writes then flush reruns effect once", expected: 1) {
        let a = Signal(0)
        var runs = 0
        #if ALIEN
        // alien-signals has no scheduler; a batch is the equivalent
        let e = Effect.immediate { runs += 1; blackHole(a.value) }
        runs = 0
        startBatch()
        for _ in 0..<100 { a.value += 1 }
        endBatch()
        #else
        let scheduler = EffectScheduler()
        let e = Effect(scheduler: scheduler) { runs += 1; blackHole(a.value) }
        runs = 0
        for _ in 0..<100 { a.value += 1 }
        scheduler.flush()
        #endif
        blackHole(e)
        return runs
    }

    // MARK: value checks — a disconnected graph must not pass as "fast"

    check("still live: deep chain ×100 value after 5 writes", expected: 105) {
        let head = Signal(0)
        var node = Computed { head.value &+ 1 }
        for _ in 1..<100 {
            let p = node
            node = Computed { p.value &+ 1 }
        }
        for _ in 0..<5 {
            head.value += 1
            blackHole(node.value)
        }
        return node.value
    }

    check("still live: diamond value after 5 writes", expected: 5 + 1 + 5 * 2) {
        let a = Signal(0)
        let b = Computed { a.value &+ 1 }
        let c = Computed { a.value &* 2 }
        let d = Computed { b.value &+ c.value }
        for _ in 0..<5 {
            a.value += 1
            blackHole(d.value)
        }
        return d.value
    }

    check("still live: fan-out 1→100 sum after 5 writes", expected: 100 * 5) {
        let s = Signal(0)
        let subs = (0..<100).map { _ in Computed { s.value } }
        for _ in 0..<5 {
            s.value += 1
            for c in subs { blackHole(c.value) }
        }
        return subs.reduce(0) { $0 &+ $1.value }
    }

    check("still live: effect reruns on each of 5 writes", expected: 5) {
        let a = Signal(0)
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(a.value) }
        runs = 0
        for _ in 0..<5 { a.value += 1 }
        blackHole(e)
        return runs
    }

    check("deps reorder [a, b] → [b, a]: still reacts to b", expected: 1) {
        let flip = Signal(false)
        let a = Signal(0)
        let b = Signal(0)
        var runs = 0
        let c = Computed {
            runs += 1
            return flip.value ? b.value &+ a.value : a.value &+ b.value
        }
        blackHole(c.value)
        flip.value = true
        blackHole(c.value)
        runs = 0
        b.value += 1
        blackHole(c.value)
        return runs
    }

    check("deps shrink [a, a] → [a]: still reacts to a", expected: 1) {
        let twice = Signal(true)
        let a = Signal(0)
        let other = Signal(0)
        var runs = 0
        let c = Computed {
            runs += 1
            // reads a, other, a (non-adjacent duplicate), then just a
            return twice.value ? a.value &+ other.value &+ a.value : a.value
        }
        blackHole(c.value)
        twice.value = false
        blackHole(c.value)
        runs = 0
        a.value += 1
        blackHole(c.value)
        return runs
    }

    check("effect dynamic deps: stale branch no longer triggers rerun", expected: 0) {
        let flag = Signal(true)
        let x = Signal(0)
        let y = Signal(0)
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(flag.value ? x.value : y.value) }
        flag.value = false
        runs = 0
        x.value += 1
        blackHole(e)
        return runs
    }

    print("check                                                                    expected  actual")
    var failed = 0
    for c in checks {
        let ok = c.expected == c.actual
        if !ok { failed += 1 }
        let name = c.name.count >= 72 ? c.name : c.name + String(repeating: " ", count: 72 - c.name.count)
        print("\(ok ? "✓" : "✗") \(name) \(c.expected)         \(c.actual)")
    }
    print("\(checks.count - failed)/\(checks.count) passed\n")
}
