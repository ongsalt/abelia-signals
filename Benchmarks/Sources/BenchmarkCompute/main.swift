// The suite's subset that maps onto the AttributeGraph API. Built twice:
//   BenchmarkCompute → Compute (jcmosc's reimplementation)
//   BenchmarkAG      → Apple's AttributeGraph via OpenAttributeGraphShims (macOS only, `-D AG`, symlinked)
// Both expose the same Swift API (Graph, Subgraph, Attribute, Rule), so the code is shared.
// Same case names and harness as Benchmark/BenchmarkAlien so the numbers line up.
//
//   signal   = Attribute(value:)            read/write `.value`
//   computed = Attribute(SomeRule())         inputs are @Attribute fields (or attributes read in `value`)
//
// Skipped: effects (AttributeGraph has none), create benchmarks (attributes live in the
// subgraph until it's invalidated, so creating millions just grows the graph).
//
//   swift run -c release BenchmarkCompute            → checks + all benchmarks
//   swift run -c release BenchmarkCompute check      → checks only
//   swift run -c release BenchmarkCompute <filter>   → benchmarks whose name contains <filter>

#if AG
import OpenAttributeGraphShims

// without the env var the shims build OpenAttributeGraph's own engine, which is still a stub
precondition(
    attributeGraphVendor == .ag,
    "BenchmarkAG isn't linked against Apple's AttributeGraph (vendor: \(attributeGraphVendor.rawValue)); "
        + "build with OPENATTRIBUTEGRAPH_OPENATTRIBUTESHIMS_ATTRIBUTEGRAPH=1"
)
#else
import Compute
#endif

let graph = Graph()
let subgraph = Subgraph(graph: graph)
Subgraph.current = subgraph

// MARK: rules

struct Plus: Rule {
    @Attribute var input: Int
    let k: Int
    var value: Int { input &+ k }
}

struct Times2: Rule {
    @Attribute var input: Int
    var value: Int { input &* 2 }
}

struct Div1000: Rule {
    @Attribute var input: Int
    var value: Int { input / 1000 }
}

struct Sum2: Rule {
    @Attribute var a: Int
    @Attribute var b: Int
    var value: Int { a &+ b }
}

struct SumAll: Rule {
    let inputs: [Attribute<Int>]
    var value: Int { inputs.reduce(0) { $0 &+ $1.value } }
}

struct SameTimes100: Rule {
    @Attribute var input: Int
    var value: Int {
        var acc = 0
        for _ in 0..<100 { acc &+= input }
        return acc
    }
}

struct Switch50: Rule {
    @Attribute var flag: Bool
    let xs: [Attribute<Int>]
    var value: Int {
        let range = flag ? 0..<50 : 50..<100
        return range.reduce(0) { $0 &+ xs[$1].value }
    }
}

final class Counter {
    var runs = 0
}

struct CountedSum2: Rule {
    @Attribute var a: Int
    @Attribute var b: Int
    let counter: Counter
    var value: Int {
        counter.runs += 1
        return a &+ b
    }
}

struct CountedPlus1: Rule {
    @Attribute var input: Int
    let counter: Counter
    var value: Int {
        counter.runs += 1
        return input &+ 1
    }
}

// MARK: checks

func runChecks() {
    var checks: [(String, Int, Int)] = []

    do {
        let a = Attribute(value: 0)
        let b = Attribute(Plus(input: a, k: 1))
        let c = Attribute(Times2(input: a))
        let counter = Counter()
        let d = Attribute(CountedSum2(a: b, b: c, counter: counter))
        blackHole(d.value)
        counter.runs = 0
        a.value &+= 1
        blackHole(d.value)
        checks.append(("diamond: D recomputes once per write", 1, counter.runs))
    }
    do {
        let a = Attribute(value: 0)
        let b = Attribute(Div1000(input: a))
        let counter = Counter()
        let d = Attribute(CountedPlus1(input: b, counter: counter))
        blackHole(d.value)
        counter.runs = 0
        a.value &+= 1
        blackHole(d.value)
        checks.append(("equality cutoff: unchanged B does not recompute D", 0, counter.runs))
    }
    do {
        let a = Attribute(value: 0)
        let counter = Counter()
        let c = Attribute(CountedPlus1(input: a, counter: counter))
        for _ in 0..<10 { a.value &+= 1 }
        blackHole(c)
        checks.append(("lazy: never-read computed does not run", 0, counter.runs))
    }
    do {
        let head = Attribute(value: 0)
        var node = Attribute(Plus(input: head, k: 1))
        for _ in 1..<100 { node = Attribute(Plus(input: node, k: 1)) }
        for _ in 0..<5 {
            head.value &+= 1
            blackHole(node.value)
        }
        checks.append(("still live: deep chain ×100 value after 5 writes", 105, node.value))
    }
    do {
        let a = Attribute(value: 0)
        let b = Attribute(Plus(input: a, k: 1))
        let c = Attribute(Times2(input: a))
        let d = Attribute(Sum2(a: b, b: c))
        for _ in 0..<5 {
            a.value &+= 1
            blackHole(d.value)
        }
        checks.append(("still live: diamond value after 5 writes", 16, d.value))
    }

    print("check                                                                    expected  actual")
    var failed = 0
    for (name, expected, actual) in checks {
        let ok = expected == actual
        if !ok { failed += 1 }
        let padded = name.count >= 72 ? name : name + String(repeating: " ", count: 72 - name.count)
        print("\(ok ? "✓" : "✗") \(padded) \(expected)         \(actual)")
    }
    print("\(checks.count - failed)/\(checks.count) passed\n")
}

// MARK: benchmarks

func registerBenchmarks() {
    benchmark("prim/signal read (untracked)") {
        let s = Attribute(value: 0)
        return { blackHole(s.value) }
    }

    benchmark("prim/signal read (tracked, 1×)") {
        let s = Attribute(value: 0)
        let c = Attribute(Plus(input: s, k: 0))
        return {
            s.value &+= 1
            blackHole(c.value)
        }
    }

    benchmark("prim/signal read (tracked, same ×100)") {
        let s = Attribute(value: 0)
        let c = Attribute(SameTimes100(input: s))
        return {
            s.value &+= 1
            blackHole(c.value)
        }
    }

    benchmark("prim/signal write (same value, equals cutoff)") {
        let s = Attribute(value: 0)
        let c = Attribute(Plus(input: s, k: 0))
        blackHole(c.value)
        return { s.value = 0 }
    }

    for n in [0, 1, 10, 100] {
        benchmark("prim/signal write (\(n) subscribers)") {
            let s = Attribute(value: 0)
            let subs = (0..<n).map { _ in Attribute(Plus(input: s, k: 0)) }
            for c in subs { blackHole(c.value) }
            return {
                s.value &+= 1
                blackHole(subs)
            }
        }
    }

    for depth in [10, 100, 1000] {
        benchmark("shape/deep chain ×\(depth)") {
            let head = Attribute(value: 0)
            var tail = Attribute(Plus(input: head, k: 1))
            for _ in 1..<depth { tail = Attribute(Plus(input: tail, k: 1)) }
            let end = tail
            blackHole(end.value)
            return {
                head.value &+= 1
                blackHole(end.value)
            }
        }
    }

    benchmark("shape/fan-out 1→1000 computeds (read all)") {
        let s = Attribute(value: 0)
        let subs = (0..<1000).map { i in Attribute(Plus(input: s, k: i)) }
        return {
            s.value &+= 1
            for c in subs { blackHole(c.value) }
        }
    }

    benchmark("shape/fan-in 1000→1 (write one)") {
        let sources = (0..<1000).map { Attribute(value: $0) }
        let sum = Attribute(SumAll(inputs: sources))
        blackHole(sum.value)
        var i = 0
        return {
            sources[i].value &+= 1
            i = (i + 1) % 1000
            blackHole(sum.value)
        }
    }

    benchmark("shape/diamond 1→2→1") {
        let a = Attribute(value: 0)
        let b = Attribute(Plus(input: a, k: 1))
        let c = Attribute(Times2(input: a))
        let d = Attribute(Sum2(a: b, b: c))
        blackHole(d.value)
        return {
            a.value &+= 1
            blackHole(d.value)
        }
    }

    benchmark("shape/wide diamond 1→100→1") {
        let a = Attribute(value: 0)
        let mids = (0..<100).map { i in Attribute(Plus(input: a, k: i)) }
        let d = Attribute(SumAll(inputs: mids))
        blackHole(d.value)
        return {
            a.value &+= 1
            blackHole(d.value)
        }
    }

    benchmark("shape/layered grid 10×100") {
        let width = 100
        let sources = (0..<width).map { Attribute(value: $0) }
        var layer = (0..<width).map { i in Attribute(Sum2(a: sources[i], b: sources[(i + 1) % width])) }
        for _ in 1..<10 {
            let prev = layer
            layer = (0..<width).map { i in Attribute(Sum2(a: prev[i], b: prev[(i + 1) % width])) }
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

    // note: AttributeGraph keeps inputs it has seen, so this isn't quite the same
    // semantics as the signals libraries (which drop the stale branch)
    benchmark("shape/dynamic deps (switch 50↔50)") {
        let flag = Attribute(value: true)
        let xs = (0..<100).map { Attribute(value: $0) }
        let c = Attribute(Switch50(flag: flag, xs: xs))
        blackHole(c.value)
        return {
            flag.value.toggle()
            blackHole(c.value)
        }
    }
}

let filter = CommandLine.arguments.dropFirst().first

if filter == nil || filter == "check" {
    runChecks()
}

if filter != "check" {
    registerBenchmarks()
    runBenchmarks(filter: filter)
}
