import CAbeliaSignals
import Dispatch

// An actor with its own scheduler. Effects created on it outside any effect or
// scope use it, found from the executor running them, however deep:
//     lazy var effectScheduler = EffectScheduler(owner: self)
public protocol EffectSchedulerOwner: Actor {
    var effectScheduler: EffectScheduler { get }
}

extension MainActor: EffectSchedulerOwner {
    public nonisolated var effectScheduler: EffectScheduler { mainScheduler.value }
}

private let mainScheduler = TrustMe(value: EffectScheduler(isolation: MainActor.shared, owner: nil))

// Schedules effect re-runs and owns top-level effects, which don't keep it alive.
public final class EffectScheduler {
    public static var main: EffectScheduler { mainScheduler.value }

    // the one bound by run(), else the current serial executor's
    public static var current: EffectScheduler {
        if let bound = _current.value { return bound }
        if let found = forCurrentExecutor() { return found }
        preconditionFailure(
            "No EffectScheduler here. Conform the actor to EffectSchedulerOwner, or create "
                + "effects inside scheduler.run { }")
    }

    @TaskLocal
    private static var _current = TrustMe<EffectScheduler?>(value: nil)

    private static func forCurrentExecutor() -> EffectScheduler? {
        let executor = csignals_current_executor()
        let main = unsafeBitCast(MainActor.sharedUnownedExecutor, to: csignals_executor.self)
        guard let identity = executor.identity else {
            return isOnMainExecutor(main) ? mainScheduler.value : nil
        }
        if identity == main.identity { return mainScheduler.value }
        // only a default actor's identity is known to be the actor
        guard executor.implementation == 0 else { return nil }
        let object = Unmanaged<AnyObject>.fromOpaque(identity).takeUnretainedValue()
        guard let owner = object as? any EffectSchedulerOwner else { return nil }
        return owner.assumeIsolated { TrustMe(value: $0.effectScheduler) }.value
    }

    // main-thread code that isn't in a task, like run loop and dispatch callbacks
    private static func isOnMainExecutor(_ main: csignals_executor) -> Bool {
        if csignals_is_current_executor(main) || csignals_is_main_thread() { return true }
        // on Linux, async main hands the main queue to a worker thread
        _ = markMainQueue
        return DispatchQueue.getSpecific(key: mainQueueKey) == true
    }

    // flushes go to `schedule`, else a Task on `isolation`, else call flush().
    // `schedule` is called mid-write, so it must not flush synchronously.
    public var isolation: (any Actor)? { retainedIsolation ?? owner }
    private let retainedIsolation: (any Actor)?
    // the owner holds the scheduler
    private unowned var owner: (any Actor)?

    @exclusivity(unchecked) public var schedule: ((@escaping () -> Void) -> Void)?

    // owns effects created outside any effect or scope
    lazy var rootScope = EffectScope(scheduler: self, detached: true)

    // what effects and scopes point at instead of the scheduler itself
    let handle = SchedulerHandle()
    // through the handle, so it doesn't keep the scheduler alive
    private let scheduledFlush: () -> Void

    @exclusivity(unchecked) private var queued: [Effect?] = []
    @exclusivity(unchecked) private var queuedLength = 0
    @exclusivity(unchecked) private var notifyIndex = 0
    @exclusivity(unchecked) private var isFlushScheduled = false

    public convenience init(isolation: isolated (any Actor)? = #isolation) {
        self.init(isolation: isolation, owner: nil)
    }

    // for an EffectSchedulerOwner to store
    public convenience init(owner: isolated any Actor) {
        self.init(isolation: nil, owner: owner)
    }

    fileprivate init(isolation: (any Actor)?, owner: (any Actor)?) {
        retainedIsolation = isolation
        self.owner = owner
        scheduledFlush = { [handle] in handle.scheduler?._withUnsafeGuaranteedRef { $0.flush() } }
        handle.scheduler = .passUnretained(self)
    }

    deinit { handle.scheduler = nil }

    @discardableResult
    public func run<R>(_ body: () throws -> R) rethrows -> R {
        try EffectScheduler.$_current.withValue(TrustMe(value: self), operation: body)
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
            let scheduler = TrustMe(value: self)
            isolation.assumeIsolated { isolation in
                _ = Task(name: "Effect flush", priority: .high) {
                    _ = isolation
                    scheduler.value.flush()
                }
            }
        } else {
            print("EffectScheduler has no isolation and schedule is not set. call flush() to run effects")
        }
    }
}

// Cleared when the scheduler is freed. Not a weak ref: those put the scheduler's
// refcount on the slow path.
final class SchedulerHandle {
    @exclusivity(unchecked) var scheduler: Unmanaged<EffectScheduler>?
}

struct TrustMe<T>: @unchecked Sendable {
    var value: T
}

private let mainQueueKey = DispatchSpecificKey<Bool>()
private let markMainQueue: Void = DispatchQueue.main.setSpecific(
    key: mainQueueKey, value: true)
