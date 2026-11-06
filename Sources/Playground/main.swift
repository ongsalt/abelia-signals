import AbeliaSignals

let a = Signal(1)
let b = Signal(1)

let c = Computed {
    a.value + b.value
}


// effect with no scope WILL be dropped
let e1 = Effect(flushing: .immediate) {
    print("[immediate] \(c.value)")
}

let e2 = Effect {
    print("[isolated] \(c.value)")
}

let scheduler = FlushScheduler()
let e3 = Effect(flushing: .manual(scheduler)) {
    print("[manual] \(c.value)")
}

Task {
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(3))
        print("[scheduler] flush")
        scheduler.flush()
    }
}

Task {
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(1))
        a.value += 1
        print("[a] a = \(a.value)")
    }
}

try await Task.sleep(for: .seconds(10))
