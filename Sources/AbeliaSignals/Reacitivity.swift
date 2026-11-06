protocol Source<T>: AnyObject {
    associatedtype T
    // only use for compute state `.maybe` checking
    var state: State { get }

    func addSink(_ sink: any Sink)
    func removeSink(_ sink: any Sink)
}

protocol Sink: AnyObject {
    func trackRead(_ source: any Source)
    func notify(direct: Bool)
}

struct WeakSink {
    weak var sink: any Sink?
}

enum State {
    case dirty
    case maybe
    case clean
}

public final class Signal<T>: Source<T> {
    var _value: T
    let equals: ((T, T) -> Bool)?
    var sinks: [WeakSink] = []
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

        _modify {
            yield &_value
            propagate()
        }
    }

    public var peek: T { _value }

    public init(_ value: T, equals: ((T, T) -> Bool)?) {
        self._value = value
        self.equals = equals
    }

    func propagate() {
        // ordering shouldnt be guaranteed?
        sinks = sinks.filter { $0.sink != nil }
        for d in sinks {
            d.sink!.notify(direct: true)
        }
    }

    func removeSink(_ sink: any Sink) {
        sinks = sinks.filter { $0.sink != nil && $0.sink !== sink }
    }

    func addSink(_ sink: any Sink) {
        sinks.append(WeakSink(sink: sink))
    }
}

extension Signal where T: Equatable {
    public convenience init(_ value: T) {
        self.init(value, equals: ==)
    }
}

public final class Computed<T>: Source<T>, Sink {
    var state: State = .dirty
    var souces: [any Source] = []
    var sinks: [WeakSink] = []

    let computation: () -> T
    let equals: ((T, T) -> Bool)?

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
            if souces.allSatisfy({ $0.state == .clean }) {
                return
            }

            recompute()
        }
    }

    func recompute() {
        removeSources()

        let prev = currentSink
        currentSink = self
        let newValue = computation()
        currentSink = prev

        if _value == nil || equals == nil || !equals!(newValue, _value!) {
            _value = newValue
            propagate(direct: true)
        }
    }

    func removeSources() {
        // TODO: optimize this
        for d in souces {
            d.removeSink(self)
        }
        souces = []
    }

    func trackRead(_ source: any Source) {
        // should actually overwrite in place
        self.souces.append(source)
        source.addSink(self)
    }

    func propagate(direct: Bool) {
        sinks = sinks.filter { $0.sink != nil }
        for d in sinks {
            d.sink!.notify(direct: direct)
        }
    }

    func notify(direct: Bool) {
        if direct {
            if state == .dirty { return }
            state = .dirty
        } else {
            // if deps really change it will mark this thing dirty
            // if not it will either: no differences or not yet pulled
            if state == .maybe { return }
            state = .maybe
        }

        propagate(direct: false)
    }

    func addSink(_ sink: any Sink) {
        sinks.append(WeakSink(sink: sink))
    }

    func removeSink(_ sink: any Sink) {
        sinks = sinks.filter { $0.sink != nil && $0.sink !== sink }
    }
}

extension Computed where T: Equatable {
    public convenience init(_ computation: @escaping () -> T) {
        self.init(computation, equals: ==)
    }
}

// TODO: make effect scope own this
public final class Effect: EffectOwner, Sink {
    var souces: [any Source] = []
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

    func removeSources() {
        // TODO: optimize this
        for d in souces {
            d.removeSink(self)
        }
        souces = []
    }

    func rerun() {
        removeSources()
        let prevSink = currentSink
        let prevScope = currentEffectScope
        currentSink = self
        currentEffectScope = self
        effect()
        currentEffectScope = prevScope
        currentSink = prevSink

        hasPendingRerun = false
    }

    func trackRead(_ source: any Source) {
        self.souces.append(source)
        source.addSink(self)
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
