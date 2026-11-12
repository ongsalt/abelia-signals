class Runtime {
    // TODO: arena with topological sorting
}

@usableFromInline
struct Node {
    // for computed/effect
    @usableFromInline
    var state: State = .dirty

    // behavior:
    //  - if self is .maybe, force deps recheck (effect)
    //  - `update` callback for dirty computed, effect
    //  - effect owner is outside of the graph
    //      - default effect is just a node with eager update flag
    //      - immediate effect batching is also outside the graph

    // or array + swap remove. also store back index, iterate a lot
    // or make a `DenseSlotMap`
    // [sink: `sources` duplicate count]
    @usableFromInline
    var sinks: [NodeRef: Int] = [:]  // this still cause refcount
    // in read order, reused by position across reruns (see `trackRead`)
    @usableFromInline
    var sources: [NodeRef] = []  // this also cause refcount

    @usableFromInline
    var trackingIndex: Int = 0

    // Node address is NOT stable, but no handle are needed cuz we have back pointer to report this to wrapper
    @usableFromInline
    var owner: Unmanaged<NodeWrapper>

    @usableFromInline
    let update: (NodeWrapper) -> Bool

    // `owner.becameDirty` is only called for effects
    @usableFromInline
    let isEffect: Bool

    @inlinable
    init(owner: Unmanaged<NodeWrapper>, isEffect: Bool, update: @escaping (NodeWrapper) -> Bool) {
        self.owner = owner
        self.isEffect = isEffect
        self.update = update
    }
}

// sink (and user) own source, effect owner own effect

@usableFromInline
typealias NodeRef = UnsafeMutablePointer<Node>

extension NodeRef {
    @inlinable
    func trackRead(_ source: NodeRef) {
        let i = pointee.trackingIndex

        // dedup: same as the previous read, already linked
        if i > 0, pointee.sources[i - 1] == source { return }

        if i == pointee.sources.count {
            // larger than before
            pointee.sources.append(source)
            source.addSink(self)
        } else if pointee.sources[i] != source {
            // overwrite
            pointee.sources[i].removeSink(self)
            pointee.sources[i] = source
            source.addSink(self)
        }

        pointee.trackingIndex = i + 1
    }

    @inlinable
    func withTracking<R>(_ body: () -> R) -> R {
        let prev = currentSinkNode
        currentSinkNode = self
        defer { currentSinkNode = prev }

        pointee.trackingIndex = 0
        let result = body()

        let keep = pointee.trackingIndex
        while pointee.sources.count > keep {
            pointee.sources.removeLast().removeSink(self)
        }
        return result
    }

    @inlinable
    func addSink(_ sink: NodeRef) {
        // retain
        if pointee.sinks.isEmpty {
            _ = pointee.owner.retain()
        }

        pointee.sinks[sink, default: 0] += 1
    }

    @inlinable
    func removeSink(_ sink: NodeRef) {
        guard let count = pointee.sinks[sink] else { return }
        if count > 1 {
            pointee.sinks[sink] = count - 1
            return
        }

        pointee.sinks[sink] = nil
        if pointee.sinks.isEmpty {
            pointee.owner.release()
        }
    }

    // should not be recursive
    @inlinable
    func propagate() {
        var next: [NodeRef] = []

        for sink in pointee.sinks.keys where sink.markDirty(direct: true) {
            for s in sink.pointee.sinks.keys { next.append(s) }
        }

        while let top = next.popLast() {
            if top.markDirty(direct: false) {
                for s in top.pointee.sinks.keys { next.append(s) }
            }
        }
    }

    // mark one sink of a changed node: `.dirty` if it reads the changed node directly,
    // `.maybe` otherwise. returns whether its own sinks still need marking
    @inlinable
    func markDirty(direct: Bool) -> Bool {
        switch pointee.state {
        case .dirty:
            return false
        case .maybe:
            // already visited, its sinks are marked; a direct hit upgrades it
            if direct { pointee.state = .dirty }
            return false
        case .clean:
            pointee.state = direct ? .dirty : .maybe
        }

        // only effects react to being dirtied, skip the call for computeds
        if pointee.isEffect {
            pointee.owner._withUnsafeGuaranteedRef { s in
                s.becameDirty(confident: direct)
            }
        }
        return true
    }

    // for computed to check dirty
    // depth-first over `.maybe` sources with an explicit stack; `update` may still pull
    // re-entrantly (a computation reading another computed), that starts its own walk
    @inlinable
    func pull() -> Bool {
        switch pointee.state {
        case .clean: return false
        case .dirty: return recompute()
        case .maybe: break
        }

        // frame: a `.maybe` node and the next of its sources to check
        var stack: [(node: NodeRef, next: Int)] = [(self, 0)]
        var changed = false

        while let (node, next) = stack.last {
            // a source changed (or marked us `.dirty` while recomputing): recompute
            if changed || node.pointee.state == .dirty {
                stack.removeLast()
                changed = node.recompute()
                continue
            }

            // checked every source and none changed
            if next == node.pointee.sources.count {
                node.pointee.state = .clean
                stack.removeLast()
                continue
            }

            stack[stack.count - 1].next = next + 1
            let source = node.pointee.sources[next]
            switch source.pointee.state {
            case .clean: break  // unchanged, signals are always here
            case .dirty: changed = source.recompute()
            case .maybe: stack.append((source, 0))
            }
        }

        return changed
    }

    // state == .dirty or a source changed
    @inlinable
    func recompute() -> Bool {
        let changed = pointee.owner._withUnsafeGuaranteedRef { s in
            pointee.update(s)
        }

        // we are clean now, so a sink pulling us later gets `false` back;
        // tell the ones still waiting that we really changed
        if changed {
            for sink in pointee.sinks.keys where sink.pointee.state == .maybe {
                sink.pointee.state = .dirty
            }
        }

        pointee.state = .clean
        return changed
    }

    @inlinable
    func unlinkSources() {
        for source in pointee.sources {
            source.removeSink(self)
        }
        pointee.sources = []
    }
}

@usableFromInline
@exclusivity(unchecked)
nonisolated(unsafe) var currentSinkNode: NodeRef?

@usableFromInline
@exclusivity(unchecked)
nonisolated(unsafe) var currentImmediateBatch: [EffectNode]?

public class NodeWrapper {
    @usableFromInline
    @exclusivity(unchecked)
    var node: NodeRef

    @inlinable
    init(isEffect: Bool = false, update: @escaping (NodeWrapper) -> Bool = { _ in true }) {
        node = .allocate(capacity: 1)
        node.initialize(to: Node(owner: .passUnretained(self), isEffect: isEffect, update: update))

        // keep `self` alive only when other node depends on this
    }

    // MARK: callback from Node side
    // see state for confident level
    @inlinable
    func becameDirty(confident: Bool) {}

    @inlinable
    public func dump() {
        print(node.pointee)
    }

    deinit {
        assert(node.pointee.sinks.isEmpty)
        node.unlinkSources()
        node.deinitialize(count: 1)
        node.deallocate()
    }
}

public final class SignalNode<T>: NodeWrapper {
    // unchecked: `isUpdating` below is the manual exclusivity check. every access to `_value`
    // is instantaneous except `update`'s inout, and nothing else may touch it meanwhile
    @usableFromInline
    @exclusivity(unchecked)
    var _value: T

    // true while `update` holds `&_value`, like `RefCell`'s mutable borrow flag
    @usableFromInline
    @exclusivity(unchecked)
    var isUpdating = false

    // generic path. When `T` is statically `Equatable`, the overload in the constrained extension
    // below is picked instead: same behavior, but the default equality is an inline `==`
    @inlinable
    public var value: T {
        get { trackedRead() }
        set {
            checkNotUpdating()
            if let equals, equals(_value, newValue) { return }
            _value = newValue
            notifySinks()
        }
    }

    @inlinable
    func trackedRead() -> T {
        checkNotUpdating()
        // this should start an immediate effect batch
        currentSinkNode?.trackRead(node)
        return _value
    }

    @inlinable
    public var peak: T {
        checkNotUpdating()
        return _value
    }

    /// Mutates the value in place (no copy-on-write copy for collections), then notifies sinks
    /// without the `equals` check, so it always propagates.
    @inlinable
    public func update<R, E>(_ body: (inout T) throws(E) -> R) throws(E) -> R {
        checkNotUpdating()
        isUpdating = true
        let result: R
        do {
            defer { isUpdating = false }  // cleared on throw too
            result = try body(&_value)
        }
        notifySinks()
        return result
    }

    @inlinable
    func checkNotUpdating() {
        if _slowPath(isUpdating) { signalAccessConflict() }
    }

    @inlinable
    func notifySinks() {
        // nobody to notify: skip the batch and the walk
        if node.pointee.sinks.isEmpty { return }

        if currentImmediateBatch == nil {
            batch {
                node.propagate()
            }
        } else {
            node.propagate()
        }
    }

    @usableFromInline
    let equals: ((T, T) -> Bool)?

    // set by the `Equatable` init: `equals` is `==`, so the `Equatable` overload of `value`
    // compares inline instead of calling through the closure
    @usableFromInline
    let usesDefaultEquality: Bool

    @inlinable
    public convenience init(_ value: T, equals: ((T, T) -> Bool)?) {
        self.init(value: value, equals: equals, usesDefaultEquality: false)
    }

    @inlinable
    init(value: T, equals: ((T, T) -> Bool)?, usesDefaultEquality: Bool) {
        _value = value
        self.equals = equals
        self.usesDefaultEquality = usesDefaultEquality
        super.init()
        node.pointee.state = .clean
    }
}

// kept out of line so the check on the hot path is a load, a compare and a not-taken branch
@usableFromInline
@inline(never)
func signalAccessConflict() -> Never {
    fatalError("signal accessed while its `update` is still running")
}

extension SignalNode where T: Equatable {
    @inlinable
    public convenience init(_ value: T) {
        self.init(value: value, equals: ==, usesDefaultEquality: true)
    }

    @inlinable
    public var value: T {
        get { trackedRead() }
        set {
            checkNotUpdating()
            if usesDefaultEquality {
                if _value == newValue { return }
            } else if let equals, equals(_value, newValue) {
                return
            }
            _value = newValue
            notifySinks()
        }
    }
}

public final class ComputedNode<T>: NodeWrapper {
    @usableFromInline
    @exclusivity(unchecked)
    var _value: T?
    @usableFromInline
    let equals: ((T, T) -> Bool)?
    @usableFromInline
    let computation: () -> T

    @inlinable
    public var value: T {
        recomputeIfNeeded()
        currentSinkNode?.trackRead(node)
        return _value!
    }

    @inlinable
    public var peek: T {
        recomputeIfNeeded()
        return _value!
    }

    @inlinable
    public convenience init(_ computation: @escaping () -> T, equals: ((T, T) -> Bool)? = nil) {
        // no captures: `self` comes in as the argument, so there's no cycle
        self.init(computation: computation, equals: equals) { wrapper in
            unsafeDowncast(wrapper, to: ComputedNode<T>.self).update()
        }
    }

    // `update` is the recompute thunk, built where `T` is concrete so it's specialized
    @inlinable
    init(
        computation: @escaping () -> T,
        equals: ((T, T) -> Bool)?,
        update: @escaping (NodeWrapper) -> Bool
    ) {
        self.computation = computation
        self.equals = equals
        super.init(update: update)
    }

    @inlinable
    func recomputeIfNeeded() {
        // tell graph to pull, and graph decice to call update
        _ = node.pull()
    }

    @inlinable
    func update() -> Bool {
        let newValue = node.withTracking(computation)
        if let old = _value, let equals, equals(old, newValue) { return false }
        _value = newValue
        return true
    }
}

extension ComputedNode where T: Equatable {
    @inlinable
    public convenience init(_ computation: @escaping () -> T) {
        // the recompute thunk compares with an inline `==` instead of calling `equals`
        self.init(computation: computation, equals: ==) { wrapper in
            unsafeDowncast(wrapper, to: ComputedNode<T>.self).updateEquatable()
        }
    }

    // `update` with the default equality inlined
    @inlinable
    func updateEquatable() -> Bool {
        let newValue = node.withTracking(computation)
        if let old = _value, old == newValue { return false }
        _value = newValue
        return true
    }
}

public final class EffectNode: NodeWrapper {
    @usableFromInline
    let effect: () -> Void
    @usableFromInline
    @exclusivity(unchecked)
    var immediate: Bool

    @usableFromInline
    @exclusivity(unchecked)
    var isReallyDirty: Bool = false

    @inlinable
    public init(immediate: Bool = true, effect: @escaping () -> Void) {
        self.immediate = immediate
        self.effect = effect
        super.init(isEffect: true)
        node.pointee.state = .dirty
        runEffect(force: true)
    }

    @inlinable
    override func becameDirty(confident: Bool) {
        // schedule the update
        if !immediate { fatalError("unimplemented") }

        if confident {
            isReallyDirty = true
        }
        currentImmediateBatch!.append(self)
    }

    @inlinable
    func runEffect(force: Bool = false) {
        defer {
            node.pointee.state = .clean
            isReallyDirty = false
        }

        let shouldRun = force || isReallyDirty || node.pull()
        if !shouldRun { return }

        node.withTracking(effect)
    }
}

@inlinable
public func batch<T>(body: () -> T) -> T {
    let prev = currentImmediateBatch
    currentImmediateBatch = []
    let ret = body()

    for effect in currentImmediateBatch! {
        effect.runEffect()
    }

    currentImmediateBatch = prev
    return ret
}
