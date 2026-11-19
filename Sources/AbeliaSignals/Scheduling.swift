// effect flushing is kinda like `queueMicrotask`

import Synchronization

public final class EffectScheduler {
    public var onFlushNeeded: ((@escaping () -> Void) -> Void)?
    var hasPendingFlush: Bool = false
    var pending: [Effect] = []

    // the callback passed in is `flush`. Schedule it as you see fit
    public init(onFlushNeeded: ((@escaping () -> Void) -> Void)? = nil) {
        self.onFlushNeeded = onFlushNeeded
    }

    @usableFromInline
    func add(_ effect: Effect) {
        pending.append(effect)

        if !hasPendingFlush {
            hasPendingFlush = true
            onFlushNeeded?(flush)
        }
    }

    public func flush() {
        hasPendingFlush = false
        flushPending(in: &pending)
        pending = []
    }
}

public enum Flush {
    // pretty much fallback now
    case isolated(any Actor)
    case scheduler(EffectScheduler)
    case immediate
}

extension Flush {
    @inlinable
    func schedule(_ effect: Effect) {
        switch self {
        case .immediate:
            // in place through the pointer: no copy of the queue
            currentImmediateBatch!.pointee.append(effect)
        case .isolated(let actor):
            fatalError("unimplemented")
            // scheduleFlush(effect, on: actor)
            break
        case .scheduler(let scheduler):
            scheduler.add(effect)
        }
    }
}

// main actor only, so no mutex
@MainActor
let mainEffectScheduler: EffectScheduler = EffectScheduler { flush in
    nonisolated(unsafe) let flush = flush
    Task { @MainActor in
        flush()
    }
}

// MARK: isolation - flush task map

// TODO: no mutex somehow
// [Actor: Set<Effect>]
let pendingTasks: Mutex<TaskMap> = Mutex(TaskMap())

// we need to wrap this in a struct for `Sendable`?
// TODO: investigate whether this is intended or compiler error
struct TaskMap: @unchecked Sendable {
    var map: [ObjectIdentifier: [ObjectIdentifier: Effect]] = [:]
}

func scheduleFlush(_ effect: Effect, on isolation: any Actor) {
    let id = ObjectIdentifier(isolation)
    let effectId = ObjectIdentifier(effect)

    let shouldAddTask = pendingTasks.withLock { taskMap in
        if taskMap.map.keys.contains(id) {
            taskMap.map[id]![effectId] = effect
            return false
        } else {
            taskMap.map[id] = [effectId: effect]
            return true
        }
    }

    if shouldAddTask {
        Task {
            // must yield or we deadlock
            await runOnActor(isolation) {
                // flush everything
                let tasks: [ObjectIdentifier: Effect]? = pendingTasks.withLock { taskMap in
                    if let tasks = taskMap.map[id] {
                        taskMap.map[id] = nil
                        return tasks
                    }
                    return nil
                }

                guard let tasks else { return }
                for effect in tasks.values {
                    effect.runEffect()
                }
            }
        }
    }

}

@inline(__always)
func runOnActor<A: Actor>(_ actor: isolated A, operation: () -> Void) {
    operation()
}

// must be synchronously used
@TaskLocal
var currentEffectScheduler: TrustMeBro<EffectScheduler?> = TrustMeBro(value: nil)

// Never start a non isolated task from this
public func withEffectScheduler<T>(_ scheduler: EffectScheduler, body: () -> T) -> T {
    $currentEffectScheduler.withValue(TrustMeBro(value: scheduler)) {
        body()
    }
}

struct TrustMeBro<T>: @unchecked Sendable {
    let value: T
}
