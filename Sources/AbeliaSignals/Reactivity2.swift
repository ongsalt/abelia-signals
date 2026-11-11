// all public `init` must lookup `Runtime`.
class Runtime {
    // node arena
    // link arena

    // pending synchronous (immediate) flush
    // fallback Scheduler
}

struct Node: ~Copyable {
    // for computed/effect
    var state: State = .dirty

    // behavior:
    //  - if self is .maybe, force deps recheck (effect)
    //  - `update` callback for dirty computed, effect
    //  - effect owner is outside of the graph
    //      - default effect is just a node with eager update flag
    //      - immediate effect batching is also outside the graph

    // or array + swap remove. also store back index, iterate a lot
    // or make a `DenseSlotMap`
    var sinks: Set<NodeRef> = []  // this still cause refcount
    // allow duplicate, dedup when propagate
    var sources: [NodeRef] = []  // this also cause refcount

    // Node address is NOT stable, but no handle are needed cuz we have back pointer to report this to wrapper
    var owner: Unmanaged<NodeWrapper>
    // dirty callback for effect
    // update callback for computed
}

// sink (and user) own source, effect owner own effect

typealias NodeRef = UnsafeMutablePointer<Node>

extension NodeRef {
    func trackRead(_ source: NodeRef) {
        pointee.sources.append(source)
        source.addSink(self)
    }

    private func addSink(_ sink: NodeRef) {
        // retain
        if pointee.sinks.isEmpty {
            _ = pointee.owner.retain()
        }

        pointee.sinks.insert(sink)
    }

    private func removeSink(_ sink: NodeRef) {
        pointee.sinks.remove(sink)

        if pointee.sinks.isEmpty {
            pointee.owner.release()
        }
    }

    // should not be recursive
    func propagate() {
        var next = Array(pointee.sinks)
        var directSinkLeft = next.count
        print("directSinks: \(next)")

        while let top = next.popLast() {
            let isDirectSink = next.count < directSinkLeft
            print("processing \(top.pointee.owner) direct:\(isDirectSink) state:\(top.pointee.state)")
            if isDirectSink {  // is direct sink
                directSinkLeft -= 1
                if top.pointee.state == .dirty { continue }
                if top.pointee.state == .maybe {
                    top.pointee.state = .dirty
                    continue
                }
                top.pointee.state = .dirty
            } else {
                if top.pointee.state == .dirty || top.pointee.state == .maybe {
                    continue
                }
                // TODO: maybe
                top.pointee.state = .maybe
                top.pointee.state = .dirty
            }

            top.pointee.owner._withUnsafeGuaranteedRef { s in
                s.becameDirty(confident: true)
            }

            for sink in top.pointee.sinks {
                next.append(sink)
            }
        }
    }

    // for computed to check dirty
    func pull(propagate doPropagate: Bool = false) -> Bool {
        if pointee.state == .clean { return false }
        defer { pointee.state = .clean }
        // if pointee.state == .maybe {
        //     var changed = false
        //     for source in pointee.sources {
        //         changed = changed || source.pull()
        //         if changed { break }
        //     }

        //     if !changed {
        //         return false
        //     }
        // }

        // state == .dirty or deps changed
        let changed = pointee.owner._withUnsafeGuaranteedRef { s in
            s.update()
        }

        if changed {
            propagate()
        }

        return changed
    }

    func unlinkSources() {
        for source in pointee.sources {
            source.removeSink(self)
        }
        pointee.sources = []
    }
}

nonisolated(unsafe) var currentSinkNode: NodeRef?
nonisolated(unsafe) var currentImmediateBatch: [EffectNode]?

public class NodeWrapper {
    var node: NodeRef
    init() {
        node = .allocate(capacity: 1)
        node.initialize(to: Node(owner: .passUnretained(self)))

        // keep `self` alive only when other node depends on this
    }

    // MARK: callback from Node side
    // see state for confident level
    func becameDirty(confident: Bool) {}

    // computed, return `changed?`
    func update() -> Bool { false }

    deinit {
        assert(node.pointee.sinks.isEmpty)
        node.unlinkSources()
        node.deinitialize(count: 1)
        node.deallocate()
    }
}

public final class SignalNode<T>: NodeWrapper {
    @usableFromInline
    var _value: T

    // @inlinable
    public var value: T {
        get {
            // this should start an immediate effect batch
            currentSinkNode?.trackRead(node)
            return _value
        }
        set {
            let shouldStartBatch = currentImmediateBatch == nil
            if shouldStartBatch {
                currentImmediateBatch = []
            }

            _value = newValue
            node.propagate()

            // flush
            if shouldStartBatch {
                for effect in currentImmediateBatch! {
                    effect.runEffect()
                }
                currentImmediateBatch = nil
            }
        }
    }
    let equals: ((T, T) -> Bool)?

    public init(_ value: T) {
        _value = value
        equals = nil
        super.init()
        node.pointee.state = .clean
    }
}

public final class ComputedNode<T>: NodeWrapper {
    @usableFromInline
    var _value: T?
    let equals: ((T, T) -> Bool)?
    var computation: () -> T

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

    public init(_ computation: @escaping () -> T) {
        self.computation = computation
        equals = nil
        super.init()
    }

    @usableFromInline
    func recomputeIfNeeded() {
        // tell graph to pull, and graph decice to call update
        _ = node.pull()
    }

    override func update() -> Bool {
        let prev = currentSinkNode
        currentSinkNode = node
        defer { currentSinkNode = prev }

        node.unlinkSources()
        _value = computation()
        // print("compute")
        // print(node.pointee.sources)
        // print(node.pointee.sinks)

        return true
    }
}

public final class EffectNode: NodeWrapper {
    let effect: () -> Void
    var immediate: Bool

    var isReallyDirty: Bool = false

    public init(immediate: Bool = true, effect: @escaping () -> Void) {
        self.immediate = immediate
        self.effect = effect
        super.init()
        node.pointee.state = .dirty
        runEffect(force: true)
    }

    override func becameDirty(confident: Bool) {
        // schedule the update
        if !immediate { fatalError("unimplemented") }
        print("became dirty confident:\(isReallyDirty)")

        if confident {
            isReallyDirty = true
        }
        currentImmediateBatch!.append(self)
    }

    func runEffect(force: Bool = false) {
        defer {
            node.pointee.state = .clean
            isReallyDirty = false
        }

        let shouldRun = force || isReallyDirty || node.pull()
        if !shouldRun { return }

        let prev = currentSinkNode
        currentSinkNode = node
        defer { currentSinkNode = prev }

        node.unlinkSources()
        effect()
    }
}
