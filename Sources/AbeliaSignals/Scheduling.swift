// effect flushing is kinda like `queueMicrotask`

public final class EffectScheduler {
    public var onFlushNeeded: ((@escaping () -> Void) -> Void)?
    var hasPendingFlush: Bool = false
    var pending: [Effect] = []

    // the callback passed in is `flush`. Schedule it as you see fit
    public init(onFlushNeeded: ((@escaping () -> Void) -> Void)? = nil) {
        self.onFlushNeeded = onFlushNeeded
    }

    func add(_ effect: Effect) {
        pending.append(effect)

        if !hasPendingFlush {
            hasPendingFlush = true
            onFlushNeeded?(flush)
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

enum Flush {
    // pretty much fallback now
    case isolated(any Actor)
    case scheduler(EffectScheduler)
    case immediate
}

extension Flush {
    func schedule(_ effect: Effect) {
        switch self {
        case .immediate:
            effect.rerun()
        case .isolated(let actor):
            scheduleFlush(effect, on: actor)
            break
        case .scheduler(let scheduler):
            scheduler.add(effect)
        }
    }
}

// main actor only, so no mutex
nonisolated(unsafe) let mainEffectScheduler: EffectScheduler = EffectScheduler { flush in
    nonisolated(unsafe) let flush = flush
    Task { @MainActor in
        flush()
    }
}

