public final class Signal<T>: ReactiveNode {
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
        Node.current?.trackRead(node)
        return _value
    }

    @inlinable
    public var peek: T {
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

        if ImmediateBatch.current == nil {
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

extension Signal where T: Equatable {
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
