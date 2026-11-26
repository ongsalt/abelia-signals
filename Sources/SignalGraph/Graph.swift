import AbeliaSignals

public final class Graph {
    @usableFromInline
    final class WeakSubgraph {
        @usableFromInline
        weak var subgraph: Subgraph?

        @inlinable
        init(_ subgraph: Subgraph) {
            self.subgraph = subgraph
        }
    }

    @usableFromInline
    @exclusivity(unchecked)
    var subgraphs: [WeakSubgraph] = []
    @usableFromInline
    @exclusivity(unchecked)
    var updateHandler: (() -> Void)?
    @usableFromInline
    @exclusivity(unchecked)
    var invalidationHandler: ((AnyAttribute) -> Void)?

    @inlinable
    public init() {}

    // one graph context per graph here, sharing is meaningless
    @inlinable
    public convenience init(shared: Graph?) {
        self.init()
    }

    @inlinable
    public func onUpdate(_ handler: @escaping () -> Void) {
        updateHandler = handler
    }

    @inlinable
    public func onInvalidation(_ handler: @escaping (AnyAttribute) -> Void) {
        invalidationHandler = handler
    }

    @inlinable
    public func setNeedsUpdate() {
        updateHandler?()
    }

    @inlinable
    public func invalidate() {
        let subgraphs = subgraphs
        self.subgraphs = []
        for entry in subgraphs { entry.subgraph?.invalidate() }
    }

    // its subgraphs don't keep it alive
    deinit {
        invalidate()
    }

    /// Reads in `body` aren't tracked by the current rule.
    @inlinable
    public static func withoutUpdate<T>(_ body: () -> T) -> T {
        let saved = currentRule
        currentRule = nil
        defer { currentRule = saved }
        return untracked(body)
    }
}

/// Owns its attributes: they live until it's invalidated. Doesn't keep its graph alive.
public final class Subgraph {
    @usableFromInline
    unowned(unsafe) let _graph: Graph
    @usableFromInline
    @exclusivity(unchecked)
    var nodes: [AttributeNode] = []
    @usableFromInline
    @exclusivity(unchecked)
    var _isValid = true

    @usableFromInline
    @exclusivity(unchecked)
    var children: [(subgraph: Subgraph, tag: UInt8)] = []
    @usableFromInline
    @exclusivity(unchecked)
    var parents: [Unowned] = []
    @usableFromInline
    @exclusivity(unchecked)
    var observers: [(id: Int, body: () -> Void)] = []
    @usableFromInline
    @exclusivity(unchecked)
    var nextObserverID = 0

    @usableFromInline
    @frozen
    struct Unowned {
        @usableFromInline
        unowned(unsafe) let subgraph: Subgraph

        @inlinable
        init(subgraph: Subgraph) {
            self.subgraph = subgraph
        }
    }

    @exclusivity(unchecked)
    nonisolated(unsafe) public static var current: Subgraph?

    @inlinable
    public init(graph: Graph) {
        _graph = graph
        graph.subgraphs.append(Graph.WeakSubgraph(self))
    }

    deinit {
        invalidate()
    }

    @inlinable
    public var graph: Graph { _graph }

    @inlinable
    public convenience init(graph: Graph, attribute: AnyAttribute) {
        self.init(graph: graph)
    }

    @inlinable
    public var isValid: Bool { _isValid }

    @inlinable
    public func apply<T>(_ body: () -> T) -> T {
        let saved = Subgraph.current
        Subgraph.current = self
        defer { Subgraph.current = saved }
        return Graph.withoutUpdate(body)
    }

    @inlinable
    public func addChild(_ child: Subgraph) {
        addChild(child, tag: 0)
    }

    /// Only the low 2 bits of `tag` are kept, as in AttributeGraph.
    @inlinable
    public func addChild(_ child: Subgraph, tag: UInt8) {
        children.append((child, tag & 0b11))
        child.parents.append(Unowned(subgraph: self))
    }

    @inlinable
    public func removeChild(_ child: Subgraph) {
        guard let i = children.firstIndex(where: { $0.subgraph === child }) else { return }
        children.remove(at: i)
        if let j = child.parents.firstIndex(where: { $0.subgraph === self }) { child.parents.remove(at: j) }
    }

    @inlinable
    public func child(at index: UInt32, tag: UnsafeMutablePointer<UInt8>?) -> Subgraph {
        let entry = children[Int(index)]
        tag?.pointee = entry.tag
        return entry.subgraph
    }

    @inlinable
    public func parent(at index: Int64) -> Subgraph {
        parents[Int(index)].subgraph
    }

    @inlinable
    public var childCount: Int { children.count }

    @inlinable
    public var parentCount: Int { parents.count }

    @inlinable
    public func isAncestor(of other: Subgraph) -> Bool {
        children.contains { $0.subgraph === other || $0.subgraph.isAncestor(of: other) }
    }

    @inlinable
    public func addObserver(_ observer: @escaping () -> Void) -> Int {
        nextObserverID += 1
        observers.append((nextObserverID, observer))
        return nextObserverID
    }

    @inlinable
    public func removeObserver(_ id: Int) {
        observers.removeAll { $0.id == id }
    }

    /// Destroys its attributes, and children left without a valid parent. Also on deinit.
    @inlinable
    public func invalidate() {
        guard _isValid else { return }
        _isValid = false
        if Subgraph.current === self { Subgraph.current = nil }

        for (child, _) in children {
            child.parents.removeAll { $0.subgraph === self }
            if !child.parents.contains(where: { $0.subgraph.isValid }) { child.invalidate() }
        }
        children = []

        let observers = observers
        self.observers = []
        for observer in observers { observer.body() }

        if let handler = graph.invalidationHandler {
            for node in nodes { handler(AnyAttribute(node: node)) }
        }
        // newest first: dependents before what they read
        while !nodes.isEmpty { nodes.removeLast() }
    }
}

extension Subgraph: Hashable {
    @inlinable
    public static func == (lhs: Subgraph, rhs: Subgraph) -> Bool { lhs === rhs }

    @inlinable
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

@inlinable
func requireSubgraph<T>(_: T.Type) -> Subgraph {
    guard let subgraph = Subgraph.current else {
        preconditionFailure("attempting to create attribute with no subgraph: \(T.self)")
    }
    precondition(subgraph.isValid, "attempting to create attribute in an invalidated subgraph")
    return subgraph
}
