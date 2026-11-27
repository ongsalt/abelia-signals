/// Backing storage for a computed property on a class without retaining `self`.
public struct ComputedStorage<Root: AnyObject, T>: ~Copyable {
    @usableFromInline
    let storage: ComputedStorageNode<Root, T>

    @inlinable
    public init(equals: ((T, T) -> Bool)? = nil, _ computation: @escaping (Root) -> T) {
        self.storage = ComputedStorageNode(computation: computation, equals: equals) { wrapper in
            unsafeDowncast(wrapper, to: ComputedStorageNode<Root, T>.self).update()
        }
    }

    @MainActor
    @_disfavoredOverload
    @inlinable
    public init(
        equals: ((T, T) -> Bool)? = nil,
        _ computation: @escaping @MainActor (Root) -> T
    ) {
        self.init(equals: equals) { root in
            nonisolated(unsafe) let root = root
            nonisolated(unsafe) var result: T?
            MainActor.assumeIsolated { result = computation(root) }
            return result!
        }
    }

    @inlinable
    init(storage: ComputedStorageNode<Root, T>) {
        self.storage = storage
    }

    @inlinable
    public func value(_ parent: Root) -> T {
        storage.value(parent)
    }

    @inlinable
    public func peek(_ parent: Root) -> T {
        storage.peek(parent)
    }

    @inlinable
    deinit {
        storage.invalidate()
    }
}

extension ComputedStorage where T: Equatable {
    @inlinable
    public init(_ computation: @escaping (Root) -> T) {
        // the recompute thunk compares with an inline `==` instead of calling `equals`
        self.init(
            storage: ComputedStorageNode(computation: computation, equals: ==) { wrapper in
                unsafeDowncast(wrapper, to: ComputedStorageNode<Root, T>.self).updateEquatable()
            }
        )
    }

    @MainActor
    @_disfavoredOverload
    @inlinable
    public init(_ computation: @escaping @MainActor (Root) -> T) {
        self.init { root in
            nonisolated(unsafe) let root = root
            nonisolated(unsafe) var result: T?
            MainActor.assumeIsolated { result = computation(root) }
            return result!
        }
    }
}

@usableFromInline
final class ComputedStorageNode<Root: AnyObject, T>: ReactiveNode {
    @usableFromInline
    @exclusivity(unchecked)
    unowned(unsafe) var parent: Root?

    @usableFromInline
    @exclusivity(unchecked)
    var _value: T?

    @usableFromInline
    let equals: ((T, T) -> Bool)?

    @usableFromInline
    let computation: (Root) -> T

    @inlinable
    init(
        computation: @escaping (Root) -> T,
        equals: ((T, T) -> Bool)?,
        update: @escaping (ReactiveNode) -> Bool
    ) {
        self.computation = computation
        self.equals = equals
        super.init(update: update)
    }

    @inlinable
    func value(_ parent: Root) -> T {
        if _value == nil { self.parent = parent }
        _ = node.pull()
        Node.current?.trackRead(node)
        return _value!
    }

    @inlinable
    func peek(_ parent: Root) -> T {
        if _value == nil { self.parent = parent }
        _ = node.pull()
        return _value!
    }

    @inlinable
    func update() -> Bool {
        guard let root = parent else { return false }
        let newValue = node.withTracking { computation(root) }
        if let old = _value, let equals, equals(old, newValue) { return false }
        _value = newValue
        return true
    }

    @inlinable
    func invalidate() {
        parent = nil
        _value = nil
        node.unlinkSources()
        node.pointee.state = .clean
    }
}

extension ComputedStorageNode where T: Equatable {
    @inlinable
    func updateEquatable() -> Bool {
        guard let root = parent else { return false }
        let newValue = node.withTracking { computation(root) }
        if let old = _value, old == newValue { return false }
        _value = newValue
        return true
    }
}
