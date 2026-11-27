@propertyWrapper
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
    public var wrappedValue: T { value }

    @inlinable
    public convenience init(
        wrappedValue: @escaping @autoclosure () -> T,
        equals: ((T, T) -> Bool)? = nil
    ) {
        self.init(wrappedValue, equals: equals)
    }

    @inlinable
    public convenience init(_ computation: @escaping () -> T, equals: ((T, T) -> Bool)? = nil) {
        // no `self` captures
        self.init(computation: computation, equals: equals) { wrapper in
            unsafeDowncast(wrapper, to: Computed<T>.self).recompute()
        }
    }

    @inlinable
    init(
        computation: @escaping () -> T,
        equals: ((T, T) -> Bool)?,
        onRecompute: @escaping (ReactiveNode) -> Bool
    ) {
        self.computation = computation
        self.equals = equals
        super.init(onRecompute: onRecompute)
    }

    @inlinable
    func recomputeIfNeeded() {
        // tell graph to pull, and graph decides to call onRecompute
        _ = node.pull()
    }

    @inlinable
    func recompute() -> Bool {
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
            unsafeDowncast(wrapper, to: Computed<T>.self).recomputeEquatable()
        }
    }

    @inlinable
    public convenience init(wrappedValue: @escaping @autoclosure () -> T) {
        self.init(wrappedValue)
    }

    // `recompute` with the default equality inlined
    @inlinable
    func recomputeEquatable() -> Bool {
        let newValue = node.withTracking(computation)
        if let old = _value, old == newValue { return false }
        _value = newValue
        return true
    }
}
