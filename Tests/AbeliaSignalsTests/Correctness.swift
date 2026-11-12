// Shared by AbeliaSignalsTests (v1, `-D V1`) and AbeliaSignalsV2Tests (v2, `-D V2`, symlinked,
// with V2Shim mapping the v1 names onto the node API).
//
// "Does it do the minimal amount of work?" counters, plus value checks so a disconnected graph
// can't pass as fast.

import AbeliaSignals
import Dispatch
import Synchronization
import Testing

// keeps effects alive (and values used) until the end of a test
@inline(never)
func blackHole<T>(_ x: T) {}

// deterministic, so a failing randomized test fails the same way every run
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

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

    // dependency lists that grow, shrink, reorder and repeat on every write: the edge bookkeeping
    // (reuse by position, unlink, back indices) must keep every computed reacting correctly
    @Test("randomized dynamic deps: values match direct evaluation")
    func randomizedDynamicDeps() {
        var rng = SplitMix64(seed: 42)
        let raw = (0..<12).map { _ in Int.random(in: 0..<100, using: &rng) }
        let signals = raw.map { Signal($0) }
        let pick = Signal(0)  // changes which signals each computed reads

        // computed k reads a pick-dependent list of signals, with duplicates
        func reads(_ k: Int, _ p: Int) -> [Int] {
            (0..<((k + p) % 6 + 1)).map { (k * 7 + p * 3 + $0 * 5) % 12 }
        }
        let computeds = (0..<20).map { k in
            Computed { reads(k, pick.value).reduce(0) { $0 &+ signals[$1].value } }
        }

        var model = raw
        var p = 0
        for step in 0..<300 {
            if step % 3 == 0 {
                p = Int.random(in: 0..<10, using: &rng)
                pick.value = p
            } else {
                let i = Int.random(in: 0..<12, using: &rng)
                model[i] = Int.random(in: 0..<100, using: &rng)
                signals[i].value = model[i]
            }
            for (k, c) in computeds.enumerated() {
                let expected = reads(k, p).reduce(0) { $0 &+ model[$1] }
                #expect(c.value == expected, "step \(step), computed \(k)")
            }
        }
    }

    // MARK: v2 `update`

    #if V2
    // MARK: v2 scopes

    @Test("scope: keeps its effects alive without a handle, dispose stops them")
    func scopeOwnsEffects() {
        let a = Signal(0)
        var runs = 0
        let scope = EffectScopeNode()
        scope.run {
            _ = Effect.immediate { runs += 1; blackHole(a.value) }  // handle dropped
        }
        a.value += 1
        #expect(runs == 2)  // initial run + rerun: the scope kept it alive
        scope.dispose()
        a.value += 1
        #expect(runs == 2)
    }

    @Test("scope: without one, dropping the handle ends the effect")
    func noScopeHandleOwns() {
        let a = Signal(0)
        var runs = 0
        _ = Effect.immediate { runs += 1; blackHole(a.value) }
        a.value += 1
        #expect(runs == 1)  // only the initial run
    }

    @Test("scope: effect.dispose stops it and detaches it from its scope")
    func effectDispose() {
        let a = Signal(0)
        var runs = 0
        let scope = EffectScopeNode()
        let e = scope.run { Effect.immediate { runs += 1; blackHole(a.value) } }
        e.dispose()
        a.value += 1
        #expect(runs == 1)
        scope.dispose()  // e is no longer in it: no double dispose
        e.dispose()  // idempotent
    }

    @Test("scope: an effect created in an effect is disposed on the outer rerun")
    func nestedEffectOwnedByOuterRun() {
        let outer = Signal(0)
        let inner = Signal(0)
        var innerRuns = 0
        let e = Effect.immediate {
            blackHole(outer.value)
            _ = Effect.immediate { innerRuns += 1; blackHole(inner.value) }
        }
        #expect(innerRuns == 1)
        inner.value += 1
        #expect(innerRuns == 2)  // the outer run's inner scope keeps it alive
        outer.value += 1  // outer reruns: old inner disposed, a new one created
        #expect(innerRuns == 3)
        inner.value += 1
        #expect(innerRuns == 4)  // only the new inner effect reacts
        blackHole(e)
    }

    // inner reads `a` before outer does, so a write queues inner first; the outer must still
    // rerun first, disposing the old inner before it gets a pointless rerun
    @Test("scope: the outer effect reruns before its pending children")
    func outerRerunsBeforePendingChildren() {
        let a = Signal(0)
        var innerRuns = 0
        let outer = Effect.immediate {
            _ = Effect.immediate { innerRuns += 1; blackHole(a.value) }
            blackHole(a.value)  // after creating inner: inner is a's first sink
        }
        innerRuns = 0
        a.value += 1
        #expect(innerRuns == 1)  // only the new inner's first run
        blackHole(outer)
    }

    // the outer is only `.maybe` (behind a computed that doesn't change): it won't rerun, so the
    // pending child must still run, and must not be recreated
    @Test("scope: a child still runs when its pending owner turns out unchanged")
    func childRunsWhenOwnerUnchanged() {
        let a = Signal(0)
        let stable = Computed { a.value / 1000 }  // stays 0
        var outerRuns = 0
        var innerRuns = 0
        let outer = Effect.immediate {
            outerRuns += 1
            _ = Effect.immediate { innerRuns += 1; blackHole(a.value) }
            blackHole(stable.value)
        }
        outerRuns = 0
        innerRuns = 0
        a.value += 1
        #expect(outerRuns == 0)
        #expect(innerRuns == 1)
        blackHole(outer)
    }

    @Test("batch: an effect dropped while queued does not run")
    func droppedWhileQueued() {
        let a = Signal(0)
        var runs = 0
        var e: EffectNode? = Effect.immediate { runs += 1; blackHole(a.value) }
        runs = 0
        batch {
            a.value += 1  // queues e
            e = nil  // last handle gone: only the queue still holds it
        }
        #expect(runs == 0)
        blackHole(e)
    }

    @Test("scope: what cleanups read isn't tracked into the effect that disposes")
    func cleanupReadsUntracked() {
        let x = Signal(0)
        let trigger = Signal(0)
        var outerRuns = 0
        let victim = Effect.immediate { onCleanup { blackHole(x.value) } }
        let outer = Effect.immediate {
            outerRuns += 1
            if trigger.value == 1 { victim.dispose() }  // the cleanup runs inside outer's body
        }
        trigger.value = 1
        outerRuns = 0
        x.value += 1  // outer itself never read x
        #expect(outerRuns == 0)
        blackHole(outer)
    }

    @Test("scope: an effect disposing itself mid-run ignores the rest of its reads")
    func selfDisposeMidRun() {
        let a = Signal(0)
        let b = Signal(0)
        var runs = 0
        var me: EffectNode?
        let e = Effect.immediate {
            runs += 1
            blackHole(a.value)
            me?.dispose()
            blackHole(b.value)  // after dispose: not tracked
        }
        me = e
        a.value += 1  // reruns, disposes itself, then reads b
        runs = 0
        b.value += 1
        a.value += 1
        #expect(runs == 0)
    }

    @Test("scope: onCleanup in an effect runs before each rerun and on dispose")
    func effectCleanup() {
        let a = Signal(0)
        var cleanups: [Int] = []
        let e = Effect.immediate {
            let v = a.value
            onCleanup { cleanups.append(v) }
        }
        a.value = 1
        a.value = 2
        #expect(cleanups == [0, 1])
        e.dispose()
        #expect(cleanups == [0, 1, 2])
    }

    @Test("scope: dispose runs cleanups last to first and disposes child scopes")
    func scopeCleanupOrder() {
        var log: [String] = []
        let root = EffectScopeNode()
        root.run {
            onCleanup { log.append("root 1") }
            let child = EffectScopeNode()
            child.run { onCleanup { log.append("child") } }
            onCleanup { log.append("root 2") }
        }
        root.dispose()
        #expect(log == ["child", "root 2", "root 1"])
    }

    @Test("scope: a cleanup that disposes a sibling during dispose is fine")
    func cleanupDisposesSibling() {
        let a = Signal(0)
        var runs = 0
        let scope = EffectScopeNode()
        scope.run {
            let sibling = Effect.immediate { runs += 1; blackHole(a.value) }
            _ = Effect.immediate { onCleanup { sibling.dispose() } }
        }
        scope.dispose()
        a.value += 1
        #expect(runs == 1)
    }

    @Test("batch: nested batches flush once, at the outermost end")
    func nestedBatchFlushesAtOuterEnd() {
        let a = Signal(0)
        let b = Signal(0)
        var runs = 0
        var glitches = 0
        let e = Effect.immediate {
            runs += 1
            if a.value != b.value { glitches += 1 }
        }
        runs = 0
        batch {
            a.value = 1
            batch { b.value = 1 }  // an inner flush here would see a == 1, b == 1 too early
            a.value = 2
            b.value = 2
        }
        blackHole(e)
        #expect(runs == 1)
        #expect(glitches == 0)
    }

    @Test("batch: an effect writing a signal runs its dependents in the same flush")
    func effectWritingSignalRunsDependents() {
        let a = Signal(0)
        let doubled = Signal(0)
        var seen = -1
        let writer = Effect.immediate { doubled.value = a.value &* 2 }
        let reader = Effect.immediate { seen = doubled.value }
        a.value = 21
        blackHole((writer, reader))
        #expect(seen == 42)
    }

    @Test("batch: effects chained through signals settle in one write")
    func effectChainSettles() {
        let s = (0..<5).map { _ in Signal(0) }
        let effects = (0..<4).map { i in Effect.immediate { s[i + 1].value = s[i].value &+ 1 } }
        s[0].value = 10
        blackHole(effects)
        #expect(s[4].value == 14)
    }

    // tracking state is thread-local: independent graphs on different threads don't interfere
    @Test("threads: independent graphs track concurrently")
    func threadLocalTracking() {
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            let a = Signal(t)
            let b = Computed { a.value &* 2 }
            let c = Computed { b.value &+ a.value }
            var seen = 0
            let e = Effect.immediate { seen = c.value }
            for i in 0..<2000 {
                a.value = t &* 10_000 &+ i
                if c.value != (t &* 10_000 &+ i) &* 3 || seen != c.value {
                    failures.withLock { $0 += 1 }
                }
            }
            blackHole(e)
        }
        #expect(failures.withLock { $0 } == 0)
    }

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
