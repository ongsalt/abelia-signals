// Minimal, dependency-free benchmark harness.
// Run with: swift run -c release Benchmark [filter]

@inline(never)
func blackHole<T>(_ x: T) {}

struct BenchmarkCase {
    let name: String
    /// Builds the graph once, returns the closure measured per iteration.
    let setup: () -> () -> Void
}

nonisolated(unsafe) var registry: [BenchmarkCase] = []

func benchmark(_ name: String, setup: @escaping () -> () -> Void) {
    registry.append(BenchmarkCase(name: name, setup: setup))
}

func runBenchmarks(filter: String?) {
    let clock = ContinuousClock()
    let samples = 15
    let targetSampleTime = Duration.milliseconds(50)

    print(pad("benchmark", 44), pad("median", 12), pad("min", 12), "iters/sample")
    for bench in registry where filter.map({ bench.name.contains($0) }) ?? true {
        let op = bench.setup()

        // warmup + calibrate iterations so each sample takes ~targetSampleTime
        var iters = 1
        while true {
            let t = clock.measure { for _ in 0..<iters { op() } }
            if t >= targetSampleTime / 4 || iters >= 1 << 26 { break }
            iters *= 2
        }
        let perSample = max(1, Int(Double(iters) * (targetSampleTime / clock.measure { for _ in 0..<iters { op() } })))

        var results: [Double] = []
        for _ in 0..<samples {
            let t = clock.measure { for _ in 0..<perSample { op() } }
            results.append(nanoseconds(t) / Double(perSample))
        }
        results.sort()
        print(pad(bench.name, 44), pad(format(results[samples / 2]), 12), pad(format(results[0]), 12), perSample)
    }
}

private func nanoseconds(_ d: Duration) -> Double {
    let (s, atto) = d.components
    return Double(s) * 1e9 + Double(atto) / 1e9
}

private func format(_ ns: Double) -> String {
    switch ns {
    case ..<1_000: return "\((ns * 10).rounded() / 10) ns"
    case ..<1_000_000: return "\((ns / 100).rounded() / 10) µs"
    default: return "\((ns / 100_000).rounded() / 10) ms"
    }
}

private func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
