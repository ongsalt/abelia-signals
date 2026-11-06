import AbeliaSignals

let a = Signal(1)
let b = Signal(1)

let c = Computed {
    a.value + b.value
}

let e = Effect(flushing: .immediate) {
    print("[immediate] \(c.value)")
}

let d = Effect {
    print("[isolated] \(c.value)")
}

Task {
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(1))
        a.value += 1
        print("a = \(a.value)")
    }
}

try await Task.sleep(for: .seconds(10))

