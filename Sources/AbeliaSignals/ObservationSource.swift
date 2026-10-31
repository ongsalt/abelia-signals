import Observation
import Synchronization

extension Computed {
    /// tracks @Observable properties
    public static func observing(
        equals isEqual: @escaping (Value, Value) -> Bool, _ compute: @escaping () -> Value
    ) -> Computed {
        let tracker = ObservationTracker(isolation: Runtime.current.isolation)
        let computed = Computed(equals: isEqual) { tracker.track(compute) }
        tracker.node = computed
        return computed
    }

    public static func observing(_ compute: @escaping () -> Value) -> Computed {
        observing(equals: { _, _ in false }, compute)
    }
}

extension Computed where Value: Equatable {
    public static func observing(_ compute: @escaping () -> Value) -> Computed {
        observing(equals: ==, compute)
    }
}

// Only touched on the runtime's isolation; onChange just schedules onto it.
private final class ObservationTracker: @unchecked Sendable {
    weak var node: ReactiveNode?
    // non-Sendable so it inherits `isolation`; a @Sendable closure wouldn't
    private var invalidateOnIsolation: TrustMe<@isolated(any) () async -> Void>?
    // bumped per track(). a registration can't be cancelled until it fires, so
    // ones from earlier computes cancel themselves without invalidating
    private let generation = Atomic<UInt64>(0)

    init(isolation: (any Actor)?) {
        guard let isolation else { return }
        invalidateOnIsolation = isolation.assumeIsolated { isolation in
            // weak: stored on self
            let invalidate: @isolated(any) () async -> Void = { [weak self] in
                _ = isolation
                self?.invalidate()
            }
            precondition(invalidate.isolation === isolation)
            return TrustMe(value: invalidate)
        }
    }

    func track<Value>(_ compute: () -> Value) -> Value {
        let current = generation.add(1, ordering: .relaxed).newValue
        return withObservationTracking(options: .didSet, compute) { [weak self] event in
            event.cancel()
            guard let self, generation.load(ordering: .relaxed) == current else { return }
            if let invalidateOnIsolation {
                Task.immediate(operation: invalidateOnIsolation.value)
            } else {
                invalidate()
            }
        }
    }

    private func invalidate() {
        guard let node, !node.flags.isEmpty, !node.flags.contains(.dirty) else { return }
        node.flags.insert(.dirty)
        if let subs = node.subsRef { propagate(subs, innerWrite: runDepth != 0) }
    }
}
