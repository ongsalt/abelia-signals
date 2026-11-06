import Synchronization

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
// TODO
nonisolated(unsafe) var currentSink: Sink?
nonisolated(unsafe) var currentEffectScope: EffectOwner?
nonisolated(unsafe) var currentEffectScheduler: EffectScheduler?


public func withEffectScheduler<T>(_ scheduler: EffectScheduler, body: () -> T) -> T {
    let prev = currentEffectScheduler
    currentEffectScheduler = scheduler
    let ret = body()
    currentEffectScheduler = prev
    return ret
}
