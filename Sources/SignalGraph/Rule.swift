import AbeliaSignals

public protocol Rule {
    associatedtype Value

    static var initialValue: Value? { get }
    var value: Value { get }
}

extension Rule {
    @inlinable
    public static var initialValue: Value? { nil }

    @inlinable
    public var bodyChanged: Bool { AnyAttribute.currentWasModified }

    @inlinable
    public var attribute: Attribute<Value> {
        Attribute<Value>(identifier: AnyAttribute.current!)
    }

    @inlinable
    public var context: RuleContext<Value> {
        RuleContext<Value>(attribute: attribute)
    }
}

/// The body persists between updates and sets its own output.
public protocol StatefulRule {
    associatedtype Value

    static var initialValue: Value? { get }
    mutating func updateValue()
}

extension StatefulRule {
    @inlinable
    public static var initialValue: Value? { nil }

    @inlinable
    public var bodyChanged: Bool { AnyAttribute.currentWasModified }

    /// The current output: the previous one until set.
    @inlinable
    public var value: Value {
        get { context.value }
        nonmutating set { context.value = newValue }
    }

    @inlinable
    public var hasValue: Bool { context.hasValue }

    @inlinable
    public var attribute: Attribute<Value> {
        Attribute<Value>(identifier: AnyAttribute.current!)
    }

    @inlinable
    public var context: RuleContext<Value> {
        RuleContext<Value>(attribute: attribute)
    }
}

@frozen
public struct RuleContext<Value>: Equatable {
    public var attribute: Attribute<Value>

    @inlinable
    public init(attribute: Attribute<Value>) {
        self.attribute = attribute
    }

    /// Runs `body` as part of this attribute's update.
    @inlinable
    public func update(body: () -> Void) {
        let saved = currentRule
        currentRule = attribute.identifier.node
        defer { currentRule = saved }
        body()
    }

    /// A StatefulRule's output (or the initial value). A plain `Rule`'s output isn't kept here.
    @inlinable
    public var value: Value {
        get {
            guard let output = attribute.node.output else { preconditionFailure("attribute has no value") }
            return output
        }
        nonmutating set { attribute.node.output = newValue }
    }

    @inlinable
    public var hasValue: Bool { attribute.node.output != nil }

    /// Whether `input` changed since this attribute's rule last ran.
    @inlinable
    public func changedValue<T>(of input: Attribute<T>, options: ValueOptions) -> (value: T, changed: Bool) {
        let node = input.node
        let value = node.read()
        return (value, node.changedAt > attribute.identifier.node.prevRun)
    }

    // AttributeGraph's spelling
    @inlinable
    public subscript<T>(attribute input: Attribute<T>) -> T { input.value }

    @inlinable
    public subscript<T>(weakAttribute input: WeakAttribute<T>) -> T? { input.attribute.map { self[attribute: $0] } }

    @inlinable
    public subscript<T>(optionalAttribute input: OptionalAttribute<T>) -> T? {
        input.attribute.map { self[attribute: $0] }
    }

    // Compute's spelling
    @inlinable
    public subscript<T>(_ input: Attribute<T>) -> T { input.value }

    @inlinable
    public subscript<T>(_ input: WeakAttribute<T>) -> T? { input.attribute.map { self[$0] } }

    @inlinable
    public subscript<T>(_ input: OptionalAttribute<T>) -> T? { input.attribute.map { self[$0] } }
}

@frozen
public struct AnyRuleContext: Equatable {
    public var attribute: AnyAttribute

    @inlinable
    public init(attribute: AnyAttribute) {
        self.attribute = attribute
    }

    @inlinable
    public init<Value>(_ context: RuleContext<Value>) {
        attribute = context.attribute.identifier
    }

    @inlinable
    public func unsafeCast<Value>(to type: Value.Type) -> RuleContext<Value> {
        RuleContext(attribute: Attribute(identifier: attribute))
    }

    @inlinable
    public func update(body: () -> Void) {
        unsafeCast(to: Void.self).update(body: body)
    }

    @inlinable
    public func changedValue<Value>(of input: Attribute<Value>, options: ValueOptions) -> (value: Value, changed: Bool) {
        let node = input.node
        let value = node.read()
        return (value, node.changedAt > attribute.node.prevRun)
    }

    @inlinable
    public subscript<Value>(attribute input: Attribute<Value>) -> Value { input.value }

    @inlinable
    public subscript<Value>(weakAttribute input: WeakAttribute<Value>) -> Value? {
        input.attribute.map { self[attribute: $0] }
    }

    @inlinable
    public subscript<Value>(optionalAttribute input: OptionalAttribute<Value>) -> Value? {
        input.attribute.map { self[attribute: $0] }
    }

    @inlinable
    public subscript<Value>(_ input: Attribute<Value>) -> Value { input.value }

    @inlinable
    public subscript<Value>(_ input: WeakAttribute<Value>) -> Value? { input.attribute.map { self[$0] } }

    @inlinable
    public subscript<Value>(_ input: OptionalAttribute<Value>) -> Value? { input.attribute.map { self[$0] } }
}

@frozen
public struct Focus<Root, Value>: Rule {
    public var root: Attribute<Root>
    public var keyPath: KeyPath<Root, Value>

    @inlinable
    public init(root: Attribute<Root>, keyPath: KeyPath<Root, Value>) {
        self.root = root
        self.keyPath = keyPath
    }

    @inlinable
    public var value: Value { root.value[keyPath: keyPath] }
}

@frozen
public struct Map<Arg, Value>: Rule {
    public var arg: Attribute<Arg>
    public var body: (Arg) -> Value

    @inlinable
    public init(_ arg: Attribute<Arg>, _ body: @escaping (Arg) -> Value) {
        self.arg = arg
        self.body = body
    }

    @inlinable
    public var value: Value { body(arg.value) }
}
