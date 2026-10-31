// Prints "<case>\t<ns per op>" lines; run.sh compares them with js/bench.mjs.
// Pass a case name to run just that one, e.g. for profiling.
import AbeliaSignals

nonisolated(unsafe) var sink = 0
let filter = CommandLine.arguments.dropFirst().first

// calibrate to ~100ms per sample, 5 samples, median ns/op
func bench(_ name: String, opsPerRun: Int = 1, _ make: () -> (() -> Void, () -> Void)) {
    if let filter, name != filter { return }
    let (run, teardown) = make()
    let clock = ContinuousClock()
    var iters = 1
    while true {
        let t = clock.measure { for _ in 0..<iters { run() } }
        if t >= .milliseconds(100) || iters >= 1 << 30 { break }
        iters *= 2
    }
    var samples: [Double] = []
    for _ in 0..<5 {
        let t = clock.measure { for _ in 0..<iters { run() } }
        let ns = Double(t.components.seconds) * 1e9 + Double(t.components.attoseconds) / 1e9
        samples.append(ns / Double(iters * opsPerRun))
    }
    teardown()
    samples.sort()
    print("\(name)\t\(samples[2])")
}

let scheduler = EffectScheduler()
scheduler.schedule = { _ in }

scheduler.run {
    for w in [1, 10, 100] {
        for h in [1, 10, 100] {
            bench("propagate \(w)x\(h)") {
                let src = Signal(1)
                let scope = EffectScope()
                scope.run {
                    for _ in 0..<w {
                        var last = Computed { src.value }
                        for _ in 1..<max(h, 1) {
                            let prev = last
                            last = Computed { prev.value + 1 }
                        }
                        let tail = last
                        effect { sink &+= tail.value }
                    }
                }
                return ({
                    src.value = src.peek + 1
                    scheduler.flush()
                }, { scope.stop() })
            }
        }
    }

    bench("create signal+computed+effect (x1000)", opsPerRun: 1000) {
        ({
            let scope = EffectScope()
            scope.run {
                for i in 0..<1000 {
                    let s = Signal(i)
                    let c = Computed { s.value * 2 }
                    effect { sink &+= c.value }
                }
            }
            scope.stop()
        }, {})
    }

    bench("dynamic deps: swap 50 of 100") {
        let sources = (0..<100).map { Signal($0) }
        let which = Signal(0)
        let scope = EffectScope()
        scope.run {
            effect {
                let w = which.value
                var sum = 0
                for i in stride(from: w, to: 100, by: 2) { sum &+= sources[i].value }
                sink &+= sum
            }
        }
        return ({
            which.value = 1 - which.peek
            scheduler.flush()
        }, { scope.stop() })
    }

    bench("read cached computed (x1000)", opsPerRun: 1000) {
        let s = Signal(1)
        let c = Computed { s.value * 2 }
        return ({
            for _ in 0..<1000 { sink &+= c.value }
        }, {})
    }
}
print("sink\t\(sink)")
