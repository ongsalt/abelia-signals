// Port of alien-signals' index.ts (MIT, see LICENSE), with
// effects flushed by Runtime instead of synchronously.

public protocol Source<Value>: AnyObject {
    associatedtype Value
    var value: Value { get }
}

public final class Signal<Value>: ReactiveNode, Source {
    @usableFromInline var stored: Value
    @usableFromInline let isEqual: (Value, Value) -> Bool

    public init(_ value: Value, equals isEqual: @escaping (Value, Value) -> Bool) {
        stored = value
        self.isEqual = isEqual
        super.init(flags: .mutable)
    }

    // without Equatable every write notifies
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
    public convenience init(_ value: Value) {
        self.init(value, equals: ==)
    }
}

// Lazy and cached. With no subscribers left it unlinks from its sources and
// recomputes on the next read.
public final class Computed<Value>: ReactiveNode, Source {
    private let compute: () -> Value
    private let isEqual: (Value, Value) -> Bool
    @usableFromInline var cached: Value?

    public init(equals isEqual: @escaping (Value, Value) -> Bool, _ compute: @escaping () -> Value) {
        self.compute = compute
        self.isEqual = isEqual
        super.init(flags: [])
    }

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

    override func update() -> Bool {
        if flags.contains(.hasChildEffect) { disposeChildEffects(self) }
        depsTail = nil
        flags = [.mutable, .recursedCheck]
        let prevSub = activeSub
        activeSub = self
        nextCycle()
        let old = cached
        let new = compute()
        cached = new
        activeSub = prevSub
        flags.remove(.recursedCheck)
        purgeDeps(self)
        guard let old else { return true }
        return !isEqual(old, new)
    }

    override func unwatched() {
        guard depsTail != nil else { return }
        flags = [.mutable, .dirty]
        disposeAllDepsInReverse(self)
    }
}

extension ReactiveNode {
    @usableFromInline func signalRead() {
        if flags.contains(.dirty) {
            flags = .mutable
            if let subs = subsRef { shallowPropagate(subs) }
        }
        if let sub = activeSubRef { link(self, sub, cycle) }
    }

    @usableFromInline func signalWritten() {
        flags = [.mutable, .dirty]
        if let subs = subsRef { propagate(subs, innerWrite: runDepth != 0) }
    }

    @usableFromInline func computedRead(tracked: Bool) {
        let flags = self.flags
        if flags.isEmpty || !flags.isDisjoint(with: [.dirty, .pending]) {
            var dirty = flags.isEmpty || flags.contains(.dirty)
            if !dirty {
                dirty = checkDirty(depsRef!, self)
                if !dirty { self.flags.remove(.pending) }
            }
            if dirty, update(), let subs = subsRef { shallowPropagate(subs) }
        }
        if tracked, let sub = activeSubRef { link(self, sub, cycle) }
    }
}

extension Computed where Value: Equatable {
    public convenience init(_ compute: @escaping () -> Value) {
        self.init(equals: ==, compute)
    }
}

// Owned by the effect, computed or scope it was created in, or by the runtime
// outside any of them. Dropping the handle doesn't stop it.
public final class Effect: ReactiveNode {
    // weak: the runtime owns root effects. once it's gone this never re-runs
    weak var runtime: Runtime?
    private let body: () -> Void
    var cleanups: [() -> Void] = []

    init(runtime: Runtime, body: @escaping () -> Void) {
        self.runtime = runtime
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
        if flags.contains(.dirty) || (flags.contains(.pending) && checkDirty(depsRef!, self)) {
            if flags.contains(.hasChildEffect) { disposeChildEffects(self) }
            if !cleanups.isEmpty {
                runCleanups(&cleanups)
                if self.flags.isEmpty { return }
            }
            depsTail = nil
            self.flags = [.watching, .recursedCheck]
            let prevSub = activeSub
            activeSub = self
            nextCycle()
            runDepth += 1
            body()
            runDepth -= 1
            activeSub = prevSub
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

extension RuntimeOwner {
    // `effect` for actor state. A body capturing `self` would keep the actor
    // alive through its own runtime, and `[weak self]` loses the isolation, so
    // this holds the actor weakly and passes it in isolated.
    @discardableResult
    public func effect(_ body: @escaping (isolated Self) -> Void) -> Effect {
        // only ever called on self, which assumeIsolated checks
        let body = TrustMe(value: body)
        return AbeliaSignals.effect { [weak self] in
            self?.assumeIsolated { body.value($0) }
        }
    }
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
    // weak: the runtime owns rootScope
    weak var runtime: Runtime?
    var cleanups: [() -> Void] = []

    // a non-detached scope is owned and stopped by the effect or scope active when it's created
    public convenience init(detached: Bool = false, isolation: isolated (any Actor)? = #isolation) {
        let parent = activeSub
        let runtime =
            (parent as? Effect)?.runtime ?? (parent as? EffectScope)?.runtime
            ?? Runtime.current(isolation: isolation)
        self.init(runtime: runtime, detached: detached)
    }

    init(runtime: Runtime, detached: Bool) {
        self.runtime = runtime
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
