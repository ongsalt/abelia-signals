import AbeliaSignals

// Graph state. Not thread-safe, like an AttributeGraph update.

/// Goes up on every real value change. `changedValue` compares against it.
@usableFromInline
@exclusivity(unchecked)
nonisolated(unsafe) var epoch = 0

/// The rule being evaluated (`AnyAttribute.current`).
@usableFromInline
@exclusivity(unchecked)
nonisolated(unsafe) unowned(unsafe) var currentRule: AttributeNode?

@usableFromInline
class AttributeNode {
    @usableFromInline
    unowned(unsafe) let subgraph: Subgraph

    // epoch of the last real change
    @usableFromInline
    @exclusivity(unchecked)
    var changedAt = 0
    // rule only: epoch at the end of the previous run, and of the one before it
    @usableFromInline
    @exclusivity(unchecked)
    var lastRun = -1
    @usableFromInline
    @exclusivity(unchecked)
    var prevRun = -1
    @usableFromInline
    @exclusivity(unchecked)
    var bodyWasModified = false

    @inlinable
    init(subgraph: Subgraph) {
        self.subgraph = subgraph
        subgraph.nodes.append(self)
    }

    @inlinable
    final func markChanged() {
        epoch &+= 1
        changedAt = epoch
    }

    @inlinable
    var hasValue: Bool { fatalError("abstract") }

    @inlinable
    var valueType: Any.Type { fatalError("abstract") }

    @inlinable
    func invalidateValue() {}

    @inlinable
    func update() {}
}

@usableFromInline
class ValueNode<Value>: AttributeNode {
    // a StatefulRule's output, or an initial value
    @usableFromInline
    @exclusivity(unchecked)
    var output: Value?

    @inlinable
    override init(subgraph: Subgraph) {
        super.init(subgraph: subgraph)
    }

    @inlinable
    override var valueType: Any.Type { Value.self }

    /// Up to date, tracked.
    @inlinable
    func read() -> Value { fatalError("abstract") }

    @inlinable
    func write(_ value: Value) -> Bool {
        preconditionFailure("attribute isn't external: \(Value.self)")
    }

    @inlinable
    override func update() { _ = read() }
}

/// `equals`: `==` for Equatable values, else nil (every write is a change), like `Signal`.
@usableFromInline
final class ExternalNode<Value>: ValueNode<Value> {
    // nil until the first write (`Attribute(type:)`)
    @usableFromInline
    @exclusivity(unchecked)
    var signal: Signal<Value>?
    @usableFromInline
    let equals: ((Value, Value) -> Bool)?

    @inlinable
    init(subgraph: Subgraph, value: Value?, equals: ((Value, Value) -> Bool)?) {
        self.equals = equals
        super.init(subgraph: subgraph)
        signal = value.map { Signal($0, equals: nil) }
    }

    @inlinable
    override var hasValue: Bool { signal != nil }

    @inlinable
    override func read() -> Value {
        guard let signal else { preconditionFailure("attribute has no value: \(Value.self)") }
        return signal.value
    }

    @inlinable
    override func write(_ value: Value) -> Bool {
        guard let signal else {
            markChanged()
            self.signal = Signal(value, equals: nil)
            return true
        }
        if let equals, equals(signal.peek, value) { return false }
        markChanged()
        signal.value = value
        return true
    }
}

/// Backed by a `Computed`, which decides what counts as a change: `equals` as for `ExternalNode`.
@usableFromInline
class DerivedNode<Value>: ValueNode<Value> {
    @usableFromInline
    @exclusivity(unchecked)
    var computed: Computed<Value>!
    // no `equals`: every run is a change
    @usableFromInline
    @exclusivity(unchecked)
    var alwaysChanges = false
    @usableFromInline
    @exclusivity(unchecked)
    var hasRun = false
    // an initial value is the first result: the body runs only once invalidated
    @usableFromInline
    @exclusivity(unchecked)
    var usesInitialValue = false

    @inlinable
    init(subgraph: Subgraph, equals: ((Value, Value) -> Bool)?) {
        super.init(subgraph: subgraph)
        if let equals {
            // `Computed` calls `equals` from the second run on
            computed = Computed(
                { [unowned(unsafe) self] in self.evaluate() },
                equals: { [unowned(unsafe) self] old, new in
                    if equals(old, new) { return true }
                    self.markChanged()
                    return false
                }
            )
        } else {
            alwaysChanges = true
            computed = Computed { [unowned(unsafe) self] in self.evaluate() }
        }
    }

    @inlinable
    override var hasValue: Bool { hasRun || output != nil }

    @inlinable
    func compute() -> Value { fatalError("abstract") }

    @inlinable
    final func evaluate() -> Value {
        let saved = currentRule
        currentRule = self
        defer { currentRule = saved }

        prevRun = lastRun
        let value: Value
        if usesInitialValue {
            usesInitialValue = false
            value = output!
        } else {
            value = compute()
        }
        if alwaysChanges || !hasRun { markChanged() }
        hasRun = true
        lastRun = epoch
        bodyWasModified = false
        return value
    }

    @inlinable
    override func read() -> Value {
        computed.value
    }

    @inlinable
    override func write(_ value: Value) -> Bool {
        precondition(!hasValue, "can only set initial value of computed attributes: \(AnyAttribute(node: self))")
        markChanged()
        output = value
        usesInitialValue = true
        return true
    }

    // AttributeGraph counts it as a body modification (`currentWasModified`)
    @inlinable
    override func invalidateValue() {
        bodyWasModified = true
        computed.invalidate()
    }
}

@usableFromInline
final class RuleNode<Body, Value>: DerivedNode<Value> {
    @usableFromInline
    @exclusivity(unchecked)
    var body: Body
    @usableFromInline
    let run: (RuleNode) -> Value

    @inlinable
    init(
        subgraph: Subgraph,
        body: Body,
        initialValue: Value?,
        equals: ((Value, Value) -> Bool)?,
        run: @escaping (RuleNode) -> Value
    ) {
        self.body = body
        self.run = run
        super.init(subgraph: subgraph, equals: equals)
        output = initialValue
        usesInitialValue = initialValue != nil
    }

    @inlinable
    override func compute() -> Value {
        run(self)
    }
}

@usableFromInline
protocol BodyMutating: AnyObject {
    func mutateBody<B>(as type: B.Type, invalidating: Bool, _ mutator: (inout B) -> Void)
}

extension RuleNode: BodyMutating {
    @inlinable
    func mutateBody<B>(as type: B.Type, invalidating: Bool, _ mutator: (inout B) -> Void) {
        precondition(B.self == Body.self, "attribute body is \(Body.self), not \(B.self)")
        withUnsafeMutablePointer(to: &body) { pointer in
            pointer.withMemoryRebound(to: B.self, capacity: 1) { mutator(&$0.pointee) }
        }
        if invalidating { invalidateValue() }
    }
}

@usableFromInline
final class IndirectNode<Value>: DerivedNode<Value> {
    @usableFromInline
    let initialSource: AnyAttribute
    @usableFromInline
    let source: Signal<AnyAttribute>
    @usableFromInline
    @exclusivity(unchecked)
    var dependency: AnyAttribute?

    @inlinable
    init(subgraph: Subgraph, source: AnyAttribute, equals: ((Value, Value) -> Bool)?) {
        initialSource = source
        self.source = Signal(source)
        super.init(subgraph: subgraph, equals: equals)
    }

    @inlinable
    override func compute() -> Value {
        unsafeDowncast(source.value.node, to: ValueNode<Value>.self).read()
    }

    @inlinable
    override func write(_ value: Value) -> Bool {
        preconditionFailure("non-direct attribute id: \(AnyAttribute(node: self))")
    }
}
