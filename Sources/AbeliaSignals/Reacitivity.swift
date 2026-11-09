import Synchronization

protocol Source<T>: AnyObject, Identifiable<UInt64> {
    associatedtype T
    // only use for compute state `.maybe` checking
    var state: State { get }

    func addSink(_ sink: any Sink)
    func removeSink(_ sink: any Sink)
}

protocol Sink: AnyObject, Identifiable<UInt64> {
    func trackRead(_ source: any Source)
    func notify(direct: Bool)
}

struct WeakSink {
    weak var sink: any Sink?
    /// number of slots in the sink's `sources` that point at this source
    var count: Int = 1
}

enum State {
    case dirty
    case maybe
    case clean
}

let currentId = Atomic<UInt64>(0)

public final class Signal<T>: Source<T> {
    public let id = currentId.add(1, ordering: .relaxed).oldValue
    @exclusivity(unchecked)
    var _value: T
    let equals: ((T, T) -> Bool)?

    var sinks: [UInt64: WeakSink] = [:]
    var state: State { .clean }

    public var value: T {
        get {
            currentSink?.trackRead(self)
            return _value
        }

        set {
            if equals == nil || !equals!(newValue, _value) {
                _value = newValue
                propagate()
            }
        }

        // TODO: get around this
        // _modify {
        //     yield &_value
        //     propagate()
        // }
    }

    public var peek: T { _value }

    public init(_ value: T, equals: ((T, T) -> Bool)?) {
        self._value = value
        self.equals = equals
    }

    func propagate() {
        // ordering shouldnt be guaranteed?

        // this job can be queued + dedup
        sinks = sinks.filter { $0.value.sink != nil }
        for d in sinks {
            d.value.sink!.notify(direct: true)
        }
    }

    func removeSink(_ sink: any Sink) {
        guard let entry = sinks[sink.id] else { return }
        if entry.count <= 1 {
            sinks[sink.id] = nil
        } else {
            sinks[sink.id]!.count -= 1
        }
    }

    func addSink(_ sink: any Sink) {
        if sinks[sink.id] != nil {
            sinks[sink.id]!.count += 1
        } else {
            sinks[sink.id] = WeakSink(sink: sink)
        }
    }
}

extension Signal where T: Equatable {
    public convenience init(_ value: T) {
        self.init(value, equals: ==)
    }
}

public final class Computed<T>: Source<T>, Sink {
    public let id = currentId.add(1, ordering: .relaxed).oldValue

    var state: State = .dirty
    var sources: [any Source] = []
    var sinks: [UInt64: WeakSink] = [:]

    let computation: () -> T
    let equals: ((T, T) -> Bool)?

    @exclusivity(unchecked)
    var _value: T?

    public var value: T {
        recomputeIfNeeded()
        currentSink?.trackRead(self)
        return _value!
    }

    public var peek: T {
        recomputeIfNeeded()
        return _value!
    }

    public init(_ computation: @escaping () -> T, equals: ((T, T) -> Bool)? = nil) {
        self.computation = computation
        self.equals = equals
    }

    func recomputeIfNeeded() {
        switch state {
        case .clean: break
        case .dirty:
            state = .clean
            recompute()
        case .maybe:
            state = .clean
            // if deps is all clean then no one notify us then we must be clean
            // Bug: wont work if `source` is .maybe
            if sources.allSatisfy({ $0.state == .clean }) {
                return
            }

            recompute()
        }
    }

    // nil mean reusing fail
    var currentTrackingIndex: Int = 0
    func recompute() {
        currentTrackingIndex = 0
        let prev = currentSink
        currentSink = self
        let newValue = computation()
        currentSink = prev

        // unlink everything after currentTrackingIndex
        for _ in currentTrackingIndex..<sources.count {
            let prev = sources.removeLast()
            prev.removeSink(self)
        }

        if _value == nil || equals == nil || !equals!(newValue, _value!) {
            _value = newValue
            propagate(direct: true)
        }
    }

    func trackRead(_ source: any Source) {
        // dedup
        if currentTrackingIndex > 0, sources[currentTrackingIndex - 1] === source { return }

        // larger than before
        if currentTrackingIndex >= sources.count {
            sources.append(source)
            source.addSink(self)
        } else if sources[currentTrackingIndex] !== source {
            // overwrite
            sources[currentTrackingIndex].removeSink(self)
            sources[currentTrackingIndex] = source
            source.addSink(self)
        }

        self.currentTrackingIndex += 1
    }

    func propagate(direct: Bool) {
        sinks = sinks.filter { $0.value.sink != nil }
        for d in sinks {
            d.value.sink!.notify(direct: direct)
        }
    }

    func notify(direct: Bool) {
        if direct {
            if state == .dirty { return }
            state = .dirty
            if state == .maybe { return }
        } else {
            // if deps really change it will mark this thing dirty
            // if not it will either: no differences or not yet pulled
            if state == .maybe || state == .dirty { return }
            state = .maybe
        }

        propagate(direct: false)
    }

    func removeSink(_ sink: any Sink) {
        guard let entry = sinks[sink.id] else { return }
        if entry.count <= 1 {
            sinks[sink.id] = nil
        } else {
            sinks[sink.id]!.count -= 1
        }
    }

    func addSink(_ sink: any Sink) {
        if sinks[sink.id] != nil {
            sinks[sink.id]!.count += 1
        } else {
            sinks[sink.id] = WeakSink(sink: sink)
        }
    }
}

extension Computed where T: Equatable {
    public convenience init(_ computation: @escaping () -> T) {
        self.init(computation, equals: ==)
    }
}

// TODO: make effect scope own this
public final class Effect: EffectOwner, Sink {
    public let id = currentId.add(1, ordering: .relaxed).oldValue

    var sources: [any Source] = []
    var effect: () -> Void
    var hasPendingRerun = false

    let flush: Flush

    @discardableResult
    public convenience init(
        scheduler: EffectScheduler? = nil,
        isolation: any Actor? = #isolation,
        effect: @escaping () -> Void
    ) {
        if let scheduler = scheduler ?? currentEffectScheduler {
            self.init(flush: .scheduler(scheduler), effect: effect)
        } else if let isolation {
            print("select isolated")
            if isolation !== MainActor.shared {
                MainActor.preconditionIsolated()
                self.init(flush: .scheduler(mainEffectScheduler), effect: effect)
            } else {
                self.init(flush: .isolated(isolation), effect: effect)
            }
        } else {
            fatalError(
                "No `EffectScheduler` are provided and current context is not isolated. You can also use `withEffectScheduler {}` to provide one."
            )
        }
    }

    init(flush: Flush, isolation: any Actor? = #isolation, effect: @escaping () -> Void) {
        self.effect = effect
        self.flush = flush
        super.init(detached: false, isolation: isolation)

        rerun()
    }

    public static func immediate(effect: @escaping () -> Void) -> Effect {
        Effect(flush: .immediate, effect: effect)
    }

    var currentTrackingIndex: Int = 0
    func rerun() {
        currentTrackingIndex = 0

        let prevSink = currentSink
        let prevScope = currentEffectScope
        currentSink = self
        currentEffectScope = self
        effect()
        currentEffectScope = prevScope
        currentSink = prevSink

        hasPendingRerun = false

        for _ in currentTrackingIndex..<sources.count {
            let prev = sources.removeLast()
            prev.removeSink(self)
        }

    }

    func trackRead(_ source: any Source) {
        if currentTrackingIndex > 0, sources[currentTrackingIndex - 1] === source { return }

        // larger than before
        if currentTrackingIndex >= sources.count {
            sources.append(source)
            source.addSink(self)
        } else if sources[currentTrackingIndex] !== source {
            // overwrite
            let prev = sources[currentTrackingIndex]
            prev.removeSink(self)
            sources[currentTrackingIndex] = source
            source.addSink(self)
        }

        self.currentTrackingIndex += 1
    }

    func notify(direct _: Bool) {
        if !hasPendingRerun {
            hasPendingRerun = true
            flush.schedule(self)
        }
    }
}

public class EffectOwner {
    weak var parent: EffectOwner?
    var children: [EffectOwner] = []
    let staticIsolation: any Actor?

    init(
        detached: Bool = false,
        isolation: any Actor?
    ) {
        staticIsolation = isolation
        if let currentEffectScope, !detached {
            currentEffectScope.add(self)
        }
        // implicitly detached when there is no parent
    }

    func add(_ child: EffectOwner) {
        children.append(child)
        child.parent = self
    }

    func remove(child: EffectOwner) {
        children = children.filter { $0 !== child }
        child.parent = nil
    }
}

/// must not be send across isolation domain
public final class EffectScope: EffectOwner {
    var preferredScheduler: EffectScheduler? = nil

    public init(
        detached: Bool = false,
        preferredScheduler: EffectScheduler? = nil,
        isolation: any Actor? = #isolation
    ) {
        self.preferredScheduler = preferredScheduler
        super.init(detached: detached, isolation: isolation)

        // or put this behavior in RootEffectScope
        if let isolation, preferredScheduler == nil, parent == nil {
            // create a default one
            // is this safe tho
            nonisolated(unsafe) let scheduler = EffectScheduler()
            scheduler.onFlushNeeded = { _ in
                Task {
                    await runOnActor(isolation) {
                        scheduler.flush()
                    }
                }
            }
            self.preferredScheduler = scheduler
        }
    }

    public func run<T>(_ block: () -> T) -> T {
        let prev = currentEffectScope
        currentEffectScope = self
        defer { currentEffectScope = prev }

        if let preferredScheduler {
            return withEffectScheduler(preferredScheduler, body: block)
        } else {
            return block()
        }
    }

    /// release children reference
    public func dispose() {
        for c in children {
            c.parent = nil
        }
        children = []
    }

}

func untrack<T>(_ body: () -> T) -> T {
    let prev = currentSink
    currentSink = nil
    defer { currentSink = prev }
    return body()
}

// extension Effect {
//     static func onDispose() {

//     }
// }
