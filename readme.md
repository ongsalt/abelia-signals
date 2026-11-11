# Abelia Signals
Signals implementation in swift.


```swift
let a = Signal(1)
let b = Signal(1)

let c = Computed {
    a.value + b.value
}

// Effect without owner scope will be dropped if not explicitly reference
Effect.immediate {
    print("[immediate] \(c.value)")
}

// this wont
let e = Effect {
    print("[isolated] \(c.value)")
}

let scope = EffectScope()
scope.run {
    // the scope will own this
    Effect {
        print("[owned] \(c.value)")
    }
}

scope.dispose()
```

## Effect flushing
`Effect` initialization must be either isolated or inside `withEffectScheduler` scope. `EffectScope` can provide this if `.preferredScheduler` is set. It is automatically set when the scope is root scope, is isolated and has no `preferredScheduler` passed in.


# Benchmark
Same suite on every implementation (`median`, release build, same machine, on charger):
- **v2**: `Reactivity2.swift` (`SignalNode` / `ComputedNode` / `EffectNode`), struct nodes behind pointers
- **Compute**: [jcmosc/Compute](https://github.com/jcmosc/Compute), an AttributeGraph reimplementation, built with `-O2 -DNDEBUG`. Runs a subset: no effects, no create benchmarks
- **alien-signals (node / bun)**: the original, via `bench-js/` (Node: V8, Bun 1.3.2: JavaScriptCore)
- **v1**: `Reacitivity.swift` (`Signal` / `Computed` / `Effect`), class nodes with weak sinks. Latest known run; the library hasn't changed since

| case | v2 | v1 | Compute | alien (node) | alien (bun) |
|---|---|---|---|---|---|
| signal read (untracked) | 3.1 ns | 3.2 ns | 19.9 ns | 2.4 ns | 3.7 ns |
| signal peek | 1.7 ns | 1.4 ns | — | 6 ns | 4.7 ns |
| signal read (tracked, 1×) | 41.9 ns | 254.0 ns | 310.2 ns | 39.9 ns | 40.2 ns |
| signal read (tracked, same ×100) | 133.7 ns | 3.3 µs | 2.5 µs | 265.5 ns | 272.8 ns |
| signal write (same value, equals cutoff) | 3.8 ns | 3.3 ns | 40.4 ns | 5.9 ns | 3.9 ns |
| signal write (0 subscribers) | 6.5 ns | 19.9 ns | 149.0 ns | 14.9 ns | 8.9 ns |
| signal write (1 subscribers) | 18.3 ns | 93.0 ns | 158.4 ns | 38.8 ns | 26.1 ns |
| signal write (10 subscribers) | 26.2 ns | 764.2 ns | 244.5 ns | 76.5 ns | 49.6 ns |
| signal write (100 subscribers) | 97.4 ns | 7.6 µs | 1.1 µs | 431.7 ns | 331.5 ns |
| create Signal | 48.8 ns | 26.1 ns | — | 15.4 ns | 21.5 ns |
| create Computed + first read | 175.2 ns | 679.4 ns | — | 369.1 ns | 187 ns |
| create Effect.immediate | 134.3 ns | 563.0 ns | — | 49 ns | 55.7 ns |
| deep chain ×10 | 465.8 ns | 5.3 µs | 1.5 µs | 332.7 ns | 313 ns |
| deep chain ×100 | 3.4 µs | 66.5 µs | 12.9 µs | 3.6 µs | 3.2 µs |
| deep chain ×1000 | 33.0 µs | 620.0 µs | 125.5 µs | 41.3 µs | 32.1 µs |
| fan-out 1→1000 computeds (read all) | 27.2 µs | 262.1 µs | 158.2 µs | 31.3 µs | 31.4 µs |
| fan-out 1→1000 effects (immediate) | 30.7 µs | 175.2 µs | — | 33.8 µs | 20.7 µs |
| fan-in 1000→1 (write one) | 6.6 µs | 42.1 µs | 197.2 µs | 13.1 µs | 12.9 µs |
| diamond 1→2→1 | 183.3 ns | 1.2 µs | 607.7 ns | 118.9 ns | 99.6 ns |
| wide diamond 1→100→1 | 4.0 µs | 52.6 µs | 26.7 µs | 4.4 µs | 3.8 µs |
| layered grid 10×100 | 4.0 µs | 69.2 µs | 14.0 µs | 4.4 µs | 4.7 µs |
| dynamic deps (switch 50↔50) | 2.2 µs | 14.6 µs | 14.8 µs | 1.9 µs | 2 µs |

- v2 numbers include the manual exclusivity check on `SignalNode` (an `isUpdating` flag guarding `update`); `_value` itself is `@exclusivity(unchecked)`

## Running it
```sh
swift test                                             # correctness tests (v1 + v2), root package
cd Benchmarks                                          # separate SwiftPM package
swift run -c release BenchmarkV2 [<filter>]            # v2
swift run -c release Benchmark [<filter>]              # v1
swift run -c release BenchmarkAlien [<filter>]         # alien-signals swift port, same suite
swift run -c release BenchmarkCompute [check|<filter>] # Compute subset, see Package.swift for build flags
cd bench-js && npm i && npm run bench             # same suite on alien-signals (Node)
cd bench-js && npm run bench:bun                  # ... or Bun
```

# Todo
- Effect scope
- effect disposal and `onDispose`
- threadlocal c shim

## qol
- propertyWrapper: `@Computed` property in a class that reference non signal field will make lifetime painful
- observation
- some kind of ordering gaurantee?
