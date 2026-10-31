// Schedules effect re-runs and owns top-level effects, which don't keep it alive.
public final class Runtime {
    // task-local so nonisolated sync code sees it too. set only by run()
    @TaskLocal
    private static var _current = TrustMe<Runtime?>(value: nil)
    public static var current: Runtime {
        guard let runtime = _current.value else {
            preconditionFailure(
                "No current Runtime. Create effects, scopes and observing computeds inside runtime.run { }")
        }
        return runtime
    }

    // flushes go to `schedule`, else a Task on `isolation`, else call flush().
    // `schedule` is called mid-write, so it must not flush synchronously.
    public var isolation: (any Actor)? { retainedIsolation ?? owner }
    private let retainedIsolation: (any Actor)?
    // weak: the owner holds the runtime
    private weak var owner: (any Actor)?

    @exclusivity(unchecked) public var schedule: ((@escaping () -> Void) -> Void)?

    // owns effects created outside any effect or scope
    lazy var rootScope = EffectScope(runtime: self, detached: true)

    // what effects and scopes point at instead of the runtime itself
    let handle = RuntimeHandle()
    // through the handle, so it doesn't keep the runtime alive
    private let scheduledFlush: () -> Void

    @exclusivity(unchecked) private var queued: [Effect?] = []
    @exclusivity(unchecked) private var queuedLength = 0
    @exclusivity(unchecked) private var notifyIndex = 0
    @exclusivity(unchecked) private var isFlushScheduled = false

    public convenience init(isolation: isolated (any Actor)? = #isolation) {
        self.init(isolation: isolation, owner: nil)
    }

    // for an actor to store: `lazy var runtime = Runtime(owner: self)`
    public convenience init(owner: isolated any Actor) {
        self.init(isolation: nil, owner: owner)
    }

    private init(isolation: (any Actor)?, owner: (any Actor)?) {
        retainedIsolation = isolation
        self.owner = owner
        scheduledFlush = { [handle] in handle.runtime?._withUnsafeGuaranteedRef { $0.flush() } }
        handle.runtime = .passUnretained(self)
    }

    deinit { handle.runtime = nil }

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
            schedule(scheduledFlush)
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

// Cleared when the runtime is freed. Not a weak ref: those put the runtime's
// refcount on the slow path.
final class RuntimeHandle {
    @exclusivity(unchecked) var runtime: Unmanaged<Runtime>?
}

struct TrustMe<T>: @unchecked Sendable {
    var value: T
}
