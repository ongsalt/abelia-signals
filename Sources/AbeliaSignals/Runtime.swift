import Synchronization

// effect flushing is kinda like `queueMicrotask`

public class FlushScheduler {
    public var onFlushNeeded: (() -> Void) -> Void
    var hasPendingFlush: Bool = false
    var pending: [Effect] = []

    // the callback passed in is `flush`. Schedule it as you see fit
    public init(onFlushNeeded: @escaping (() -> Void) -> Void = { _ in}) {
        self.onFlushNeeded = onFlushNeeded
    }

    func add(_ effect: Effect) {
        pending.append(effect)

        if !hasPendingFlush {
            hasPendingFlush = true
            onFlushNeeded(flush)
        }
    }

    public func flush() {
        hasPendingFlush = false
        for effect in pending {
            effect.rerun()
        }
        pending = []
    }
}

public enum Flushing {
    /// Effect rerun in actor isolation. Current context must be isolated.
    case isolated

    /// Create a `FlushScheduler` then call `flush` yourself
    case manual(FlushScheduler)

    /// `Effect` will run immediately
    case immediate

    /// Inherit from `EffectScope`
    case inherit

    /// `.inherit` then `.isolated`
    case `default`

    func resolve(_ isolation: any Actor?) -> FlushingStrategy {
        switch self {
        case .default:
            if let currentEffectScope {
                return currentEffectScope.flushingStrategy
            } else if let isolation {
                return .isolated(isolation)
            } else {
                fatalError(
                    "Current context is not isolated and there is no surrounding `EffectScope`. Try explicitly specify the `flushing` option or make a surrounding scope"
                )
            }
        case .isolated:
            guard let isolation else {
                fatalError("flushing: .isolated is usable only in an isolated context.")
            }
            return .isolated(isolation)
        case .manual(let scheduler):
            return .manual(scheduler)
        case .immediate:
            return .immediate
        case .inherit:
            guard let currentEffectScope else {
                fatalError("Can not inherit isolation: Parent scope not found.")
            }
            return currentEffectScope.flushingStrategy
        }
    }
}

public enum FlushingStrategy {
    case isolated(any Actor)
    case manual(FlushScheduler)
    case immediate
}

extension FlushingStrategy {
    func schedule(_ effect: Effect) {
        switch self {
        case .immediate:
            effect.rerun()
        case .isolated(let actor):
            scheduleFlush(effect, on: actor)
            break
        case .manual(let scheduler):
            scheduler.add(effect)
        }
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

private func scheduleFlush(_ effect: Effect, on isolation: any Actor) {
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
                    effect.rerun()
                }
            }
        }
    }

}

@inline(__always)
func runOnActor<A: Actor>(_ actor: isolated A, operation: () -> Void) {
    operation()
}
// MARK: threadlocal

nonisolated(unsafe) var currentSink: Sink?
nonisolated(unsafe) var currentEffectScope: EffectOwner?
