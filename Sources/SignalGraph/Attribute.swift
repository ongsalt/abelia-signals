import AbeliaSignals

@frozen
public struct ValueOptions: OptionSet, Sendable {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// An attribute's identity. Unowned, like AttributeGraph's 32-bit ID: the subgraph owns the node.
@frozen
public struct AnyAttribute {
    @usableFromInline
    unowned(unsafe) let node: AttributeNode

    @inlinable
    init(node: AttributeNode) {
        self.node = node
    }

    @inlinable
    public init<Value>(_ attribute: Attribute<Value>) {
        self = attribute.identifier
    }

    @inlinable
    public static var current: AnyAttribute? {
        currentRule.map { AnyAttribute(node: $0) }
    }

    /// Whether `mutateBody` touched the current rule since its last run.
    @inlinable
    public static var currentWasModified: Bool {
        currentRule?.bodyWasModified ?? false
    }

    @inlinable
    public func unsafeCast<Value>(to type: Value.Type) -> Attribute<Value> {
        Attribute(identifier: self)
    }

    @inlinable
    public var subgraph: Subgraph { node.subgraph }

    @inlinable
    public var subgraphOrNil: Subgraph? { node.subgraph.isValid ? node.subgraph : nil }

    @inlinable
    public var graph: Graph { node.subgraph.graph }

    @inlinable
    public var valueType: Any.Type { node.valueType }

    @inlinable
    public var hasValue: Bool { node.hasValue }

    @inlinable
    public func updateValue() { node.update() }

    @inlinable
    public func invalidateValue() { node.invalidateValue() }

    @inlinable
    public func mutateBody<Body>(as type: Body.Type, invalidating: Bool, _ mutator: (inout Body) -> Void) {
        guard let node = node as? BodyMutating else { preconditionFailure("attribute has no rule body") }
        node.mutateBody(as: type, invalidating: invalidating, mutator)
    }
}

extension AnyAttribute: Hashable {
    @inlinable
    public static func == (lhs: AnyAttribute, rhs: AnyAttribute) -> Bool { lhs.node === rhs.node }

    @inlinable
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(node)) }
}

extension AnyAttribute: CustomStringConvertible {
    @inlinable
    public var description: String {
        "#\(String(UInt(bitPattern: ObjectIdentifier(node).hashValue), radix: 16))"
    }
}

/// Change detection follows `Signal` / `Computed`: `==` when `Value` is Equatable (picked by
/// overload, so it needs the concrete type at the call site), otherwise every update is a change.
@frozen
@propertyWrapper
@dynamicMemberLookup
public struct Attribute<Value> {
    public var identifier: AnyAttribute

    @inlinable
    var node: ValueNode<Value> { unsafeDowncast(identifier.node, to: ValueNode<Value>.self) }

    @inlinable
    public init(identifier: AnyAttribute) {
        self.identifier = identifier
    }

    @inlinable
    public init(_ attribute: Attribute<Value>) {
        self = attribute
    }

    @inlinable
    init(node: ValueNode<Value>) {
        identifier = AnyAttribute(node: node)
    }

    @inlinable
    init(value: Value?, equals: ((Value, Value) -> Bool)?) {
        self.init(node: ExternalNode(subgraph: requireSubgraph(Value.self), value: value, equals: equals))
    }

    @inlinable
    public init(value: Value) {
        self.init(value: value, equals: nil)
    }

    @inlinable
    public init(type: Value.Type) {
        self.init(value: nil, equals: nil)
    }

    @inlinable
    public var graph: Graph { identifier.graph }

    @inlinable
    public var subgraph: Subgraph { identifier.subgraph }

    @inlinable
    public var subgraphOrNil: Subgraph? { identifier.subgraphOrNil }

    @inlinable
    public var value: Value {
        get { node.read() }
        nonmutating set { _ = setValue(newValue) }
    }

    /// Whether it changed.
    @discardableResult
    @inlinable
    public func setValue(_ value: Value) -> Bool {
        node.write(value)
    }

    @inlinable
    public var hasValue: Bool { node.hasValue }

    /// Inside a rule: changed since that rule last ran. Outside: this read recomputed it to a new value.
    @inlinable
    public func changedValue(options: ValueOptions = []) -> (value: Value, changed: Bool) {
        let node = node
        if let rule = currentRule {
            let value = node.read()
            return (value, node.changedAt > rule.prevRun)
        }
        let before = node.changedAt
        let value = node.read()
        return (value, node.changedAt != before)
    }

    @inlinable
    public func updateValue() { node.update() }

    @inlinable
    public func prefetchValue() { node.update() }

    @inlinable
    public func invalidateValue() { node.invalidateValue() }

    @inlinable
    public func validate() {}

    @inlinable
    public func mutateBody<Body>(as type: Body.Type, invalidating: Bool, _ mutator: (inout Body) -> Void) {
        identifier.mutateBody(as: type, invalidating: invalidating, mutator)
    }

    @inlinable
    public var wrappedValue: Value {
        get { node.read() }
        nonmutating set { _ = setValue(newValue) }
    }

    @inlinable
    public var projectedValue: Attribute<Value> {
        get { self }
        set { self = newValue }
    }

    /// A `Focus` rule. AttributeGraph makes an offset attribute for stored fields; this is always a node.
    @inlinable
    public subscript<Member>(keyPath keyPath: KeyPath<Value, Member>) -> Attribute<Member> {
        Attribute<Member>(Focus(root: self, keyPath: keyPath))
    }

    @inlinable
    public subscript<Member: Equatable>(keyPath keyPath: KeyPath<Value, Member>) -> Attribute<Member> {
        Attribute<Member>(Focus(root: self, keyPath: keyPath))
    }

    @inlinable
    public subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Attribute<Member> {
        self[keyPath: keyPath]
    }

    @inlinable
    public subscript<Member: Equatable>(dynamicMember keyPath: KeyPath<Value, Member>) -> Attribute<Member> {
        self[keyPath: keyPath]
    }

    @inlinable
    public func unsafeCast<T>(to type: T.Type) -> Attribute<T> {
        Attribute<T>(identifier: identifier)
    }
}

extension Attribute where Value: Equatable {
    @inlinable
    public init(value: Value) {
        self.init(value: value, equals: ==)
    }

    @inlinable
    public init(type: Value.Type) {
        self.init(value: nil, equals: ==)
    }
}

extension Attribute: Hashable {
    @inlinable
    public static func == (lhs: Attribute, rhs: Attribute) -> Bool { lhs.identifier == rhs.identifier }

    @inlinable
    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}

extension Attribute: CustomStringConvertible {
    @inlinable
    public var description: String { identifier.description }
}

// MARK: rules

extension Attribute {
    @inlinable
    init<Body>(
        body: Body,
        initialValue: Value?,
        equals: ((Value, Value) -> Bool)?,
        run: @escaping (RuleNode<Body, Value>) -> Value
    ) {
        self.init(
            node: RuleNode(
                subgraph: requireSubgraph(Body.self),
                body: body,
                initialValue: initialValue,
                equals: equals,
                run: run
            )
        )
    }

    @inlinable
    public init<Body: Rule>(_ body: Body) where Body.Value == Value {
        self.init(body: body, initialValue: nil, equals: nil) { $0.body.value }
    }

    @inlinable
    public init<Body: Rule>(_ body: Body, initialValue: Value) where Body.Value == Value {
        self.init(body: body, initialValue: initialValue, equals: nil) { $0.body.value }
    }

    @inlinable
    public init<Body: StatefulRule>(_ body: Body) where Body.Value == Value {
        self.init(body: body, initialValue: nil, equals: nil, run: runStateful)
    }

    @inlinable
    public init<Body: StatefulRule>(_ body: Body, initialValue: Value) where Body.Value == Value {
        self.init(body: body, initialValue: initialValue, equals: nil, run: runStateful)
    }
}

extension Attribute where Value: Equatable {
    @inlinable
    public init<Body: Rule>(_ body: Body) where Body.Value == Value {
        self.init(body: body, initialValue: nil, equals: ==) { $0.body.value }
    }

    @inlinable
    public init<Body: Rule>(_ body: Body, initialValue: Value) where Body.Value == Value {
        self.init(body: body, initialValue: initialValue, equals: ==) { $0.body.value }
    }

    @inlinable
    public init<Body: StatefulRule>(_ body: Body) where Body.Value == Value {
        self.init(body: body, initialValue: nil, equals: ==, run: runStateful)
    }

    @inlinable
    public init<Body: StatefulRule>(_ body: Body, initialValue: Value) where Body.Value == Value {
        self.init(body: body, initialValue: initialValue, equals: ==, run: runStateful)
    }
}

@inlinable
func runStateful<Body: StatefulRule>(_ node: RuleNode<Body, Body.Value>) -> Body.Value {
    node.body.updateValue()
    guard let value = node.output else { preconditionFailure("\(Body.self) didn't set a value") }
    return value
}
