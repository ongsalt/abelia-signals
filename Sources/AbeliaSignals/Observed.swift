import Observation

// Mirrors signals into Observation: observers track `value`, a plain
// @Observable property, never the nodes. `compute` only runs in the effect,
// in a flush, so never inside someone's withObservationTracking. Don't create
// it inside one either: its first run is in init. Freeing it stops the effect.
@Observable
public final class Observed<Value> {
    public private(set) var value: Value
    private let isEqual: (Value, Value) -> Bool
    private let scope: EffectScope

    public init(equals isEqual: @escaping (Value, Value) -> Bool, _ compute: @escaping () -> Value) {
        // the first run is synchronous, before self exists
        let sink = ObservedSink<Value>()
        let scope = EffectScope(detached: true)
        scope.run {
            effect {
                let new = compute()
                if let target = sink.target {
                    target.receive(new)
                } else {
                    sink.initial = new
                }
            }
        }
        value = sink.initial!
        self.isEqual = isEqual
        self.scope = scope
        sink.target = self
    }

    // without Equatable every change is assigned
    public convenience init(_ compute: @escaping () -> Value) {
        self.init(equals: { _, _ in false }, compute)
    }

    private func receive(_ new: Value) {
        if !isEqual(value, new) { value = new }
    }
}

extension Observed where Value: Equatable {
    public convenience init(_ compute: @escaping () -> Value) {
        self.init(equals: ==, compute)
    }
}

// weak: the effect lives in the object's scope
private final class ObservedSink<Value> {
    weak var target: Observed<Value>?
    var initial: Value?
}
