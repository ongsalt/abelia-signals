import AbeliaSignals

/// nil once its subgraph is invalidated.
@frozen
public struct AnyWeakAttribute: Hashable {
    @usableFromInline
    weak var node: AttributeNode?
    @usableFromInline
    let id: ObjectIdentifier?

    @inlinable
    public init(_ attribute: AnyAttribute?) {
        node = attribute?.node
        id = attribute.map { ObjectIdentifier($0.node) }
    }

    @inlinable
    public var attribute: AnyAttribute? {
        get {
            guard let node, node.subgraph.isValid else { return nil }
            return AnyAttribute(node: node)
        }
        set { self = AnyWeakAttribute(newValue) }
    }

    @inlinable
    public static func == (lhs: AnyWeakAttribute, rhs: AnyWeakAttribute) -> Bool { lhs.id == rhs.id }

    @inlinable
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@frozen
@propertyWrapper
@dynamicMemberLookup
public struct WeakAttribute<Value>: Hashable {
    public var base: AnyWeakAttribute

    @inlinable
    public init(base: AnyWeakAttribute) {
        self.base = base
    }

    @inlinable
    public init() {
        base = AnyWeakAttribute(nil)
    }

    @inlinable
    public init(_ attribute: Attribute<Value>) {
        base = AnyWeakAttribute(attribute.identifier)
    }

    @inlinable
    public init(_ attribute: Attribute<Value>?) {
        base = AnyWeakAttribute(attribute?.identifier)
    }

    @inlinable
    public var attribute: Attribute<Value>? {
        get { base.attribute?.unsafeCast(to: Value.self) }
        set { base.attribute = newValue?.identifier }
    }

    @inlinable
    public var value: Value? { attribute?.value }

    @inlinable
    public func changedValue(options: ValueOptions = []) -> (value: Value, changed: Bool)? {
        attribute?.changedValue(options: options)
    }

    @inlinable
    public var wrappedValue: Value? { value }

    @inlinable
    public var projectedValue: Attribute<Value>? {
        get { attribute }
        set { attribute = newValue }
    }

    @inlinable
    public subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Attribute<Member>? {
        attribute?[keyPath: keyPath]
    }
}

@frozen
public struct AnyOptionalAttribute: Hashable {
    public var identifier: AnyAttribute?

    @inlinable
    public init() {
        identifier = nil
    }

    @inlinable
    public init(_ attribute: AnyAttribute?) {
        identifier = attribute
    }

    @inlinable
    public init(_ weak: AnyWeakAttribute) {
        identifier = weak.attribute
    }

    @inlinable
    public var attribute: AnyAttribute? {
        get { identifier }
        set { identifier = newValue }
    }
}

@frozen
@propertyWrapper
@dynamicMemberLookup
public struct OptionalAttribute<Value>: Hashable {
    public var base: AnyOptionalAttribute

    @inlinable
    public init(base: AnyOptionalAttribute) {
        self.base = base
    }

    @inlinable
    public init() {
        base = AnyOptionalAttribute()
    }

    @inlinable
    public init(_ weakAttribute: WeakAttribute<Value>) {
        base = AnyOptionalAttribute(weakAttribute.base)
    }

    @inlinable
    public init(_ attribute: Attribute<Value>) {
        base = AnyOptionalAttribute(attribute.identifier)
    }

    @inlinable
    public init(_ attribute: Attribute<Value>?) {
        base = AnyOptionalAttribute(attribute?.identifier)
    }

    @inlinable
    public var attribute: Attribute<Value>? {
        get { base.attribute?.unsafeCast(to: Value.self) }
        set { base.attribute = newValue?.identifier }
    }

    @inlinable
    public var value: Value? { attribute?.value }

    @inlinable
    public func changedValue(options: ValueOptions = []) -> (value: Value, changed: Bool)? {
        attribute?.changedValue(options: options)
    }

    @inlinable
    public func map<T>(_ transform: (Attribute<Value>) -> T) -> T? {
        attribute.map(transform)
    }

    @inlinable
    public var wrappedValue: Value? { value }

    @inlinable
    public var projectedValue: Attribute<Value>? {
        get { attribute }
        set { attribute = newValue }
    }

    @inlinable
    public subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Attribute<Member>? {
        attribute?[dynamicMember: keyPath]
    }
}

/// Forwards to a source that can be swapped.
@frozen
@propertyWrapper
@dynamicMemberLookup
public struct IndirectAttribute<Value>: Hashable {
    public var identifier: AnyAttribute

    @inlinable
    var node: IndirectNode<Value> { unsafeDowncast(identifier.node, to: IndirectNode<Value>.self) }

    @inlinable
    init(source: Attribute<Value>, equals: ((Value, Value) -> Bool)?) {
        identifier = AnyAttribute(
            node: IndirectNode<Value>(subgraph: requireSubgraph(Value.self), source: source.identifier, equals: equals)
        )
    }

    @inlinable
    public init(source: Attribute<Value>) {
        self.init(source: source, equals: nil)
    }

    @inlinable
    public var source: Attribute<Value> {
        get { Attribute(identifier: node.source.peek) }
        nonmutating set { node.source.value = newValue.identifier }
    }

    @inlinable
    public var attribute: Attribute<Value> { Attribute(identifier: identifier) }

    @inlinable
    public func resetSource() {
        node.source.value = node.initialSource
    }

    @inlinable
    public var dependency: AnyAttribute? {
        get { node.dependency }
        nonmutating set { node.dependency = newValue }
    }

    @inlinable
    public var value: Value {
        get { attribute.value }
        nonmutating set { attribute.value = newValue }
    }

    @inlinable
    public func changedValue(options: ValueOptions = []) -> (value: Value, changed: Bool) {
        attribute.changedValue(options: options)
    }

    @inlinable
    public var wrappedValue: Value {
        get { value }
        nonmutating set { value = newValue }
    }

    @inlinable
    public var projectedValue: Attribute<Value> { attribute }

    @inlinable
    public subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Attribute<Member> {
        attribute[dynamicMember: keyPath]
    }
}

extension IndirectAttribute where Value: Equatable {
    @inlinable
    public init(source: Attribute<Value>) {
        self.init(source: source, equals: ==)
    }
}
