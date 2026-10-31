// Schedules effect re-runs. Tracking state is thread-local (see System.swift).
public final class Runtime {
    // the default runs on the main actor, like UI code
    @TaskLocal
    private static var _current = TrustMe(value: Runtime(unsafeIsolation: MainActor.shared))
    public static var current: Runtime { _current.value }

    // Effects re-run in one batched flush per turn, never synchronously on write.
    // The flush goes to `schedule` if set, else a Task on `isolation`; with
    // neither, call flush() yourself. `schedule` is called mid-write, so it must
    // not flush synchronously.
    public let isolation: (any Actor)?

    public var schedule: ((@escaping () -> Void) -> Void)?

    // owns effects created outside any effect or scope
    lazy var rootScope = EffectScope(runtime: self, detached: true)

    @exclusivity(unchecked) private var queued: [Effect?] = []
    @exclusivity(unchecked) private var queuedLength = 0
    @exclusivity(unchecked) private var notifyIndex = 0
    @exclusivity(unchecked) private var isFlushScheduled = false

    public init(isolation: isolated (any Actor)? = #isolation) {
        self.isolation = isolation
    }

    // for the default, which can't be created on the actor it uses
    private init(unsafeIsolation: (any Actor)?) {
        self.isolation = unsafeIsolation
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
