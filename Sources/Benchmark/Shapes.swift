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
}
