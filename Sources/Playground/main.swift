import AbeliaSignals

let a = SignalNode(1)

let c = ComputedNode {
    a.value + 1
}

let e2 = EffectNode {
    print("[immediate] c = \(c.value)")
}

Task {
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(1))
        a.value += 1
        print("[a] a = \(a.value)")
    }
}

try await Task.sleep(for: .seconds(10))
