// Shared by AbeliaSignalsTests (v1, `-D V1`) and AbeliaSignalsV2Tests (v2, `-D V2`, symlinked,
// with V2Shim mapping the v1 names onto the node API).
//
// "Does it do the minimal amount of work?" counters, plus value checks so a disconnected graph
// can't pass as fast.

import AbeliaSignals
import Testing

// keeps effects alive (and values used) until the end of a test
@inline(never)
func blackHole<T>(_ x: T) {}

// the reactivity runtime uses globals (current sink, current batch): no parallel tests
@Suite(.serialized)
struct Correctness {
    @Test("diamond: D recomputes once per write")
    func diamondRecomputesOnce() {
        let a = Signal(0)
        let b = Computed { a.value &+ 1 }
        let c = Computed { a.value &* 2 }
        var runs = 0
        let d = Computed { runs += 1; return b.value &+ c.value }
        blackHole(d.value)
        runs = 0
        a.value += 1
        blackHole(d.value)
        #expect(runs == 1)
    }

    @Test("diamond: immediate effect reruns once per write")
    func diamondEffectRerunsOnce() {
        let a = Signal(0)
        let b = Computed { a.value &+ 1 }
        let c = Computed { a.value &* 2 }
        let d = Computed { b.value &+ c.value }
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(d.value) }
        runs = 0
        a.value += 1
        blackHole(e)
        #if V1
        withKnownIssue("v1: `Effect.immediate` runs during propagation (readme, Bugs)") {
            #expect(runs == 1)
        }
        #else
        #expect(runs == 1)
        #endif
    }

    @Test("diamond: effect never sees glitch")
    func diamondNoGlitch() {
        let a = Signal(0)
        let b = Computed { a.value }
        let c = Computed { a.value }
        var glitches = 0
        let e = Effect.immediate { if b.value != c.value { glitches += 1 } }
        for _ in 0..<10 { a.value += 1 }
        blackHole(e)
        #if V1
        withKnownIssue("v1: `Effect.immediate` sees glitched state (readme, Bugs)") {
            #expect(glitches == 0)
        }
        #else
        #expect(glitches == 0)
        #endif
    }

    @Test("equality cutoff: unchanged B does not recompute D")
    func cutoffSkipsDownstream() {
        let a = Signal(0)
        let b = Computed { a.value / 1000 }  // stays 0 for small a
        var runs = 0
        let d = Computed { runs += 1; return b.value &+ 1 }
        blackHole(d.value)
        runs = 0
        a.value += 1
        blackHole(d.value)
        #expect(runs == 0)
    }

    @Test("equality cutoff: deep chain below unchanged node")
    func cutoffSkipsDeepChain() {
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
        #expect(runs == 0)
    }

    @Test("equality cutoff: effect behind unchanged computed does not rerun")
    func cutoffSkipsEffect() {
        let a = Signal(0)
        let b = Computed { a.value / 1000 }
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(b.value) }
        runs = 0
        a.value += 1
        blackHole(e)
        #expect(runs == 0)
    }

    @Test("lazy: never-read computed does not run")
    func lazyNeverRead() {
        let a = Signal(0)
        var runs = 0
        let c = Computed { runs += 1; return a.value }
        for _ in 0..<10 { a.value += 1 }
        blackHole(c)
        #expect(runs == 0)
    }

    @Test("lazy: computed recomputes once for 10 writes then 1 read")
    func lazyOneRecompute() {
        let a = Signal(0)
        var runs = 0
        let c = Computed { runs += 1; return a.value }
        blackHole(c.value)
        runs = 0
        for _ in 0..<10 { a.value += 1 }
        blackHole(c.value)
        #expect(runs == 1)
    }

    @Test("dynamic deps: stale branch no longer triggers recompute")
    func dynamicDepsDropStale() {
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
        #expect(runs == 0)
    }

    @Test("repeated reads: effect reading a signal 3× reruns once")
    func repeatedReadsRerunOnce() {
        let a = Signal(0)
        var runs = 0
        let e = Effect.immediate {
            runs += 1
            blackHole(a.value &+ a.value &+ a.value)
        }
        runs = 0
        a.value += 1
        blackHole(e)
        #expect(runs == 1)
    }

    @Test("scheduler: 100 writes then flush reruns effect once")
    func batchedWritesRerunOnce() {
        let a = Signal(0)
        var runs = 0
        #if V2
        // v2 only has immediate effects; a batch is the equivalent
        let e = Effect.immediate { runs += 1; blackHole(a.value) }
        runs = 0
        batch {
            for _ in 0..<100 { a.value += 1 }
        }
        #else
        let scheduler = EffectScheduler()
        let e = Effect(scheduler: scheduler) { runs += 1; blackHole(a.value) }
        runs = 0
        for _ in 0..<100 { a.value += 1 }
        scheduler.flush()
        #endif
        blackHole(e)
        #expect(runs == 1)
    }

    // MARK: value checks: a disconnected graph must not pass as "fast"

    @Test("still live: deep chain ×100 value after 5 writes")
    func liveDeepChain() {
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
        #expect(node.value == 105)
    }

    @Test("still live: diamond value after 5 writes")
    func liveDiamond() {
        let a = Signal(0)
        let b = Computed { a.value &+ 1 }
        let c = Computed { a.value &* 2 }
        let d = Computed { b.value &+ c.value }
        for _ in 0..<5 {
            a.value += 1
            blackHole(d.value)
        }
        #expect(d.value == 5 + 1 + 5 * 2)
    }

    // b is recomputed by the first reader; the second reader must still see that it changed
    @Test("still live: shared computed, second reader after 5 writes")
    func liveSharedComputed() {
        let a = Signal(0)
        let b = Computed { a.value &+ 1 }
        let c = Computed { b.value &+ 1 }
        let d = Computed { b.value &+ 2 }
        for _ in 0..<5 {
            a.value += 1
            blackHole(c.value)
            blackHole(d.value)
        }
        #expect(d.value == 5 + 1 + 2)
    }

    @Test("still live: fan-out 1→100 sum after 5 writes")
    func liveFanOut() {
        let s = Signal(0)
        let subs = (0..<100).map { _ in Computed { s.value } }
        for _ in 0..<5 {
            s.value += 1
            for c in subs { blackHole(c.value) }
        }
        #expect(subs.reduce(0) { $0 &+ $1.value } == 100 * 5)
    }

    @Test("still live: effect reruns on each of 5 writes")
    func liveEffect() {
        let a = Signal(0)
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(a.value) }
        runs = 0
        for _ in 0..<5 { a.value += 1 }
        blackHole(e)
        #expect(runs == 5)
    }

    @Test("deps reorder [a, b] → [b, a]: still reacts to b")
    func depsReorder() {
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
        #expect(runs == 1)
    }

    @Test("deps shrink [a, other, a] → [a]: still reacts to a")
    func depsShrink() {
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
        #expect(runs == 1)
    }

    @Test("effect dynamic deps: stale branch no longer triggers rerun")
    func effectDynamicDeps() {
        let flag = Signal(true)
        let x = Signal(0)
        let y = Signal(0)
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(flag.value ? x.value : y.value) }
        flag.value = false
        runs = 0
        x.value += 1
        blackHole(e)
        #expect(runs == 0)
    }

    // MARK: v2 `update`

    #if V2
    @Test("update: propagates even when the value is unchanged")
    func updateAlwaysPropagates() {
        let a = Signal(0)
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(a.value) }
        runs = 0
        a.update { $0 = 0 }
        blackHole(e)
        #expect(runs == 1)
    }

    @Test("update: effect flushed after update can read the signal")
    func updateClearsFlagBeforeNotify() {
        let a = Signal(0)
        var seen = 0
        let e = Effect.immediate { seen = a.value }
        a.update { $0 = 5 }
        blackHole(e)
        #expect(seen == 5)
    }

    // the manual exclusivity check: touching the signal while `update` holds `&_value` traps
    @Test("update: reading the signal inside its own update traps")
    func updateConflictTraps() async {
        await #expect(processExitsWith: .failure) {
            let s = Signal(1)
            s.update { v in v += s.value }
        }
    }
    #endif
}
