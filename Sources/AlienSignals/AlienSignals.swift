// Line-by-line port of alien-signals 3.2.1 `esm/index.mjs` (MIT).
// Benchmark baseline only, see System.swift.
//
// Differences forced by Swift:
//   - `signal()` / `computed()` return objects with `.value` instead of callable functions
//   - `'getter' in node` dispatch is class overrides of `update()` / `unwatched()`
//   - values compare with `!=` (Equatable) where JS uses `!==`
// Not ported: isSignal/isComputed/..., effect cleanups (v3's `fn` may return one),
// computed `getter(previousValue)`.

let HasChildEffect = 64

nonisolated(unsafe) var cycle = 0
nonisolated(unsafe) var runDepth = 0
nonisolated(unsafe) var batchDepth = 0
nonisolated(unsafe) var notifyIndex = 0
nonisolated(unsafe) var queuedLength = 0
nonisolated(unsafe) var activeSub: ReactiveNode?
nonisolated(unsafe) var queued: [ReactiveNode?] = []

func notify(_ start: ReactiveNode) {
    var effect: ReactiveNode? = start
    var insertIndex = queuedLength
    var firstInsertedIndex = insertIndex
    repeat {
        if insertIndex == queued.count {
            queued.append(effect)
        } else {
            queued[insertIndex] = effect
        }
        insertIndex += 1
        effect!.flags &= ~2
        effect = effect!.subs?.sub
        if effect == nil || effect!.flags & 2 == 0 {
            break
        }
    } while true
    queuedLength = insertIndex
    insertIndex -= 1
    while firstInsertedIndex < insertIndex {
        let left = queued[firstInsertedIndex]
        queued[firstInsertedIndex] = queued[insertIndex]
        firstInsertedIndex += 1
        queued[insertIndex] = left
        insertIndex -= 1
    }
}

public func getActiveSub() -> ReactiveNode? {
    activeSub
}

@discardableResult
public func setActiveSub(_ sub: ReactiveNode?) -> ReactiveNode? {
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
    var currentValue: T
    var pendingValue: T

    public init(_ initialValue: T) {
        currentValue = initialValue
        pendingValue = initialValue
        super.init(flags: 1)
    }

    override func update() -> Bool {
        updateSignal(self)
    }

    // signalOper
    public var value: T {
        get {
            if flags & 16 != 0 {
                if updateSignal(self) {
                    let subs = self.subs
                    if subs != nil {
                        shallowPropagate(subs!)
                    }
                }
            }
            let sub = activeSub
            if sub != nil {
                link(self, sub!, cycle)
            }
            return currentValue
        }
        set {
            if pendingValue != newValue {
                pendingValue = newValue
                flags = 1 | 16
                let subs = self.subs
                if subs != nil {
                    propagate(subs!, runDepth != 0)
                    if batchDepth == 0 {
                        flush()
                    }
                }
            }
        }
    }

    // not in alien-signals: same work as AbeliaSignals' `peek`, plus committing a pending write
    public var peek: T {
        if flags & 16 != 0 {
            if updateSignal(self) {
                let subs = self.subs
                if subs != nil {
                    shallowPropagate(subs!)
                }
            }
        }
        return currentValue
    }
}

public final class Computed<T: Equatable>: ReactiveNode {
    var _value: T?
    let getter: () -> T

    public init(_ getter: @escaping () -> T) {
        self.getter = getter
        super.init(flags: 0)
    }

    override func update() -> Bool {
        updateComputed(self)
    }

    override func unwatched() {
        if depsTail != nil {
            flags = 1 | 16
            disposeAllDepsInReverse(self)
        }
    }

    // computedOper
    public var value: T {
        let flags = self.flags
        if flags & 16 != 0
            || (flags & 32 != 0
                && (checkDirty(deps!, self)
                    || { self.flags = flags & ~32; return false }()))
        {
            if updateComputed(self) {
                let subs = self.subs
                if subs != nil {
                    shallowPropagate(subs!)
                }
            }
        } else if flags == 0 {
            self.flags = 1 | 4
            let prevSub = setActiveSub(self)
            _value = getter()
            activeSub = prevSub
            self.flags &= ~4
        }
        let sub = activeSub
        if sub != nil {
            link(self, sub!, cycle)
        }
        return _value!
    }

    // not in alien-signals: an untracked read, for the shared suite
    public var peek: T {
        let prevSub = setActiveSub(nil)
        defer { activeSub = prevSub }
        return value
    }
}

public final class Effect: ReactiveNode {
    let fn: () -> Void

    init(_ fn: @escaping () -> Void) {
        self.fn = fn
        super.init(flags: 2 | 4)
    }

    override func unwatched() {
        effectOper(self)
    }

    // calling the returned function in JS
    public func dispose() {
        effectOper(self)
    }

    // same spelling as AbeliaSignals, so the benchmark suite compiles against both
    public static func immediate(effect fn: @escaping () -> Void) -> Effect {
        effect(fn)
    }
}

public final class EffectScope: ReactiveNode {
    init() {
        super.init(flags: 1)
    }

    override func unwatched() {
        effectScopeOper(self)
    }

    // calling the returned function in JS
    public func dispose() {
        effectScopeOper(self)
    }
}

@discardableResult
public func effect(_ fn: @escaping () -> Void) -> Effect {
    let e = Effect(fn)
    let prevSub = setActiveSub(e)
    if prevSub != nil {
        link(e, prevSub!, 0)
        prevSub!.flags |= HasChildEffect
    }
    runDepth += 1
    e.fn()
    runDepth -= 1
    activeSub = prevSub
    e.flags &= ~4
    return e
}

@discardableResult
public func effectScope(_ fn: () -> Void) -> EffectScope {
    let e = EffectScope()
    let prevSub = setActiveSub(e)
    if prevSub != nil {
        link(e, prevSub!, 0)
        prevSub!.flags |= HasChildEffect
    }
    fn()
    activeSub = prevSub
    return e
}

public func trigger(_ fn: () -> Void) {
    let sub = ReactiveNode(flags: 2)
    let prevSub = setActiveSub(sub)
    fn()
    activeSub = prevSub
    sub.flags = 0
    var link = sub.deps
    while link != nil {
        let dep = link!.dep
        link = unlink(link!, sub)
        let subs = dep.subs
        if subs != nil {
            propagate(subs!, runDepth != 0)
            shallowPropagate(subs!)
        }
    }
    if batchDepth == 0 {
        flush()
    }
}

func updateComputed<T>(_ c: Computed<T>) -> Bool {
    if c.flags & HasChildEffect != 0 {
        var link = c.depsTail
        while link != nil {
            let prev = link!.prevDep
            let dep = link!.dep
            if dep is Effect || dep is EffectScope {
                unlink(link!, c)
            }
            link = prev
        }
    }
    c.depsTail = nil
    c.flags = 1 | 4
    let prevSub = setActiveSub(c)
    cycle += 1
    let oldValue = c._value
    c._value = c.getter()
    let changed = oldValue != c._value
    activeSub = prevSub
    c.flags &= ~4
    purgeDeps(c)
    return changed
}

func updateSignal<T>(_ s: Signal<T>) -> Bool {
    s.flags = 1
    let changed = s.currentValue != s.pendingValue
    s.currentValue = s.pendingValue
    return changed
}

func run(_ e: Effect) {
    let flags = e.flags
    if flags & 16 != 0
        || (flags & 32 != 0
            && checkDirty(e.deps!, e))
    {
        if flags & HasChildEffect != 0 {
            var link = e.depsTail
            while link != nil {
                let prev = link!.prevDep
                let dep = link!.dep
                if dep is Effect || dep is EffectScope {
                    unlink(link!, e)
                }
                link = prev
            }
        }
        e.depsTail = nil
        e.flags = 2 | 4
        let prevSub = setActiveSub(e)
        cycle += 1
        runDepth += 1
        e.fn()
        runDepth -= 1
        activeSub = prevSub
        e.flags &= ~4
        purgeDeps(e)
    } else if e.deps != nil {
        e.flags = 2 | (flags & HasChildEffect)
    }
}

func flush() {
    while notifyIndex < queuedLength {
        let effect = queued[notifyIndex]!
        queued[notifyIndex] = nil
        notifyIndex += 1
        run(effect as! Effect)
    }
    // JS's `finally` re-queues effects left behind by a throw; nothing here throws
    notifyIndex = 0
    queuedLength = 0
}

func effectOper(_ e: ReactiveNode) {
    effectScopeOper(e)
}

func effectScopeOper(_ e: ReactiveNode) {
    e.flags = 0
    disposeAllDepsInReverse(e)
    let sub = e.subs
    if sub != nil {
        unlink(sub!)
    }
}

func disposeAllDepsInReverse(_ sub: ReactiveNode) {
    var link = sub.depsTail
    while link != nil {
        let prev = link!.prevDep
        unlink(link!, sub)
        link = prev
    }
}

func purgeDeps(_ sub: ReactiveNode) {
    let depsTail = sub.depsTail
    var dep = depsTail != nil ? depsTail!.nextDep : sub.deps
    while dep != nil {
        dep = unlink(dep!, sub)
    }
}
