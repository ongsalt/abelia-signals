// The suite's subset that maps onto the AttributeGraph API. Built three times:
//   BenchmarkCompute     → Compute (jcmosc's reimplementation)
//   BenchmarkAG          → Apple's AttributeGraph via OpenAttributeGraphShims (macOS only, `-D AG`, symlinked)
//   BenchmarkSignalGraph → SignalGraph, the same API on AbeliaSignals (`-D SIGNALGRAPH`, symlinked)
// All expose the same Swift API (Graph, Subgraph, Attribute, Rule), so the code is shared.
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

#if SIGNALGRAPH
import SignalGraph
#elseif AG
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

// MARK: behavior probes: printed, not checked; diff the output between backends

struct Pick: Rule {
    @Attribute var flag: Bool
    @Attribute var a: Int
    @Attribute var b: Int
    let counter: Counter
    var value: Int {
        counter.runs += 1
        return flag ? a : b
    }
}

final class Log {
    var entries: [String] = []
}

struct WhichChanged: Rule {
    @Attribute var a: Int
    @Attribute var b: Int
    let log: Log
    var value: Int {
        let (av, ac) = context.changedValue(of: $a, options: [])
        let (bv, bc) = context.changedValue(of: $b, options: [])
        log.entries.append(ac || bc ? (ac ? "a" : "") + (bc ? "b" : "") : "-")
        return av &+ bv
    }
}

struct RunningSum: StatefulRule {
    typealias Value = Int
    @Attribute var input: Int
    mutating func updateValue() {
        value = (hasValue ? value : 0) &+ input
    }
}

struct Adder: Rule {
    @Attribute var input: Int
    var k: Int
    let counter: Counter
    var value: Int {
        counter.runs += 1
        return input &+ k
    }
}

struct Untracked: Rule {
    @Attribute var input: Int
    let counter: Counter
    var value: Int {
        counter.runs += 1
        return Graph.withoutUpdate { input }
    }
}

struct Read<T>: Rule {
    @Attribute var input: T
    let counter: Counter
    var value: T {
        counter.runs += 1
        return input
    }
}

struct Pair {
    var a: Int
    var b: Int
}

// not Equatable: POD, and not POD
struct PlainPOD {
    var x: Int
}

struct PlainBoxed {
    var s: String
}

struct ToPlainPOD: Rule {
    @Attribute var input: Int
    var value: PlainPOD { PlainPOD(x: input / 1000) }
}

struct ToPlainBoxed: Rule {
    @Attribute var input: Int
    var value: PlainBoxed { PlainBoxed(s: input < 1000 ? "small" : "big") }
}

struct ToDouble: Rule {
    @Attribute var input: Int
    var value: Double { input >= 0 ? .nan : 0 }
}

func runProbes() {
    var probes: [(String, String)] = []

    do {
        let flag = Attribute(value: true)
        let a = Attribute(value: 1)
        let b = Attribute(value: 2)
        let counter = Counter()
        let c = Attribute(Pick(flag: flag, a: a, b: b, counter: counter))
        blackHole(c.value)
        flag.value = false
        blackHole(c.value)
        counter.runs = 0
        a.value = 10
        blackHole(c.value)
        probes.append(("dynamic deps: write a stale input, reruns", "\(counter.runs)"))
    }
    do {
        let a = Attribute(value: 1)
        let b = Attribute(value: 2)
        let log = Log()
        let c = Attribute(WhichChanged(a: a, b: b, log: log))
        blackHole(c.value)
        b.value = 20
        blackHole(c.value)
        a.value = 10
        b.value = 30
        blackHole(c.value)
        probes.append(("context.changedValue(of:): first, write b, write both", log.entries.joined(separator: " ")))
    }
    do {
        let a = Attribute(value: 0)
        let c = Attribute(Plus(input: a, k: 0))
        let first = c.changedValue().changed
        let again = c.changedValue().changed
        a.value = 1
        let afterWrite = c.changedValue().changed
        a.value = 2
        let external = a.changedValue().changed
        probes.append(("changedValue() outside: first, again, after write", "\(first) \(again) \(afterWrite)"))
        probes.append(("changedValue() outside on a written external", "\(external)"))
    }
    do {
        let a = Attribute(value: 0)
        let same = a.setValue(0)
        let different = a.setValue(1)
        probes.append(("setValue: same, different", "\(same) \(different)"))
    }
    do {
        let a = Attribute(value: 1)
        let sum = Attribute(RunningSum(input: a))
        var seen: [Int] = [sum.value]
        for v in [2, 3] {
            a.value = v
            seen.append(sum.value)
        }
        blackHole(sum.value)
        seen.append(sum.value)
        probes.append(("StatefulRule running sum, reads after writes 2, 3, none", seen.map(String.init).joined(separator: " ")))
    }
    do {
        let a = Attribute(value: 1)
        let counter = Counter()
        let c = Attribute(Adder(input: a, k: 0, counter: counter))
        blackHole(c.value)
        c.mutateBody(as: Adder.self, invalidating: false) { $0.k = 100 }
        let quiet = c.value
        c.mutateBody(as: Adder.self, invalidating: true) { $0.k = 10 }
        let loud = c.value
        probes.append(("mutateBody invalidating: false, then true", "\(quiet) \(loud)"))
    }
    do {
        let a = Attribute(value: 1)
        let counter = Counter()
        let c = Attribute(Untracked(input: a, counter: counter))
        blackHole(c.value)
        counter.runs = 0
        a.value = 2
        blackHole(c.value)
        probes.append(("Graph.withoutUpdate read, reruns after write", "\(counter.runs)"))
    }
    do {
        let pair = Attribute(value: Pair(a: 1, b: 2))
        let counter = Counter()
        let c = Attribute(Read(input: pair.a, counter: counter))
        blackHole(c.value)
        counter.runs = 0
        pair.value.b = 3
        blackHole(c.value)
        let afterB = counter.runs
        pair.value.a = 4
        probes.append(("focus pair.a: reruns after writing b; value after writing a", "\(afterB) \(c.value)"))
    }
    do {
        let x = Attribute(value: 1)
        let y = Attribute(value: 2)
        let indirect = IndirectAttribute(source: x)
        let counter = Counter()
        let c = Attribute(Read(input: indirect.projectedValue, counter: counter))
        let before = c.value
        indirect.source = y
        let switched = c.value
        counter.runs = 0
        x.value = 10
        blackHole(c.value)
        probes.append(("indirect: value, after switch, reruns on old source", "\(before) \(switched) \(counter.runs)"))
    }
    do {
        let prev = Subgraph.current!
        let sub = Subgraph(graph: prev.graph)
        Subgraph.current = sub
        let a = Attribute(value: 7)
        let weak = WeakAttribute(a)
        Subgraph.current = prev
        let before = weak.value.map(String.init) ?? "nil"
        sub.invalidate()
        let after = weak.value.map(String.init) ?? "nil"
        probes.append(("WeakAttribute before, after invalidate; isValid", "\(before) \(after) \(sub.isValid)"))
    }
    do {
        let a = Attribute(value: 0)
        let pod = Attribute(ToPlainPOD(input: a))
        let boxed = Attribute(ToPlainBoxed(input: a))
        let podCounter = Counter()
        let boxedCounter = Counter()
        let c1 = Attribute(Read(input: pod, counter: podCounter))
        let c2 = Attribute(Read(input: boxed, counter: boxedCounter))
        blackHole(c1.value)
        blackHole(c2.value)
        podCounter.runs = 0
        boxedCounter.runs = 0
        a.value = 1
        blackHole(c1.value)
        blackHole(c2.value)
        probes.append(("cutoff, not Equatable: POD reruns, non-POD reruns", "\(podCounter.runs) \(boxedCounter.runs)"))
    }
    do {
        let a = Attribute(value: 0)
        let d = Attribute(ToDouble(input: a))
        let counter = Counter()
        let c = Attribute(Read(input: d, counter: counter))
        blackHole(c.value)
        counter.runs = 0
        a.value = 1
        blackHole(c.value)
        let nanExternal = Attribute(value: Double.nan)
        probes.append(("cutoff, NaN rule output: reruns; NaN external setValue(NaN)", "\(counter.runs) \(nanExternal.setValue(.nan))"))
    }

    print("probe                                                                              observed")
    for (name, observed) in probes {
        let padded = name.count >= 82 ? name : name + String(repeating: " ", count: 82 - name.count)
        print("  \(padded) \(observed)")
    }
    print()
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

    // not a shape SwiftUI builds (rules have few inputs): inputs added dynamically one by one
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

    // MARK: how SwiftUI drives AttributeGraph: one root read per update, batched writes, churn

    benchmark("shape/fan-out 1→1000 via root (one read)") {
        let s = Attribute(value: 0)
        let subs = (0..<1000).map { i in Attribute(Plus(input: s, k: i)) }
        let root = Attribute(SumAll(inputs: subs))
        blackHole(root.value)
        return {
            s.value &+= 1
            blackHole(root.value)
        }
    }

    // no batch API: writes only mark, the read does the one update
    benchmark("shape/batched writes ×10, one read") {
        let sources = (0..<10).map { Attribute(value: $0) }
        let mids = sources.map { Attribute(Times2(input: $0)) }
        let root = Attribute(SumAll(inputs: mids))
        blackHole(root.value)
        return {
            for s in sources { s.value &+= 1 }
            blackHole(root.value)
        }
    }

    // SwiftUI's unit of churn: a subgraph built, read and invalidated
    benchmark("shape/subgraph churn (build 10, read, drop)") {
        let input = Attribute(value: 0)
        let g = Subgraph.current!.graph
        return {
            let sub = Subgraph(graph: g)
            let prev = Subgraph.current
            Subgraph.current = sub
            var node = Attribute(Plus(input: input, k: 1))
            for _ in 1..<10 { node = Attribute(Plus(input: node, k: 1)) }
            blackHole(node.value)
            Subgraph.current = prev
            sub.invalidate()
        }
    }

    // AttributeGraph drops inputs the last run didn't read, like the signals libraries
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
    runProbes()
}

if filter != "check" {
    registerBenchmarks()
    runBenchmarks(filter: filter)
}
