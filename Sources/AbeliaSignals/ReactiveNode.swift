public class ReactiveNode {
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
    init(isEffect: Bool = false, onRecompute: @escaping (ReactiveNode) -> Bool = { _ in true }) {
        storage = Node(isEffect: isEffect, onRecompute: onRecompute)
        // the layout assumptions `node` and `NodeRef.owner` rely on
        assert(
            withUnsafeMutablePointer(to: &storage) { $0 } == node,
            "storage isn't the first stored property")
        assert(
            UnsafeRawPointer(node) - nodeHeaderSize
                == UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            "object header isn't nodeHeaderSize bytes"
        )

        // keep `self` alive only when other node depends on this
    }

    // MARK: callback from Node side
    // see state for confident level
    @inlinable
    func becameDirty(confident: Bool) {}

    internal func dump() {
        print(node.pointee)
    }

    deinit {
        assert(node.pointee.sinks.isEmpty)
        node.unlinkSources()
    }
}
