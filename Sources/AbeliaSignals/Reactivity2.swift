@preconcurrency import AbeliaSignalsTLS

class Runtime {
    // global/ambient state needed: 
    // - current sink: transient tls
    // - current effect scope: transient tls
}

@usableFromInline
struct Node {
    // state, isEffect and isRunning packed
    @usableFromInline
    var flags: NodeFlags

    // behavior:
    //  - if self is .maybe, force deps recheck (effect)
    //  - `update` callback for dirty computed, effect
    //  - effect owner is outside of the graph
    //      - default effect is just a node with eager update flag
    //      - immediate effect batching is also outside the graph

    // Solid-style edge lists. edge has back index + do swap remove
    @usableFromInline
    var sinks: [Edge] = []
    // in read order, reused by position across reruns (see `trackRead`)
    @usableFromInline
    var sources: [Edge] = []

    @usableFromInline
    var trackingIndex: Int = 0

    @usableFromInline
    let update: (NodeWrapper) -> Bool

    @inlinable
    init(isEffect: Bool, update: @escaping (NodeWrapper) -> Bool) {
        self.flags = isEffect ? [.dirty, .effect] : [.dirty]
        self.update = update
    }

    // for computed/effect: clean = neither state bit set
    @inlinable
    var state: State {
        get {
            if flags.contains(.dirty) { return .dirty }
            if flags.contains(.maybe) { return .maybe }
            return .clean
        }
        set {
            flags.subtract(.stateMask)
            switch newValue {
            case .dirty: flags.insert(.dirty)
            case .maybe: flags.insert(.maybe)
            case .clean: break
            }
        }
    }

    // `owner.becameDirty` is only called for effects. Fixed at init
    @inlinable
    var isEffect: Bool { flags.contains(.effect) }

    // exempted from mark dirty
    @inlinable
    var isRunning: Bool {
        get { flags.contains(.running) }
        set {
            if newValue { flags.insert(.running) } else { flags.remove(.running) }
        }
    }
}

@usableFromInline
@frozen
struct NodeFlags: OptionSet {
    @usableFromInline
    var rawValue: UInt8

    @inlinable
    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    // state: at most one of these, neither = clean
    @inlinable
    static var dirty: NodeFlags { NodeFlags(rawValue: 1 << 0) }
    @inlinable
    static var maybe: NodeFlags { NodeFlags(rawValue: 1 << 1) }
    @inlinable
    static var stateMask: NodeFlags { NodeFlags(rawValue: 0b11) }

    @inlinable
    static var effect: NodeFlags { NodeFlags(rawValue: 1 << 2) }
    @inlinable
    static var running: NodeFlags { NodeFlags(rawValue: 1 << 3) }
}

// sink (and user) own source, effect owner own effect

@usableFromInline
typealias NodeRef = UnsafeMutablePointer<Node>

@usableFromInline
@frozen
struct Edge {
    @usableFromInline
    var node: NodeRef
    @usableFromInline
    // back index
    var slot: Int

    @inlinable
    init(node: NodeRef, slot: Int) {
        self.node = node
        self.slot = slot
    }
}

// object header is 2 words: (metadata pointer, refcount)
@inlinable
var nodeHeaderSize: Int { 2 * MemoryLayout<UnsafeRawPointer>.size }

extension NodeRef {
    @inlinable
    var owner: Unmanaged<NodeWrapper> {
        Unmanaged.fromOpaque(UnsafeRawPointer(self) - nodeHeaderSize)
    }

    @inlinable
    func trackRead(_ source: NodeRef) {
        let i = pointee.trackingIndex

        // dedup: same as the previous read, already linked
        if i > 0, pointee.sources[i - 1].node == source { return }

        if i == pointee.sources.count {
            // larger than before
            pointee.sources.append(Edge(node: source, slot: 0))  // slot set by link
            link(source, at: i)
        } else if pointee.sources[i].node != source {
            // overwrite
            unlink(at: i)
            link(source, at: i)
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
            unlink(at: pointee.sources.count - 1)
            pointee.sources.removeLast()
        }
        return result
    }

    @inlinable
    func link(_ source: NodeRef, at i: Int) {
        let j = source.pointee.sinks.count
        // the graph keeps a source alive while anything depends on it
        if j == 0 {
            _ = source.owner.retain()
        }
        source.pointee.sinks.append(Edge(node: self, slot: i))
        pointee.sources[i] = Edge(node: source, slot: j)
    }

    @inlinable
    func unlink(at i: Int) {
        let source = pointee.sources[i].node
        let j = pointee.sources[i].slot
        let last = source.pointee.sinks.count - 1

        if j != last {
            let moved = source.pointee.sinks[last]
            source.pointee.sinks[j] = moved
            moved.node.pointee.sources[moved.slot].slot = j
        }
        source.pointee.sinks.removeLast()

        if last == 0 {
            source.owner.release()
        }
    }

    // should not be recursive
    @inlinable
    func propagate() {
        var next: [NodeRef] = []

        // by index: nothing here mutates the lists being walked
        for k in pointee.sinks.indices {
            let sink = pointee.sinks[k].node
            if sink.markDirty(direct: true) {
                for m in sink.pointee.sinks.indices {
                    next.append(sink.pointee.sinks[m].node)
                }
            }
        }

        while let top = next.popLast() {
            if top.markDirty(direct: false) {
                for m in top.pointee.sinks.indices {
                    next.append(top.pointee.sinks[m].node)
                }
            }
        }
    }

    // returns: should mark sinks dirty
    @inlinable
    func markDirty(direct: Bool) -> Bool {
        if pointee.isRunning { return false }

        switch pointee.state {
        case .dirty:
            return false
        case .maybe:
            if direct { pointee.state = .dirty }
            return false
        case .clean:
            pointee.state = direct ? .dirty : .maybe
        }

        if pointee.isEffect {
            owner._withUnsafeGuaranteedRef { s in
                s.becameDirty(confident: direct)
            }
        }
        return true
    }

    // for computed to check dirty
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
            let source = node.pointee.sources[next].node
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
        let changed = owner._withUnsafeGuaranteedRef { s in
            pointee.update(s)
        }

        // we are clean now, so a sink pulling us later gets `false` back;
        // tell the ones still waiting that we really changed
        if changed {
            for k in pointee.sinks.indices {
                let sink = pointee.sinks[k].node
                if sink.pointee.state == .maybe { sink.pointee.state = .dirty }
            }
        }

        pointee.state = .clean
        return changed
    }

    @inlinable
    func unlinkSources() {
        // back to front, so no unlink moves an edge of ours that's still to be visited
        var i = pointee.sources.count - 1
        while i >= 0 {
            unlink(at: i)
            i -= 1
        }
        pointee.sources = []
        // a run still in progress (a node disposed mid-run) must not index past the end
        pointee.trackingIndex = 0
    }
}

public class NodeWrapper {
    // inlineeee
    @usableFromInline
    @exclusivity(unchecked)
    var storage: Node

    /// Pointer to the inline `Node`. Stable for the object's lifetime: objects don't move.
    @inlinable
    var node: NodeRef {
        // first and only stored property
        _getUnsafePointerToStoredProperties(self).assumingMemoryBound(to: Node.self)
    }

    @inlinable
    init(isEffect: Bool = false, update: @escaping (NodeWrapper) -> Bool = { _ in true }) {
        storage = Node(isEffect: isEffect, update: update)
        // the layout assumptions `node` and `NodeRef.owner` rely on
        assert(withUnsafeMutablePointer(to: &storage) { $0 } == node, "storage isn't the first stored property")
        assert(
            UnsafeRawPointer(node) - nodeHeaderSize == UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            "object header isn't nodeHeaderSize bytes"
        )

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
    }
}

public final class SignalNode<T>: NodeWrapper {
    @usableFromInline
    @exclusivity(unchecked)
    var _value: T

    // manual exclusivity check
    @usableFromInline
    @exclusivity(unchecked)
    var isUpdating = false

    // generic path.
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

    // less dynamic function call
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
        // no `self` captures
        self.init(computation: computation, equals: equals) { wrapper in
            unsafeDowncast(wrapper, to: ComputedNode<T>.self).update()
        }
    }

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
    let allowRecurse: Bool
    @usableFromInline
    @exclusivity(unchecked)
    var immediate: Bool

    @usableFromInline
    @exclusivity(unchecked)
    var isReallyDirty: Bool = false

    @usableFromInline
    let innerScope: EffectScopeNode

    @usableFromInline
    unowned(unsafe) var scope: EffectScopeNode?
    @usableFromInline
    var indexInScope: Int = -1
    @usableFromInline
    var isDisposed = false

    @inlinable
    public init(immediate: Bool = true, allowRecurse: Bool = false, effect: @escaping () -> Void) {
        self.immediate = immediate
        self.allowRecurse = allowRecurse
        self.effect = effect
        self.innerScope = EffectScopeNode(attached: false)
        super.init(isEffect: true)
        innerScope.ownerEffect = self
        currentScopeNode?.adopt(self)
        node.pointee.state = .dirty
        // inside a batch, like every run: a write in the body only queues, it can't rerun this
        // effect while the body is still running
        batch { runEffect(force: true) }
    }

    @inlinable
    public func dispose() {
        if isDisposed { return }
        let owner = scope
        disposeOwned()
        owner?.release(self)
    }

    // the same, but called by the scope so it wont tell scope to release self again
    @inlinable
    func disposeOwned() {
        if isDisposed { return }
        isDisposed = true
        scope = nil
        // disposed mid-run: the rest of the body reads untracked (withTracking restores the
        // outer sink when the run ends)
        if currentSinkNode == node { currentSinkNode = nil }
        node.unlinkSources()
        innerScope.reset()
    }

    @inlinable
    override func becameDirty(confident: Bool) {
        // schedule the update
        if !immediate { fatalError("unimplemented") }

        if confident {
            isReallyDirty = true
        }
        // in place through the pointer: no copy of the queue
        currentImmediateBatch!.pointee.append(self)
    }

    // .dirty -> yes. `.maybe` -> check
    @inlinable
    func willRerun() -> Bool {
        if node.pointee.state == .maybe {
            for i in node.pointee.sources.indices {
                _ = node.pointee.sources[i].node.pull()
                if node.pointee.state == .dirty { break }
            }
        }
        return node.pointee.state == .dirty
    }

    @inlinable
    func runEffect(force: Bool = false) {
        if isDisposed { return }

        // Owner first, without running it here (it may be on another scheduler)
        // if parent dirty -> self gonna be disposed anywhere
        if !force {
            var owner = scope?.ownerEffect
            while let o = owner {
                if o.willRerun() { return }
                owner = o.scope?.ownerEffect
            }
        }

        let shouldRun = force || isReallyDirty || node.pull()

        // clean before run so write in effect body will mark this dirty again
        node.pointee.state = .clean
        isReallyDirty = false
        if !shouldRun { return }

        innerScope.reset()

        let prev = currentScopeNode
        currentScopeNode = innerScope
        defer { currentScopeNode = prev }
        node.pointee.isRunning = !allowRecurse
        defer { node.pointee.isRunning = false }
        node.withTracking(effect)
    }
}

@inlinable
public func batch<T>(body: () -> T) -> T {
    // nested: ignored
    if currentImmediateBatch != nil { return body() }

    var queue: [EffectNode] = []
    return withUnsafeMutablePointer(to: &queue) { queue in
        currentImmediateBatch = queue
        defer { currentImmediateBatch = nil }

        let ret = body()

        // allow effect to write signal without crashing
        var i = 0
        while i < queue.pointee.count {
            // the queue holding the last reference means nobody owns the effect any more
            // (no handle, no scope; the graph never retains effects): skip it, it dies with the queue
            if isKnownUniquelyReferenced(&queue.pointee[i]) {
                i += 1
                continue
            }
            let effect = queue.pointee[i]
            i += 1
            effect.runEffect()
        }
        return ret
    }
}
