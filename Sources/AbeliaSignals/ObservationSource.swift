import Observation
import Synchronization

extension Computed {
    /// tracks @Observable properties
    public static func observing(
        isolation: isolated (any Actor)? = #isolation,
        equals isEqual: @escaping (Value, Value) -> Bool, _ compute: @escaping () -> Value
    ) -> Computed {
        let tracker = ObservationTracker(isolation: isolation)
        let computed = Computed(equals: isEqual) { tracker.track(compute) }
        tracker.node = computed
        return computed
    }

    public static func observing(
        isolation: isolated (any Actor)? = #isolation, _ compute: @escaping () -> Value
    ) -> Computed {
        observing(isolation: isolation, equals: { _, _ in false }, compute)
    }
}

extension Computed where Value: Equatable {
    public static func observing(
        isolation: isolated (any Actor)? = #isolation, _ compute: @escaping () -> Value
    ) -> Computed {
        observing(isolation: isolation, equals: ==, compute)
    }
}

// Only touched on `isolation`; onChange just schedules onto it.
private final class ObservationTracker: @unchecked Sendable {
    weak var node: ReactiveNode?
    // weak: the actor may own the computed
    private weak var isolation: (any Actor)?
    private let isIsolated: Bool
    // bumped per track(). a registration can't be cancelled until it fires, so
    // ones from earlier computes cancel themselves without invalidating
    private let generation = Atomic<UInt64>(0)

    init(isolation: (any Actor)?) {
        self.isolation = isolation
        isIsolated = isolation != nil
    }

    func track<Value>(_ compute: () -> Value) -> Value {
        let current = generation.add(1, ordering: .relaxed).newValue
        return withObservationTracking(options: .didSet, compute) { [weak self] event in
            event.cancel()
            guard let self, generation.load(ordering: .relaxed) == current else { return }
            if !isIsolated {
                invalidate()
            } else if let isolation {
                Task.immediate(operation: makeInvalidate(isolation, self))
            }
        }
    }

    fileprivate func invalidate() {
        guard let node, !node.flags.isEmpty, !node.flags.contains(.dirty) else { return }
        node.flags.insert(.dirty)
        if let subs = node.subs { propagate(subs, innerWrite: runDepth != 0) }
    }
}

// An isolated closure needs the actor captured strongly, and the actor may own
// the computed, so it's built per change rather than stored. Building one
// doesn't run anything on the actor, so off it this does what assumeIsolated
// does, minus the check.
private func makeInvalidate(
    _ isolation: any Actor, _ tracker: ObservationTracker
) -> @isolated(any) () async -> Void {
    let make = unsafeBitCast(
        invalidateClosure as (isolated any Actor, ObservationTracker) -> @isolated(any) () async -> Void,
        to: ((any Actor, ObservationTracker) -> @isolated(any) () async -> Void).self)
    let invalidate = make(isolation, tracker)
    assert(invalidate.isolation === isolation)
    return invalidate
}

private func invalidateClosure(
    _ isolation: isolated any Actor, _ tracker: ObservationTracker
) -> @isolated(any) () async -> Void {
    {
        _ = isolation
        tracker.invalidate()
    }
}
