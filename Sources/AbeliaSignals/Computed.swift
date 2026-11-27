public final class Computed<T>: ReactiveNode {
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
        Node.current?.trackRead(node)
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
            unsafeDowncast(wrapper, to: Computed<T>.self).update()
        }
    }

    @inlinable
    init(
        computation: @escaping () -> T,
        equals: ((T, T) -> Bool)?,
        update: @escaping (ReactiveNode) -> Bool
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

extension Computed where T: Equatable {
    @inlinable
    public convenience init(_ computation: @escaping () -> T) {
        // the recompute thunk compares with an inline `==` instead of calling `equals`
        self.init(computation: computation, equals: ==) { wrapper in
            unsafeDowncast(wrapper, to: Computed<T>.self).updateEquatable()
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
