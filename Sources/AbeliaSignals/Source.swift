/// A readable reactive source.
public protocol Source<Value> {
    associatedtype Value
    var value: Value { get }
    var peek: Value { get }
}

extension Source {
    @inlinable
    public var peek: Value { untracked { value } }

    @inlinable
    public var getter: Getter<Value> { Getter(self) }
}

/// A readable and writable reactive source.
public protocol MutableSource<Value>: Source {
    var value: Value { get nonmutating set }
}

extension MutableSource {
    @inlinable
    public var binding: Binding<Value> { Binding(self) }
}

/// A read-only reactive handle backed by a getter closure.
public struct Getter<Value>: Source {
    @usableFromInline
    let _get: () -> Value

    @inlinable
    public var value: Value { _get() }

    @inlinable
    public var peek: Value { untracked(_get) }

    @inlinable
    public init(_ get: @escaping () -> Value) {
        self._get = get
    }

    @inlinable
    public init(_ source: some Source<Value>) {
        self._get = { source.value }
    }

    @inlinable
    public static func constant(_ value: Value) -> Self {
        Self { value }
    }
}

/// A read-write reactive handle backed by getter and setter closures.
public struct Binding<Value>: MutableSource {
    @usableFromInline
    let _get: () -> Value

    @usableFromInline
    let _set: (Value) -> Void

    @inlinable
    public var value: Value {
        get { _get() }
        nonmutating set { _set(newValue) }
    }

    @inlinable
    public var peek: Value { untracked(_get) }

    @inlinable
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self._get = get
        self._set = set
    }

    @inlinable
    public init(_ source: some MutableSource<Value>) {
        self._get = { source.value }
        self._set = { source.value = $0 }
    }
}

extension Binding where Value: Equatable {
    @inlinable
    public init(_ signal: Signal<Value>) {
        self._get = { signal.value }
        self._set = { signal.value = $0 }
    }
}

extension Signal: MutableSource {}
extension Computed: Source {}
