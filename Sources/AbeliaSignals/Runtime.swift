// An actor that owns a Runtime. Effects, scopes and observing computeds made
// on it outside any other effect or scope use this runtime, and are stopped
// when the runtime is freed:
//     let signalsRuntime = Runtime()
public protocol RuntimeOwner: Actor {
    var signalsRuntime: Runtime { get }
}

extension MainActor: RuntimeOwner {
    // the compiler doesn't see `self` as the global main actor
    public var signalsRuntime: Runtime { MainActor.assumeIsolated { TrustMe(value: mainRuntime) }.value }
}

@MainActor private let mainRuntime = Runtime()

// Schedules effect re-runs. Tracking state is thread-local (see System.swift).
// Owns the effects created outside any effect or scope; they don't keep it
// alive, so whoever creates a runtime must hold it.
public final class Runtime {
    // set by run(), for runtimes no actor owns
    @TaskLocal
    private static var _current = TrustMe<Runtime?>(value: nil)

    // the one bound by run(), else the one the caller's actor owns
    public static func current(isolation: isolated (any Actor)? = #isolation) -> Runtime {
        if let runtime = _current.value { return runtime }
        guard let owner = isolation as? any RuntimeOwner else {
            preconditionFailure(
                "No Runtime for \(isolation.map { "\(type(of: $0))" } ?? "nonisolated code"). "
                    + "Conform the actor to RuntimeOwner, or use Runtime.run")
        }
        let runtime = owner.assumeIsolated { TrustMe(value: $0.signalsRuntime) }.value
        // created in a property initializer, so it learns its owner here
        if runtime.isolation == nil {
            runtime.owner = owner
        } else {
            precondition(runtime.isolation === owner, "Runtime is owned by another actor")
        }
        return runtime
    }

    // Effects re-run in one batched flush per turn, never synchronously on write.
    // The flush goes to `schedule` if set, else a Task on `isolation`; with
    // neither, call flush() yourself. `schedule` is called mid-write, so it must
    // not flush synchronously.
    public var isolation: (any Actor)? { retainedIsolation ?? owner }
    private let retainedIsolation: (any Actor)?
    // weak: the owner holds the runtime
    private weak var owner: (any Actor)?

    public var schedule: ((@escaping () -> Void) -> Void)?

    // owns effects created outside any effect or scope
    lazy var rootScope = EffectScope(runtime: self, detached: true)

    @exclusivity(unchecked) private var queued: [Effect?] = []
    @exclusivity(unchecked) private var queuedLength = 0
    @exclusivity(unchecked) private var notifyIndex = 0
    @exclusivity(unchecked) private var isFlushScheduled = false

    // used through run(), or stored by a RuntimeOwner
    public init(isolation: isolated (any Actor)? = #isolation) {
        retainedIsolation = isolation
    }

    @discardableResult
    public func run<R>(_ body: () throws -> R) rethrows -> R {
        try Runtime.$_current.withValue(TrustMe(value: self), operation: body)
    }

    public func flush() {
        isFlushScheduled = true
        while notifyIndex < queuedLength {
            let effect = queued[notifyIndex].take()!
            notifyIndex += 1
            effect.run()
        }
        notifyIndex = 0
        queuedLength = 0
        isFlushScheduled = false
    }

    // queues outer effects first, so a parent re-run disposes its children
    func enqueue(_ first: Effect) {
        var insertIndex = queuedLength
        let firstInsertedIndex = insertIndex
        var effect = NodeRef.passUnretained(first)
        while true {
            let strong = unsafeDowncast(effect.takeUnretainedValue(), to: Effect.self)
            if insertIndex < queued.count {
                queued[insertIndex] = strong
            } else {
                queued.append(strong)
            }
            insertIndex += 1
            effect.flags.remove(.watching)
            guard let parent = effect.subs?.sub, parent.flags.contains(.watching) else { break }
            effect = parent
        }
        queuedLength = insertIndex
        var left = firstInsertedIndex
        var right = insertIndex - 1
        while left < right {
            queued.swapAt(left, right)
            left += 1
            right -= 1
        }

        if isFlushScheduled { return }
        isFlushScheduled = true

        if let schedule {
            schedule { [self] in flush() }
        } else if let isolation {
            let runtime = TrustMe(value: self)
            isolation.assumeIsolated { isolation in
                _ = Task(name: "Effect flush", priority: .high) {
                    _ = isolation
                    runtime.value.flush()
                }
            }
        } else {
            print("Runtime has no isolation and schedule is not set. call flush() to run effects")
        }
    }
}

struct TrustMe<T>: @unchecked Sendable {
    var value: T
}
