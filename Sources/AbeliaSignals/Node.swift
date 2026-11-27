@usableFromInline
enum State {
    case dirty
    case maybe
    case clean
}

@usableFromInline
struct Node {
    // state, isEffect and isRunning packed
    @usableFromInline
    var flags: NodeFlags

    // behavior:
    //  - if self is .maybe, force deps recheck (effect)
    //  - `onRecompute` callback for dirty computed, effect
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
    let onRecompute: (ReactiveNode) -> Bool

    @inlinable
    init(isEffect: Bool, onRecompute: @escaping (ReactiveNode) -> Bool) {
        self.flags = isEffect ? [.dirty, .effect] : [.dirty]
        self.onRecompute = onRecompute
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
    var owner: Unmanaged<ReactiveNode> {
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
        let prev = Node.current
        Node.current = self
        defer { Node.current = prev }

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
            if next >= node.pointee.sources.count {
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
            pointee.onRecompute(s)
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
