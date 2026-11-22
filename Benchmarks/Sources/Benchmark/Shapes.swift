#if ALIEN
import AlienSignals
#else
import AbeliaSignals
#endif

// MARK: 2. Graph shapes — modeled after js-reactivity-benchmark

func registerShapes() {
    for depth in [10, 100, 1000] {
        benchmark("shape/deep chain ×\(depth)") {
            let head = Signal(0)
            var nodes: [Computed<Int>] = [Computed { head.value &+ 1 }]
            for i in 1..<depth {
                let prev = nodes[i - 1]
                nodes.append(Computed { prev.value &+ 1 })
            }
            let tail = nodes.last!
            blackHole(tail.value)
            return {
                head.value &+= 1
                blackHole(tail.value)
            }
        }
    }

    benchmark("shape/fan-out 1→1000 computeds (read all)") {
        let s = Signal(0)
        let subs = (0..<1000).map { i in Computed { s.value &+ i } }
        return {
            s.value &+= 1
            for c in subs { blackHole(c.value) }
        }
    }

    benchmark("shape/fan-out 1→1000 effects (immediate)") {
        let s = Signal(0)
        var sink = 0
        let effects = (0..<1000).map { _ in Effect.immediate { sink &+= s.value } }
        return {
            s.value &+= 1
            blackHole(effects)
            blackHole(sink)
        }
    }

    benchmark("shape/fan-in 1000→1 (write one)") {
        let sources = (0..<1000).map { Signal($0) }
        let sum = Computed { sources.reduce(0) { $0 &+ $1.value } }
        blackHole(sum.value)
        var i = 0
        return {
            sources[i].value &+= 1
            i = (i + 1) % 1000
            blackHole(sum.value)
        }
    }

    benchmark("shape/diamond 1→2→1") {
        let a = Signal(0)
        let b = Computed { a.value &+ 1 }
        let c = Computed { a.value &* 2 }
        let d = Computed { b.value &+ c.value }
        blackHole(d.value)
        return {
            a.value &+= 1
            blackHole(d.value)
        }
    }

    benchmark("shape/wide diamond 1→100→1") {
        let a = Signal(0)
        let mids = (0..<100).map { i in Computed { a.value &+ i } }
        let d = Computed { mids.reduce(0) { $0 &+ $1.value } }
        blackHole(d.value)
        return {
            a.value &+= 1
            blackHole(d.value)
        }
    }

    // each node reads 2 neighbours from the previous layer; write one source, read last layer
    benchmark("shape/layered grid 10×100") {
        let width = 100
        let sources = (0..<width).map { Signal($0) }
        var layer: [Computed<Int>] = (0..<width).map { i in
            Computed { sources[i].value &+ sources[(i + 1) % width].value }
        }
        for _ in 1..<10 {
            let prev = layer
            layer = (0..<width).map { i in Computed { prev[i].value &+ prev[(i + 1) % width].value } }
        }
        let last = layer
        for c in last { blackHole(c.value) }
        var i = 0
        return {
            sources[i].value &+= 1
            i = (i + 1) % width
            for c in last { blackHole(c.value) }
        }
    }

    // flips between two disjoint sets of 50 dependencies every iteration
    benchmark("shape/dynamic deps (switch 50↔50)") {
        let flag = Signal(true)
        let xs = (0..<100).map { Signal($0) }
        let c = Computed {
            let range = flag.value ? 0..<50 : 50..<100
            return range.reduce(0) { $0 &+ xs[$1].value }
        }
        blackHole(c.value)
        return {
            flag.value.toggle()
            blackHole(c.value)
        }
    }
    // MARK: SwiftUI / AttributeGraph-style: one root read per update, batched writes, churn

    // 1000 dependents read through one root, the way a frame reads its root output once
    benchmark("shape/fan-out 1→1000 via root (one read)") {
        let s = Signal(0)
        let subs = (0..<1000).map { i in Computed { s.value &+ i } }
        let root = Computed { subs.reduce(0) { $0 &+ $1.value } }
        blackHole(root.value)
        return {
            s.value &+= 1
            blackHole(root.value)
        }
    }

    // a transaction: several writes, then one update
    benchmark("shape/batched writes ×10, one read") {
        let sources = (0..<10).map { Signal($0) }
        let mids = sources.map { s in Computed { s.value &* 2 } }
        let root = Computed { mids.reduce(0) { $0 &+ $1.value } }
        blackHole(root.value)
        return {
            withBatch { for s in sources { s.value &+= 1 } }
            blackHole(root.value)
        }
    }

    // build a small subtree reading a long-lived input, read it, throw it away
    benchmark("shape/subgraph churn (build 10, read, drop)") {
        let input = Signal(0)
        return {
            var node = Computed { input.value &+ 1 }
            for _ in 1..<10 {
                let p = node
                node = Computed { p.value &+ 1 }
            }
            blackHole(node.value)
        }
    }

    // MARK: Solid-style: a rendered list, one effect per row (a DOM binding)

    benchmark("solid/create + dispose 1000 rows") {
        return {
            let dispose = makeScope {
                for i in 0..<1000 {
                    let label = Signal(i)
                    _ = Effect.immediate { blackHole(label.value) }
                }
            }
            dispose()
        }
    }

    benchmark("solid/update every 10th row (1000 rows, batched)") {
        let labels = (0..<1000).map { Signal($0) }
        var sink = 0
        let dispose = makeScope {
            for label in labels { _ = Effect.immediate { sink &+= label.value } }
        }
        return {
            withBatch {
                for i in stride(from: 0, to: 1000, by: 10) { labels[i].value &+= 1 }
            }
            blackHole(sink)
            blackHole(dispose)
        }
    }

    // per-row `isSelected` computed: moving the selection reruns 2 effects, not 1000
    benchmark("solid/select row (1000 rows)") {
        let selected = Signal(-1)
        var sink = 0
        let dispose = makeScope {
            for i in 0..<1000 {
                let isSelected = Computed { selected.value == i }
                _ = Effect.immediate { if isSelected.value { sink &+= 1 } }
            }
        }
        var next = 0
        return {
            selected.value = next
            next = (next + 1) % 1000
            blackHole(sink)
            blackHole(dispose)
        }
    }
}

// the two libraries spell batching and scopes differently
#if ALIEN
func withBatch(_ body: () -> Void) {
    startBatch()
    body()
    endBatch()
}

func makeScope(_ body: () -> Void) -> () -> Void {
    let scope = effectScope(body)
    return { scope.dispose() }
}
#else
func withBatch(_ body: () -> Void) {
    batch(body: body)
}

func makeScope(_ body: () -> Void) -> () -> Void {
    let scope = EffectScope()
    scope.run(body)
    return { scope.dispose() }
}
#endif
