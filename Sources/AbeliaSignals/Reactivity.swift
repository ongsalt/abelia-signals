// Port of alien-signals' index.ts (MIT, see LICENSE), with
// effects flushed by Runtime instead of synchronously.

public protocol Source<Value>: AnyObject {
    associatedtype Value
    var value: Value { get }
}

public final class Signal<Value>: ReactiveNode, Source {
    @exclusivity(unchecked) @usableFromInline var stored: Value
    @usableFromInline let isEqual: (Value, Value) -> Bool

    @inlinable
    public init(_ value: Value, equals isEqual: @escaping (Value, Value) -> Bool) {
        stored = value
        self.isEqual = isEqual
        super.init(flags: .mutable)
    }

    // without Equatable every write notifies
    @inlinable
    public convenience init(_ value: Value) {
        self.init(value, equals: { _, _ in false })
    }

    // inlinable so clients specialize on Value; the graph work is behind
    // non-generic calls
    @inlinable public var value: Value {
        get {
            signalRead()
            return stored
        }
        set {
            if isEqual(stored, newValue) { return }
            stored = newValue
            signalWritten()
        }
        // always notifies: comparing would need a copy of the old value
        _modify {
            yield &stored
            signalWritten()
        }
    }

    @inlinable public var peek: Value { stored }

    override func update() -> Bool {
        flags = .mutable
        return true
    }
}

extension Signal where Value: Equatable {
    @inlinable
    public convenience init(_ value: Value) {
        self.init(value, equals: ==)
    }
}

// The non-generic half of Computed. `recompute` is built by Computed's
// inlinable init, so it's specialized for the client's Value; a generic
// update() here would run unspecialized.
public class ComputedNode: ReactiveNode {
    // stores the new value, returns whether it changed
    @usableFromInline let recompute: (ComputedNode) -> Bool

    @usableFromInline init(recompute: @escaping (ComputedNode) -> Bool) {
        self.recompute = recompute
        super.init(flags: [])
    }

    final override func update() -> Bool {
        if flags.contains(.hasChildEffect) { disposeChildEffects(self) }
        depsTail = nil
        flags = [.mutable, .recursedCheck]
        let prevSub = swapActiveSub(self)
        nextCycle()
        let changed = recompute(self)
        restoreActiveSub(prevSub)
        flags.remove(.recursedCheck)
        purgeDeps(self)
        return changed
    }

    final override func unwatched() {
        guard depsTail != nil else { return }
        flags = [.mutable, .dirty]
        disposeAllDepsInReverse(self)
    }
}

// Lazy and cached. With no subscribers left it unlinks from its sources and
// recomputes on the next read.
public final class Computed<Value>: ComputedNode, Source {
    @exclusivity(unchecked) @usableFromInline var cached: Value?
    @usableFromInline let compute: () -> Value
    @usableFromInline let isEqual: (Value, Value) -> Bool

    // `recompute` captures nothing, so specialized it needs no context allocation
    @inlinable
    public init(equals isEqual: @escaping (Value, Value) -> Bool, _ compute: @escaping () -> Value) {
        self.compute = compute
        self.isEqual = isEqual
        super.init(recompute: { node in
            let computed = unsafeDowncast(node, to: Computed<Value>.self)
            let old = computed.cached
            let new = computed.compute()
            computed.cached = new
            guard let old else { return true }
            return !computed.isEqual(old, new)
        })
    }

    @inlinable
    public convenience init(_ compute: @escaping () -> Value) {
        self.init(equals: { _, _ in false }, compute)
    }

    @inlinable public var value: Value {
        computedRead(tracked: true)
        return cached!
    }

    @inlinable public var peek: Value {
        computedRead(tracked: false)
        return cached!
    }

}

extension ReactiveNode {
    @usableFromInline func signalRead() {
        if flags.contains(.dirty) {
            flags = .mutable
            if let subs { shallowPropagate(subs) }
        }
        if let sub = activeSubRef { link(self, sub, cycle) }
    }

    @usableFromInline func signalWritten() {
        flags = [.mutable, .dirty]
        if let subs { propagate(subs, innerWrite: runDepth != 0) }
    }

    @usableFromInline func computedRead(tracked: Bool) {
        let flags = self.flags
        if flags.isEmpty || !flags.isDisjoint(with: [.dirty, .pending]) {
            var dirty = flags.isEmpty || flags.contains(.dirty)
            if !dirty {
                dirty = checkDirty(deps!, self)
                if !dirty { self.flags.remove(.pending) }
            }
            if dirty, update(), let subs { shallowPropagate(subs) }
        }
        if tracked, let sub = activeSubRef { link(self, sub, cycle) }
    }
}

extension Computed where Value: Equatable {
    @inlinable
    public convenience init(_ compute: @escaping () -> Value) {
        self.init(equals: ==, compute)
    }
}

// Owned by the effect, computed or scope it was created in, or by the runtime
// outside any of them. Dropping the handle doesn't stop it.
public final class Effect: ReactiveNode {
    // not the runtime: it owns root effects. once it's gone this never re-runs
    let runtimeHandle: RuntimeHandle
    var runtime: Runtime? { runtimeHandle.runtime?.takeUnretainedValue() }
    private let body: () -> Void
    @exclusivity(unchecked) var cleanups: [() -> Void] = []

    init(runtime: Runtime, body: @escaping () -> Void) {
        runtimeHandle = runtime.handle
        self.body = body
        super.init(flags: [.watching, .recursedCheck])
    }

    public var isStopped: Bool { flags.isEmpty }

    public func stop() {
        disposeNode(self)
        runCleanups(&cleanups)
    }

    func run() {
        let flags = self.flags
        if flags.contains(.dirty) || (flags.contains(.pending) && checkDirty(deps!, self)) {
            if flags.contains(.hasChildEffect) { disposeChildEffects(self) }
            if !cleanups.isEmpty {
                runCleanups(&cleanups)
                if self.flags.isEmpty { return }
            }
            depsTail = nil
            self.flags = [.watching, .recursedCheck]
            let prevSub = swapActiveSub(self)
            nextCycle()
            runDepth += 1
            body()
            runDepth -= 1
            restoreActiveSub(prevSub)
            self.flags.remove(.recursedCheck)
            purgeDeps(self)
        } else if deps != nil {
            self.flags = flags.intersection(.hasChildEffect).union(.watching)
        }
    }

    override func unwatched() { stop() }
}

// Runs `body` now, then again in the next flush after anything it read changes.
// Effects created inside `body` are stopped before each re-run.
@discardableResult
public func effect(
    isolation: isolated (any Actor)? = #isolation, _ body: @escaping () -> Void
) -> Effect {
    let parent = activeSub
    let runtime =
        (parent as? Effect)?.runtime ?? (parent as? EffectScope)?.runtime
        ?? Runtime.current(isolation: isolation)
    let effect = Effect(runtime: runtime, body: body)
    let owner = parent ?? runtime.rootScope
    link(effect, .passUnretained(owner), 0)
    owner.flags.insert(.hasChildEffect)

    activeSub = effect
    runDepth += 1
    body()
    runDepth -= 1
    activeSub = parent
    effect.flags.remove(.recursedCheck)
    return effect
}

// Inside an effect: runs before its next run and when it stops.
// Inside `EffectScope.run`: runs when the scope stops.
public func onCleanup(_ cleanup: @escaping () -> Void) {
    switch activeSub {
    case let effect as Effect: effect.cleanups.append(cleanup)
    case let scope as EffectScope: scope.cleanups.append(cleanup)
    default: print("onCleanup called outside an effect or scope. it will never run")
    }
}

// read signals inside `body` without subscribing to them
public func untrack<R>(_ body: () throws -> R) rethrows -> R {
    let prevSub = activeSub
    activeSub = nil
    defer { activeSub = prevSub }
    return try body()
}

// Like Vue's effectScope. Stops when deinitialized.
public final class EffectScope: ReactiveNode {
    // not the runtime: it owns rootScope
    let runtimeHandle: RuntimeHandle
    var runtime: Runtime? { runtimeHandle.runtime?.takeUnretainedValue() }
    @exclusivity(unchecked) var cleanups: [() -> Void] = []

    // a non-detached scope is owned and stopped by the effect or scope active when it's created
    public convenience init(detached: Bool = false, isolation: isolated (any Actor)? = #isolation) {
        let parent = activeSub
        let runtime =
            (parent as? Effect)?.runtime ?? (parent as? EffectScope)?.runtime
            ?? Runtime.current(isolation: isolation)
        self.init(runtime: runtime, detached: detached)
    }

    init(runtime: Runtime, detached: Bool) {
        runtimeHandle = runtime.handle
        super.init(flags: .mutable)
        if !detached, let parent = activeSub {
            link(self, .passUnretained(parent), 0)
            parent.flags.insert(.hasChildEffect)
        }
    }

    deinit { stop() }

    public var isStopped: Bool { flags.isEmpty }

    @discardableResult
    public func run<R>(_ body: () throws -> R) rethrows -> R {
        precondition(!isStopped, "EffectScope.run on a stopped scope")
        let prevSub = activeSub
        activeSub = self
        defer { activeSub = prevSub }
        return try body()
    }

    public func stop() {
        disposeNode(self)
        runCleanups(&cleanups)
    }

    override func update() -> Bool {
        flags = .mutable
        return true
    }

    override func unwatched() { stop() }
}

private func disposeNode(_ node: ReactiveNode) {
    node.flags = []
    disposeAllDepsInReverse(node)
    if let sub = node.subs { unlink(sub, sub.sub) }
}

private func runCleanups(_ cleanups: inout [() -> Void]) {
    if cleanups.isEmpty { return }
    let pending = cleanups
    cleanups.removeAll()
    untrack {
        for cleanup in pending.reversed() { cleanup() }
    }
}
