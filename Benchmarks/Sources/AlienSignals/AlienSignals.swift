// Port of alien-signals 3.2.1 `esm/index.mjs` (MIT), same algorithm, tuned for Swift.
// Benchmark baseline only, see System.swift.
//
// Differences forced by Swift:
//   - `signal()` / `computed()` return objects with `.value` instead of callable functions
//   - values compare with `!=` (Equatable) where JS uses `!==`
// Not ported: isSignal/isComputed/..., effect cleanups (v3's `fn` may return one),
// computed `getter(previousValue)`.

let HasChildEffect = 64

@exclusivity(unchecked)
nonisolated(unsafe) var cycle = 0

@exclusivity(unchecked)
nonisolated(unsafe) var runDepth = 0

@exclusivity(unchecked)
nonisolated(unsafe) var batchDepth = 0

@exclusivity(unchecked)
nonisolated(unsafe) var notifyIndex = 0

@exclusivity(unchecked)
nonisolated(unsafe) var queuedLength = 0

@usableFromInline
@exclusivity(unchecked)
nonisolated(unsafe) var activeSub: NodePtr? = nil

// each queued effect's object is retained (JS: the array keeps it alive)
@exclusivity(unchecked)
nonisolated(unsafe) var queued: ContiguousArray<NodePtr?> = []

// MARK: the callbacks handed to createReactiveSystem

func update(_ node: NodePtr) -> Bool {
    switch node.pointee.kind {
    case .computed:
        return updateComputed(node)
    case .signal:
        return updateSignal(node)
    default:
        node.pointee.flags = 1
        return true
    }
}

func notify(_ start: NodePtr) {
    var effect: NodePtr? = start
    var insertIndex = queuedLength
    var firstInsertedIndex = insertIndex
    repeat {
        let e = effect!
        _ = e.pointee.object.retain()
        if insertIndex == queued.count {
            queued.append(e)
        } else {
            queued[insertIndex] = e
        }
        insertIndex += 1
        e.pointee.flags &= ~2
        // JS: effect.subs?.sub, the first subscriber
        effect = e.pointee.sinkCount > 0 ? e.pointee.sinks[0].sub : nil
        if effect == nil || effect!.pointee.flags & 2 == 0 {
            break
        }
    } while true
    queuedLength = insertIndex
    insertIndex -= 1
    while firstInsertedIndex < insertIndex {
        queued.swapAt(firstInsertedIndex, insertIndex)
        firstInsertedIndex += 1
        insertIndex -= 1
    }
}

func unwatched(_ node: NodePtr) {
    switch node.pointee.kind {
    case .computed:
        if node.pointee.depsTail != nil {
            node.pointee.flags = 1 | 16
            disposeAllDepsInReverse(node)
        }
    case .signal:
        break
    case .effect:
        effectOper(node)
    case .scope, .trigger:
        effectScopeOper(node)
    }
}

// MARK: exports

@discardableResult
func setActiveSub(_ sub: NodePtr?) -> NodePtr? {
    let prevSub = activeSub
    activeSub = sub
    return prevSub
}

public func getBatchDepth() -> Int {
    batchDepth
}

public func startBatch() {
    batchDepth += 1
}

public func endBatch() {
    batchDepth -= 1
    if batchDepth == 0 {
        flush()
    }
}

public final class Signal<T: Equatable>: ReactiveNode {
    @usableFromInline
    @exclusivity(unchecked)
    var currentValue: T

    @usableFromInline
    @exclusivity(unchecked)
    var pendingValue: T

    @inlinable
    public init(_ initialValue: T) {
        currentValue = initialValue
        pendingValue = initialValue
        super.init(kind: .signal, flags: 1) { node in
            // updateSignal: currentValue !== (currentValue = pendingValue)
            let s = unsafeDowncast(node, to: Signal<T>.self)
            let changed = s.currentValue != s.pendingValue
            s.currentValue = s.pendingValue
            return changed
        }
    }

    // signalOper
    @inlinable
    public var value: T {
        get {
            if node.pointee.flags & 16 != 0 || activeSub != nil {
                signalRead(node)
            }
            return currentValue
        }
        set {
            if pendingValue != newValue {
                pendingValue = newValue
                signalWrite(node)
            }
        }
    }

    // not in alien-signals: same work as AbeliaSignals' `peek`, plus committing a pending write
    @inlinable
    public var peek: T {
        if node.pointee.flags & 16 != 0 {
            signalCommit(node)
        }
        return currentValue
    }
}

public final class Computed<T: Equatable>: ReactiveNode {
    @usableFromInline
    @exclusivity(unchecked)
    var _value: T? = nil

    @usableFromInline
    let getter: () -> T

    @inlinable
    public init(_ getter: @escaping () -> T) {
        self.getter = getter
        super.init(kind: .computed, flags: 0) { node in
            // oldValue !== (c.value = c.getter(oldValue))
            let c = unsafeDowncast(node, to: Computed<T>.self)
            let oldValue = c._value
            let newValue = c.getter()
            c._value = newValue
            return oldValue != newValue
        }
    }

    // computedOper
    @inlinable
    public var value: T {
        computedOper(node)
        return _value!
    }

    // not in alien-signals: an untracked read, for the shared suite
    @inlinable
    public var peek: T {
        let prevSub = activeSub
        activeSub = nil
        computedOper(node)
        activeSub = prevSub
        return _value!
    }
}

public final class Effect: ReactiveNode {
    let fn: () -> Void

    init(_ fn: @escaping () -> Void) {
        self.fn = fn
        super.init(kind: .effect, flags: 2 | 4) { _ in false }
    }

    // calling the returned function in JS
    public func dispose() {
        effectOper(node)
    }

    // same spelling as AbeliaSignals, so the benchmark suite compiles against both
    public static func immediate(effect fn: @escaping () -> Void) -> Effect {
        effect(fn)
    }
}

public final class EffectScope: ReactiveNode {
    init() {
        super.init(kind: .scope, flags: 1) { _ in false }
    }

    // calling the returned function in JS
    public func dispose() {
        effectScopeOper(node)
    }
}

final class TriggerNode: ReactiveNode {
    init() {
        super.init(kind: .trigger, flags: 2) { _ in false }
    }
}

@discardableResult
public func effect(_ fn: @escaping () -> Void) -> Effect {
    let e = Effect(fn)
    let prevSub = setActiveSub(e.node)
    if let prevSub {
        link(e.node, prevSub, 0)
        prevSub.pointee.flags |= HasChildEffect
    }
    runDepth += 1
    e.fn()
    runDepth -= 1
    activeSub = prevSub
    e.node.pointee.flags &= ~4
    return e
}

@discardableResult
public func effectScope(_ fn: () -> Void) -> EffectScope {
    let e = EffectScope()
    let prevSub = setActiveSub(e.node)
    if let prevSub {
        link(e.node, prevSub, 0)
        prevSub.pointee.flags |= HasChildEffect
    }
    fn()
    activeSub = prevSub
    return e
}

public func trigger(_ fn: () -> Void) {
    let trigger = TriggerNode()
    withExtendedLifetime(trigger) {
        let sub = trigger.node
        let prevSub = setActiveSub(sub)
        fn()
        activeSub = prevSub
        sub.pointee.flags = 0
        var link = sub.pointee.deps
        while let l = link {
            // JS keeps `dep` alive through the GC; the link may hold the last reference
            let dep = l.pointee.dep
            let object = dep.pointee.object.retain()
            link = unlink(l, sub)
            if dep.pointee.sinkCount > 0 {
                propagate(dep, runDepth != 0)
                shallowPropagate(dep)
            }
            object.release()
        }
        if batchDepth == 0 {
            flush()
        }
    }
}

// MARK: internals

func updateComputed(_ c: NodePtr) -> Bool {
    if c.pointee.flags & HasChildEffect != 0 {
        unlinkChildEffects(c)
    }
    c.pointee.depsTail = nil
    c.pointee.flags = 1 | 4
    let prevSub = setActiveSub(c)
    cycle += 1
    let changed = c.pointee.object._withUnsafeGuaranteedRef { $0.apply($0) }
    activeSub = prevSub
    c.pointee.flags &= ~4
    purgeDeps(c)
    return changed
}

func updateSignal(_ s: NodePtr) -> Bool {
    s.pointee.flags = 1
    return s.pointee.object._withUnsafeGuaranteedRef { $0.apply($0) }
}

func run(_ e: NodePtr) {
    let flags = e.pointee.flags
    if flags & 16 != 0 || (flags & 32 != 0 && checkDirty(e.pointee.deps!, e)) {
        if flags & HasChildEffect != 0 {
            unlinkChildEffects(e)
        }
        e.pointee.depsTail = nil
        e.pointee.flags = 2 | 4
        let prevSub = setActiveSub(e)
        cycle += 1
        runDepth += 1
        e.pointee.object._withUnsafeGuaranteedRef { unsafeDowncast($0, to: Effect.self).fn() }
        runDepth -= 1
        activeSub = prevSub
        e.pointee.flags &= ~4
        purgeDeps(e)
    } else if e.pointee.deps != nil {
        e.pointee.flags = 2 | (flags & HasChildEffect)
    }
}

// the HasChildEffect loop shared by updateComputed and run
private func unlinkChildEffects(_ sub: NodePtr) {
    var link = sub.pointee.depsTail
    while let l = link {
        let prev = l.pointee.prevDep
        let kind = l.pointee.dep.pointee.kind
        if kind != .computed && kind != .signal {
            unlink(l, sub)
        }
        link = prev
    }
}

func flush() {
    while notifyIndex < queuedLength {
        let effect = queued[notifyIndex]!
        queued[notifyIndex] = nil
        notifyIndex += 1
        run(effect)
        effect.pointee.object.release()
    }
    // JS's `finally` re-queues effects left behind by a throw; nothing here throws
    notifyIndex = 0
    queuedLength = 0
}

@usableFromInline
func computedOper(_ c: NodePtr) {
    let flags = c.pointee.flags
    var shouldUpdate = flags & 16 != 0
    if !shouldUpdate && flags & 32 != 0 {
        if checkDirty(c.pointee.deps!, c) {
            shouldUpdate = true
        } else {
            c.pointee.flags = flags & ~32
        }
    }
    if shouldUpdate {
        if updateComputed(c) {
            if c.pointee.sinkCount > 0 {
                shallowPropagate(c)
            }
        }
    } else if flags == 0 {
        c.pointee.flags = 1 | 4
        let prevSub = setActiveSub(c)
        _ = c.pointee.object._withUnsafeGuaranteedRef { $0.apply($0) }
        activeSub = prevSub
        c.pointee.flags &= ~4
    }
    if let sub = activeSub {
        link(c, sub, cycle)
    }
}

@usableFromInline
func signalRead(_ s: NodePtr) {
    if s.pointee.flags & 16 != 0 {
        signalCommit(s)
    }
    if let sub = activeSub {
        link(s, sub, cycle)
    }
}

@usableFromInline
func signalCommit(_ s: NodePtr) {
    if updateSignal(s) {
        if s.pointee.sinkCount > 0 {
            shallowPropagate(s)
        }
    }
}

@usableFromInline
func signalWrite(_ s: NodePtr) {
    s.pointee.flags = 1 | 16
    if s.pointee.sinkCount > 0 {
        propagate(s, runDepth != 0)
        if batchDepth == 0 {
            flush()
        }
    }
}

func effectOper(_ e: NodePtr) {
    effectScopeOper(e)
}

func effectScopeOper(_ e: NodePtr) {
    e.pointee.flags = 0
    disposeAllDepsInReverse(e)
    if e.pointee.sinkCount > 0 {
        unlink(sink(e, 0))
    }
}

func disposeAllDepsInReverse(_ sub: NodePtr) {
    var link = sub.pointee.depsTail
    while let l = link {
        let prev = l.pointee.prevDep
        unlink(l, sub)
        link = prev
    }
}

func purgeDeps(_ sub: NodePtr) {
    let depsTail = sub.pointee.depsTail
    var dep = depsTail != nil ? depsTail!.pointee.nextDep : sub.pointee.deps
    while let d = dep {
        dep = unlink(d, sub)
    }
}
