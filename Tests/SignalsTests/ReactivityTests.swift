import Dispatch
import Observation
import Testing

@testable import AbeliaSignals

// Tests run in parallel, so each gets its own scheduler. Nonisolated tests
// have no isolation to hop to, so they flush by hand.
func withScheduler(_ body: (EffectScheduler) throws -> Void) rethrows {
    let scheduler = EffectScheduler()
    scheduler.schedule = { _ in }
    try scheduler.run { try body(scheduler) }
}

final class Counter {
    var count = 0
}

@Test
func computedIsLazyAndCached() {
    withScheduler { _ in
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
    withScheduler { scheduler in
        let a = Signal(0)
        var seen: [Int] = []
        effect { seen.append(a.value) }
        #expect(seen == [0], "first run is synchronous")

        a.value = 1
        a.value = 2
        a.value = 3
        #expect(seen == [0])

        scheduler.flush()
        #expect(seen == [0, 3])

        scheduler.flush()
        #expect(seen == [0, 3], "nothing pending")
    }
}

@Test
func diamondRunsEachNodeOnce() {
    withScheduler { scheduler in
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
        scheduler.flush()
        #expect(seen == [12, 23])
        #expect(dRuns.count == 2)
    }
}

@Test
func unchangedComputedStopsPropagation() {
    withScheduler { scheduler in
        let a = Signal(2)
        let isEven = Computed { a.value % 2 == 0 }
        var runs = 0
        effect {
            _ = isEven.value
            runs += 1
        }

        a.value = 4
        scheduler.flush()
        #expect(runs == 1, "isEven stayed true")

        a.value = 5
        scheduler.flush()
        #expect(runs == 2)
    }
}

@Test
func dependenciesAreDynamic() {
    withScheduler { scheduler in
        let flag = Signal(true)
        let a = Signal("a")
        let b = Signal("b")
        var seen: [String] = []
        effect { seen.append(flag.value ? a.value : b.value) }

        flag.value = false
        scheduler.flush()
        #expect(seen == ["a", "b"])

        a.value = "A"
        scheduler.flush()
        #expect(seen == ["a", "b"], "a is no longer a dependency")

        b.value = "B"
        scheduler.flush()
        #expect(seen == ["a", "b", "B"])
    }
}

@Test
func inPlaceMutationIsNotARead() {
    withScheduler { scheduler in
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
        scheduler.flush()
        #expect(runs == 1, "the effect only wrote list, it doesn't depend on it")
    }
}

@Test
func computedIsRemovedOnDeinit() {
    withScheduler { _ in
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
func freeingTheSchedulerStopsItsEffects() {
    weak var freed: EffectScheduler?
    var unscoped: Effect?
    let a = Signal(0)
    do {
        let scheduler = EffectScheduler()
        scheduler.schedule = { _ in }
        scheduler.run {
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
        freed = scheduler
    }
    #expect(freed == nil, "effects don't keep their scheduler alive")
    #expect(unscoped?.isStopped == true)
    #expect(a.subscriberCount == 0)
}

@Test
func cleanupRunsBeforeRerunAndOnStop() {
    withScheduler { scheduler in
        let a = Signal(0)
        var log: [String] = []
        let e = effect {
            let v = a.value
            log.append("run \(v)")
            onCleanup { log.append("cleanup \(v)") }
        }

        a.value = 1
        scheduler.flush()
        e.stop()
        #expect(log == ["run 0", "cleanup 0", "run 1", "cleanup 1"])
        #expect(e.isStopped)

        a.value = 2
        scheduler.flush()
        #expect(log.count == 4, "stopped effect doesn't run")
    }
}

@Test
func nestedEffectsAreStoppedOnParentRerun() {
    withScheduler { scheduler in
        let outer = Signal(0)
        let inner = Signal(0)
        var log: [String] = []
        effect {
            let o = outer.value
            effect { log.append("inner \(o) \(inner.value)") }
        }

        inner.value = 1
        scheduler.flush()
        outer.value = 1
        scheduler.flush()
        inner.value = 2
        scheduler.flush()
        #expect(
            log == ["inner 0 0", "inner 0 1", "inner 1 1", "inner 1 2"], "old inner effect is gone")
    }
}

@Test
func scopeStopsEverythingInside() {
    withScheduler { scheduler in
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
        scheduler.flush()
        scope.stop()
        a.value = 2
        scheduler.flush()

        #expect(log == ["e1 0", "child 0", "e1 1", "child 1", "scope cleanup"])
        #expect(a.subscriberCount == 0)
    }
}

@Test
func scheduleIsCalledOncePerBatch() {
    let scheduler = EffectScheduler()
    var scheduled: [() -> Void] = []
    scheduler.schedule = { scheduled.append($0) }

    scheduler.run {
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
    scheduled.removeAll()  // each holds the scheduler, which holds `schedule`
}

@MainActor
@Test
func flushHopsBackOntoIsolation() async {
    let scheduler = EffectScheduler()
    defer { withExtendedLifetime(scheduler) {} }  // effects don't keep it alive
    #expect(scheduler.isolation === MainActor.shared)

    let (a, log) = scheduler.run {
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
    withScheduler { scheduler in
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
    let scheduler = EffectScheduler()
    defer { withExtendedLifetime(scheduler) {} }  // effects don't keep it alive
    let model = CounterModel()
    let offset = scheduler.run { Signal(10) }
    let total = scheduler.run { Computed.observing { model.count + offset.value } }
    var seen: [Int] = []
    scheduler.run { effect { seen.append(total.value) } }

    model.count = 1
    #expect(total.value == 11, "no hop needed on the scheduler's isolation")

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
    let scheduler = EffectScheduler()
    defer { withExtendedLifetime(scheduler) {} }  // effects don't keep it alive
    let model = SharedModel()
    let doubled = scheduler.run { Computed.observing { model.count * 2 } }
    var seen: [Int] = []
    scheduler.run { effect { seen.append(doubled.value) } }

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
    withScheduler { scheduler in
        let model = PairModel()
        let useA = Signal(true)
        let runs = Counter()
        let picked = Computed.observing {
            runs.count += 1
            return useA.value ? model.a : model.b
        }
        effect { _ = picked.value }

        useA.value = false
        scheduler.flush()
        #expect(runs.count == 2)

        model.a = 1
        scheduler.flush()
        #expect(runs.count == 2, "the observation from the first compute is stale")

        model.b = 1
        scheduler.flush()
        #expect(runs.count == 3)
    }
}

actor IsolatedOwner {
    func makeObservingComputed() {
        let scheduler = EffectScheduler()
        scheduler.run { _ = Computed.observing { 1 }.value }
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

final class Log {
    var values: [Int] = []
}

actor Store: EffectSchedulerOwner {
    lazy var effectScheduler = EffectScheduler(owner: self)
    let count = Signal(0)
    let log = Log()
    var observed: Computed<Int>?

    var seen: [Int] { log.values }

    func start() {
        makeAppendingEffect(count, log)
        observed = Computed.observing { 1 }
        _ = observed?.value
    }

    func bump() { count.value += 1 }

    func schedulerIsOwn() -> Bool { EffectScheduler.current === effectScheduler }
}

// sync and not isolated: the scheduler comes from the executor running it
nonisolated func makeAppendingEffect(_ count: Signal<Int>, _ log: Log) {
    effect { log.values.append(count.value) }
}

@Test
func actorOwnsItsScheduler() async {
    weak var freed: Store?
    do {
        let store = Store()
        freed = store
        #expect(await store.schedulerIsOwn())
        await store.start()
        await store.bump()
        for _ in 0..<100 where await store.seen.count < 2 { await Task.yield() }
        #expect(await store.seen == [0, 1], "flushed on the store")
    }
    #expect(freed == nil, "the store, its scheduler and its effects go together")
}

@Test
func computedCanStopItsReaderMidCheck() {
    withScheduler { scheduler in
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
        scheduler.flush()
        #expect(reader == nil)
        #expect(mid.peek == 2)
    }
}

struct Opaque {
    var id = 0
}

final class WrappedModel {
    @Signal var count = 0
    @Signal var opaque = Opaque()
    let doubledRuns = Counter()

    @Computed
    var doubled: Int {
        doubledRuns.count += 1
        return count * 2
    }
}

@Test
func propertyWrappers() {
    withScheduler { scheduler in
        let model = WrappedModel()
        var seen: [Int] = []
        effect { seen.append(model.doubled) }

        model.count = 1
        scheduler.flush()
        model.count = 1
        scheduler.flush()
        #expect(seen == [0, 2], "an equal write doesn't notify")

        model.count += 1
        scheduler.flush()
        #expect(seen == [0, 2, 4])
        #expect(model.$count.peek == 2)
        #expect(model.doubled == 4)
        #expect(model.$doubled.peek == 4, "$doubled is the Computed")
        #expect(model.doubledRuns.count == 3, "cached between changes")

        var opaqueRuns = 0
        effect {
            _ = model.opaque
            opaqueRuns += 1
        }
        model.opaque = Opaque()
        scheduler.flush()
        #expect(opaqueRuns == 2, "not Equatable: every write notifies")
    }
}

@Test
func computedMacroDoesNotRetainItsObject() {
    weak var freed: WrappedModel?
    do {
        let model = WrappedModel()
        freed = model
        #expect(model.doubled == 0)
    }
    #expect(freed == nil)
}

nonisolated func makeLoggingEffect(_ a: Signal<Int>, _ log: Counter) -> Effect {
    effect { log.count = a.value }
}

@MainActor
@Test
func effectDeepInNonisolatedCodeUsesTheBoundScheduler() async {
    let scheduler = EffectScheduler()
    defer { withExtendedLifetime(scheduler) {} }  // effects don't keep it alive
    let a = Signal(0)
    let log = Counter()
    let e = scheduler.run { makeLoggingEffect(a, log) }
    #expect(e.scheduler === scheduler)

    a.value = 1
    for _ in 0..<100 where log.count == 0 { await Task.yield() }
    #expect(log.count == 1, "flushed on the main actor, where the scheduler was made")
}

@MainActor
@Test
func mainActorCodeUsesTheMainScheduler() async {
    let a = Signal(0)
    let log = Counter()
    let e = makeLoggingEffect(a, log)
    defer { e.stop() }
    #expect(e.scheduler === EffectScheduler.main)

    a.value = 1
    for _ in 0..<100 where log.count == 0 { await Task.yield() }
    #expect(log.count == 1)
}

@MainActor
@Test
func mainQueueCallbackUsesTheMainScheduler() async {
    let found = await withCheckedContinuation { continuation in
        // a dispatch callback isn't a task, so there's no executor to go by
        DispatchQueue.main.async {
            let isMain = EffectScheduler.current === EffectScheduler.main
            continuation.resume(returning: isMain)
        }
    }
    #expect(found)
}

actor NotAnOwner {
    func makeEffect() { _ = effect {} }
}

@Test
func actorThatIsntAnOwnerTraps() async {
    await #expect(processExitsWith: .failure) {
        await NotAnOwner().makeEffect()
    }
}

final class ExternalModel {
    let source: Signal<Int>

    init(_ source: Signal<Int>) { self.source = source }

    @Computed
    var doubled: Int { source.value * 2 }
}

@Test
func readingAComputedKeepsItsObjectAlive() {
    withScheduler { scheduler in
        let source = Signal(1)
        weak var freed: ExternalModel?
        var seen: [Int?] = []
        var reader: Effect?
        do {
            let model = ExternalModel(source)
            freed = model
            reader = effect { [weak model] in seen.append(model?.doubled) }
        }
        #expect(freed != nil, "the reader links to model.doubled, which holds model")

        // used to trap: the reader's checkDirty recomputed doubled after model was gone
        source.value = 2
        scheduler.flush()
        #expect(seen == [2, 4])

        reader?.stop()
        #expect(freed == nil, "unwatched, it lets go")
    }
}

final class Flag: @unchecked Sendable {
    var fired = false
}

// an Observation observer of `observed.value`
func watch<Value>(_ observed: Observed<Value>) -> Flag {
    let flag = Flag()
    withObservationTracking({ _ = observed.value }, onChange: { flag.fired = true })
    return flag
}

@Test
func observedMirrorsIntoObservation() {
    withScheduler { scheduler in
        let a = Signal(1)
        let doubled = Observed { a.value * 2 }
        #expect(doubled.value == 2)

        let flag = watch(doubled)
        a.value = 2
        #expect(doubled.value == 2 && !flag.fired, "updated in the flush, not on write")

        scheduler.flush()
        #expect(doubled.value == 4)
        #expect(flag.fired)
    }
}

@Test
func observedSkipsEqualValues() {
    withScheduler { scheduler in
        let a = Signal(2)
        let isEven = Observed { a.value % 2 == 0 }
        let flag = watch(isEven)

        a.value = 4
        scheduler.flush()
        #expect(!flag.fired, "still true: Observation isn't told")
    }
}

@Test
func freeingObservedStopsItsEffect() {
    withScheduler { _ in
        let a = Signal(1)
        weak var freed: Observed<Int>?
        do {
            let doubled = Observed { a.value * 2 }
            freed = doubled
            #expect(a.subscriberCount == 1)
        }
        #expect(freed == nil)
        #expect(a.subscriberCount == 0)
    }
}
