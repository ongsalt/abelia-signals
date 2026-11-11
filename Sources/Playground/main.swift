import AbeliaSignals

let a = SignalNode(1)
let b = SignalNode(1)

let c = ComputedNode {
    a.value + b.value
}

let e2 = EffectNode {
    print("[immediate] \(c.value)")
}

Task {
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(1))
        a.value += 1
        print("[a] a = \(a.value)")
    }
}

try await Task.sleep(for: .seconds(10))
