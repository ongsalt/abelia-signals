import Testing
@testable import AbeliaSignals
import Observation

// Tests run in parallel, so each gets its own runtime. Nonisolated tests
// have no isolation to hop to, so they flush by hand.
func withRuntime(_ body: (Runtime) throws -> Void) rethrows {
    let runtime = Runtime()
    runtime.schedule = { _ in }
    try runtime.run { try body(runtime) }
}

final class Counter {
    var count = 0
}

@Test
func computedIsLazyAndCached() {
    withRuntime { _ in
        let a = Signal(1)
        let runs = Counter()
        let double = Computed {
            runs.count += 1
            return a.value * 2
        }
        #expect(runs.count == 0, "nothing computed until read")

        #expect(double.value == 2)
        #expect(double.value == 2)
        #expect(runs.count == 1)

        a.value = 5
        #expect(runs.count == 1, "writes only mark, reads recompute")
        #expect(double.value == 10)
        #expect(runs.count == 2)
    }
}

@Test
func effectsAreBatchedUntilFlush() {
    withRuntime { runtime in
        let a = Signal(0)
        var seen: [Int] = []
        effect { seen.append(a.value) }
        #expect(seen == [0], "first run is synchronous")

        a.value = 1
        a.value = 2
        a.value = 3
        #expect(seen == [0])

        runtime.flush()
        #expect(seen == [0, 3])

        runtime.flush()
        #expect(seen == [0, 3], "nothing pending")
    }
}

@Test
func diamondRunsEachNodeOnce() {
    withRuntime { runtime in
        let a = Signal(1)
        let b = Computed { a.value + 1 }
        let c = Computed { a.value * 10 }
        let dRuns = Counter()
        let d = Computed {
            dRuns.count += 1
            return b.value + c.value
        }
        var seen: [Int] = []
        effect { seen.append(d.value) }

        a.value = 2
        runtime.flush()
        #expect(seen == [12, 23])
        #expect(dRuns.count == 2)
    }
}

@Test
func unchangedComputedStopsPropagation() {
    withRuntime { runtime in
        let a = Signal(2)
        let isEven = Computed { a.value % 2 == 0 }
        var runs = 0
        effect {
            _ = isEven.value
            runs += 1
        }

        a.value = 4
        runtime.flush()
        #expect(runs == 1, "isEven stayed true")

        a.value = 5
        runtime.flush()
        #expect(runs == 2)
    }
}

@Test
func dependenciesAreDynamic() {
    withRuntime { runtime in
        let flag = Signal(true)
        let a = Signal("a")
        let b = Signal("b")
        var seen: [String] = []
        effect { seen.append(flag.value ? a.value : b.value) }

        flag.value = false
        runtime.flush()
        #expect(seen == ["a", "b"])

        a.value = "A"
        runtime.flush()
        #expect(seen == ["a", "b"], "a is no longer a dependency")

        b.value = "B"
        runtime.flush()
        #expect(seen == ["a", "b", "B"])
    }
}

@Test
func inPlaceMutationIsNotARead() {
    withRuntime { runtime in
        let list = Signal<[Int]>([])
        let other = Signal(0)
        var runs = 0
        effect {
            _ = other.value
            list.value.append(runs)
            runs += 1
        }
        #expect(list.peek == [0])

        list.value.append(99)
        runtime.flush()
        #expect(runs == 1, "the effect only wrote list, it doesn't depend on it")
    }
}

@Test
func computedIsRemovedOnDeinit() {
    withRuntime { _ in
        let a = Signal(1)
        do {
            let c = Computed { a.value + 1 }
            #expect(c.value == 2)
            #expect(a.subscriberCount == 1)
        }
        #expect(a.subscriberCount == 0)
    }
}

@Test
func freeingTheRuntimeStopsItsEffects() {
    weak var freed: Runtime?
    var unscoped: Effect?
    let a = Signal(0)
    do {
        let runtime = Runtime()
        runtime.schedule = { _ in }
        runtime.run {
            let c = Computed { a.value }
            let scope = EffectScope()
            scope.run {
                effect {
                    _ = c.value
                    onCleanup {}
                }
            }
            unscoped = effect { _ = a.value }
        }
        freed = runtime
    }
    #expect(freed == nil, "effects don't keep their runtime alive")
    #expect(unscoped?.isStopped == true)
    #expect(a.subscriberCount == 0)
}

@Test
func cleanupRunsBeforeRerunAndOnStop() {
    withRuntime { runtime in
        let a = Signal(0)
        var log: [String] = []
        let e = effect {
            let v = a.value
            log.append("run \(v)")
            onCleanup { log.append("cleanup \(v)") }
        }

        a.value = 1
        runtime.flush()
        e.stop()
        #expect(log == ["run 0", "cleanup 0", "run 1", "cleanup 1"])
        #expect(e.isStopped)

        a.value = 2
        runtime.flush()
        #expect(log.count == 4, "stopped effect doesn't run")
    }
}

@Test
func nestedEffectsAreStoppedOnParentRerun() {
    withRuntime { runtime in
        let outer = Signal(0)
        let inner = Signal(0)
        var log: [String] = []
        effect {
            let o = outer.value
            effect { log.append("inner \(o) \(inner.value)") }
        }

        inner.value = 1
        runtime.flush()
        outer.value = 1
        runtime.flush()
        inner.value = 2
        runtime.flush()
        #expect(log == ["inner 0 0", "inner 0 1", "inner 1 1", "inner 1 2"], "old inner effect is gone")
    }
}

@Test
func scopeStopsEverythingInside() {
    withRuntime { runtime in
        let a = Signal(0)
        var log: [String] = []
        let scope = EffectScope()
        scope.run {
            effect { log.append("e1 \(a.value)") }
            onCleanup { log.append("scope cleanup") }
            EffectScope().run {
                effect { log.append("child \(a.value)") }
            }
        }

        a.value = 1
        runtime.flush()
        scope.stop()
        a.value = 2
        runtime.flush()

        #expect(log == ["e1 0", "child 0", "e1 1", "child 1", "scope cleanup"])
        #expect(a.subscriberCount == 0)
    }
}

@Test
func scheduleIsCalledOncePerBatch() {
    let runtime = Runtime()
    var scheduled: [() -> Void] = []
    runtime.schedule = { scheduled.append($0) }

    runtime.run {
        let a = Signal(0)
        let b = Signal(0)
        var runs = 0
        effect {
            _ = a.value + b.value
            runs += 1
        }

        a.value = 1
        b.value = 1
        #expect(scheduled.count == 1)
        scheduled.removeFirst()()
        #expect(runs == 2)

        a.value = 2
        #expect(scheduled.count == 1, "next batch schedules again")
    }
    scheduled.removeAll()  // each holds the runtime, which holds `schedule`
}

@MainActor
@Test
func flushHopsBackOntoIsolation() async {
    let runtime = Runtime()
    defer { withExtendedLifetime(runtime) {} }  // effects don't keep it alive
    #expect(runtime.isolation === MainActor.shared)

    let (a, log) = runtime.run {
        let a = Signal(0)
        let log = Counter()
        effect {
            MainActor.assertIsolated()
            log.count = a.value
        }
        return (a, log)
    }

    a.value = 1
    #expect(log.count == 0, "not run synchronously")

    for _ in 0..<100 where log.count == 0 { await Task.yield() }
    #expect(log.count == 1)
}

@Test
func unwatchedComputedDisconnects() {
    withRuntime { runtime in
        let a = Signal(1)
        var runs = 0
        let double = Computed {
            runs += 1
            return a.value * 2
        }
        let e = effect { _ = double.value }
        #expect(a.subscriberCount == 1)

        e.stop()
        #expect(a.subscriberCount == 0, "no one watches double, so it let go of a")

        a.value = 5
        #expect(runs == 1)
        #expect(double.value == 10, "recomputed on read")
    }
}

@MainActor @Observable
final class CounterModel {
    var count = 0
}

@MainActor
@Test
func observedComputedIsMarkedSynchronously() async {
    let runtime = Runtime()
    defer { withExtendedLifetime(runtime) {} }  // effects don't keep it alive
    let model = CounterModel()
    let offset = runtime.run { Signal(10) }
    let total = runtime.run { Computed.observing { model.count + offset.value } }
    var seen: [Int] = []
    runtime.run { effect { seen.append(total.value) } }

    model.count = 1
    #expect(total.value == 11, "no hop needed on the runtime's isolation")

    offset.value = 20
    model.count = 2
    for _ in 0..<100 where seen.count < 2 { await Task.yield() }
    #expect(seen == [10, 22], "both sources land in one batched flush")
}

@Observable
final class SharedModel: @unchecked Sendable {
    var count = 0
}

@MainActor
@Test
func observedChangeFromAnotherThreadHops() async {
    let runtime = Runtime()
    defer { withExtendedLifetime(runtime) {} }  // effects don't keep it alive
    let model = SharedModel()
    let doubled = runtime.run { Computed.observing { model.count * 2 } }
    var seen: [Int] = []
    runtime.run { effect { seen.append(doubled.value) } }

    await Task.detached { model.count = 3 }.value
    for _ in 0..<100 where seen.count < 2 { await Task.yield() }
    #expect(seen == [0, 6])
}

@Observable
final class PairModel {
    var a = 0
    var b = 0
}

@Test
func observedComputedIgnoresSourcesItNoLongerReads() {
    withRuntime { runtime in
        let model = PairModel()
        let useA = Signal(true)
        let runs = Counter()
        let picked = Computed.observing {
            runs.count += 1
            return useA.value ? model.a : model.b
        }
        effect { _ = picked.value }

        useA.value = false
        runtime.flush()
        #expect(runs.count == 2)

        model.a = 1
        runtime.flush()
        #expect(runs.count == 2, "the observation from the first compute is stale")

        model.b = 1
        runtime.flush()
        #expect(runs.count == 3)
    }
}

actor IsolatedOwner {
    func makeObservingComputed() {
        let runtime = Runtime()
        runtime.run { _ = Computed.observing { 1 }.value }
    }
}

@Test
func observingComputedDoesNotRetainItsIsolation() async {
    weak var freed: IsolatedOwner?
    do {
        let owner = IsolatedOwner()
        freed = owner
        await owner.makeObservingComputed()
    }
    #expect(freed == nil)
}

@MainActor
@Test
func defaultRuntimeFlushesOnMainActor() async {
    #expect(Runtime.current().isolation === MainActor.shared)

    let a = Signal(0)
    let log = Counter()
    let e = effect { log.count = a.value }
    defer { e.stop() }

    a.value = 1
    for _ in 0..<100 where log.count == 0 { await Task.yield() }
    #expect(log.count == 1, "no flush() or schedule needed")
}

final class Log {
    var values: [Int] = []
}

actor Store: RuntimeOwner {
    let signalsRuntime = Runtime()
    let count = Signal(0)
    let log = Log()
    var observed: Computed<Int>?

    var seen: [Int] { log.values }

    func start() {
        effect { [count, log] in log.values.append(count.value) }
        observed = Computed.observing { 1 }
        _ = observed?.value
    }

    func bump() { count.value += 1 }

    func runtimeIsOwn() -> Bool { Runtime.current().isolation === self }
}

@Test
func actorOwnsItsRuntime() async {
    weak var freed: Store?
    do {
        let store = Store()
        freed = store
        #expect(await store.runtimeIsOwn())
        await store.start()
        await store.bump()
        for _ in 0..<100 where await store.seen.count < 2 { await Task.yield() }
        #expect(await store.seen == [0, 1], "flushed on the store without any setup")
    }
    #expect(freed == nil, "the store, its runtime and its effects go together")
}

@Test
func computedCanStopItsReaderMidCheck() {
    withRuntime { runtime in
        let a = Signal(0)
        var reader: Effect?
        let c = Computed { () -> Int in
            let value = a.value
            if value == 1 {
                // unlinks every link the walk that's running this is standing on
                reader?.stop()
                reader = nil
            }
            return value
        }
        let mid = Computed { c.value + 1 }
        reader = effect { _ = mid.value }

        a.value = 1
        runtime.flush()
        #expect(reader == nil)
        #expect(mid.peek == 2)
    }
}
