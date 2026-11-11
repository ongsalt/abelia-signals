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
- **alien-signals (node)**: the original, via `bench-js/`
- v1 (`Signal` / `Computed` / `Effect`) and the alien-signals Swift port are listed further down, from an older run

| case | v2 | Compute | alien (node) |
|---|---|---|---|
| signal read (untracked) | 2.6 ns | 19.9 ns | 2.4 ns |
| signal peek | 1.4 ns | — | 6 ns |
| signal read (tracked, 1×) | 66.2 ns | 310.2 ns | 39.9 ns |
| signal read (tracked, same ×100) | 156.3 ns | 2.5 µs | 265.5 ns |
| signal write (same value, equals cutoff) | 9.5 ns | 40.4 ns | 5.9 ns |
| signal write (0 subscribers) | 25.1 ns | 149.0 ns | 14.9 ns |
| signal write (1 subscribers) | 37.7 ns | 158.4 ns | 38.8 ns |
| signal write (10 subscribers) | 44.0 ns | 244.5 ns | 76.5 ns |
| signal write (100 subscribers) | 116.4 ns | 1.1 µs | 431.7 ns |
| create Signal | 46.2 ns | — | 15.4 ns |
| create Computed + first read | 174.9 ns | — | 369.1 ns |
| create Effect.immediate | 130.8 ns | — | 49 ns |
| deep chain ×10 | 472.6 ns | 1.5 µs | 332.7 ns |
| deep chain ×100 | 3.5 µs | 12.9 µs | 3.6 µs |
| deep chain ×1000 | 33.6 µs | 125.5 µs | 41.3 µs |
| fan-out 1→1000 computeds (read all) | 32.5 µs | 158.2 µs | 31.3 µs |
| fan-out 1→1000 effects (immediate) | 34.7 µs | — | 33.8 µs |
| fan-in 1000→1 (write one) | 12.9 µs | 197.2 µs | 13.1 µs |
| diamond 1→2→1 | 204.0 ns | 607.7 ns | 118.9 ns |
| wide diamond 1→100→1 | 4.5 µs | 26.7 µs | 4.4 µs |
| layered grid 10×100 | 3.9 µs | 14.0 µs | 4.4 µs |
| dynamic deps (switch 50↔50) | 2.4 µs | 14.8 µs | 1.9 µs |

- v2 vs alien (node): faster on wide writes (10/100 subscribers), deep chain ×1000, layered grid and repeated reads; about even on fan-out, fan-in and wide diamond; still behind on fixed per-operation cost: single tracked read / small diamond / same-value write ~1.6–1.7×, write with 0 subscribers 1.7×, create signal/effect ~3×

## v2
```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 2.6 ns       2.5 ns       19258462
prim/signal peek                             1.4 ns       1.4 ns       35429230
prim/signal read (tracked, 1×)               66.2 ns      65.9 ns      734313
prim/signal read (tracked, same ×100)        156.3 ns     151.4 ns     318091
prim/signal write (same value, equals cutoff) 9.5 ns       9.4 ns       5277638
prim/signal write (0 subscribers)            25.1 ns      24.6 ns      2027677
prim/signal write (1 subscribers)            37.7 ns      36.5 ns      1348306
prim/signal write (10 subscribers)           44.0 ns      42.9 ns      1137783
prim/signal write (100 subscribers)          116.4 ns     112.8 ns     428963
prim/create Signal                           46.2 ns      45.8 ns      1050129
prim/create Computed + first read            174.9 ns     173.0 ns     286976
prim/create Effect.immediate                 130.8 ns     130.0 ns     378306
shape/deep chain ×10                         472.6 ns     469.3 ns     103250
shape/deep chain ×100                        3.5 µs       3.4 µs       14547
shape/deep chain ×1000                       33.6 µs      32.0 µs      1487
shape/fan-out 1→1000 computeds (read all)    32.5 µs      31.5 µs      1539
shape/fan-out 1→1000 effects (immediate)     34.7 µs      34.4 µs      1437
shape/fan-in 1000→1 (write one)              12.9 µs      12.6 µs      3838
shape/diamond 1→2→1                          204.0 ns     201.9 ns     250338
shape/wide diamond 1→100→1                   4.5 µs       4.4 µs       11195
shape/layered grid 10×100                    3.9 µs       3.9 µs       12987
shape/dynamic deps (switch 50↔50)            2.4 µs       2.4 µs       20679
```

## Compute
```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 19.9 ns      19.6 ns      2531668
prim/signal read (tracked, 1×)               310.2 ns     308.7 ns     159269
prim/signal read (tracked, same ×100)        2.5 µs       2.5 µs       19663
prim/signal write (same value, equals cutoff) 40.4 ns      40.0 ns      1221974
prim/signal write (0 subscribers)            149.0 ns     141.0 ns     359349
prim/signal write (1 subscribers)            158.4 ns     156.1 ns     322960
prim/signal write (10 subscribers)           244.5 ns     243.0 ns     204979
prim/signal write (100 subscribers)          1.1 µs       1.1 µs       44653
shape/deep chain ×10                         1.5 µs       1.5 µs       34236
shape/deep chain ×100                        12.9 µs      12.8 µs      3880
shape/deep chain ×1000                       125.5 µs     125.0 µs     398
shape/fan-out 1→1000 computeds (read all)    158.2 µs     157.6 µs     315
shape/fan-in 1000→1 (write one)              197.2 µs     195.4 µs     254
shape/diamond 1→2→1                          607.7 ns     603.8 ns     82473
shape/wide diamond 1→100→1                   26.7 µs      26.6 µs      1873
shape/layered grid 10×100                    14.0 µs      13.9 µs      3586
shape/dynamic deps (switch 50↔50)            14.8 µs      14.8 µs      3383
```

## alien-signals (node)
holy shit
```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 2.4 ns       2.4 ns       20573519
prim/signal peek                             6 ns         5.9 ns       7829346
prim/signal read (tracked, 1×)               39.9 ns      39.6 ns      1262974
prim/signal read (tracked, same ×100)        265.5 ns     262.1 ns     187849
prim/signal write (same value, equals cutoff) 5.9 ns       5.3 ns       8486473
prim/signal write (0 subscribers)            14.9 ns      14.8 ns      3350448
prim/signal write (1 subscribers)            38.8 ns      38.4 ns      1207778
prim/signal write (10 subscribers)           76.5 ns      75.5 ns      637665
prim/signal write (100 subscribers)          431.7 ns     417.7 ns     112262
prim/create Signal                           15.4 ns      13.1 ns      3220777
prim/create Computed + first read            369.1 ns     123.7 ns     401919
prim/create Effect.immediate                 49 ns        43.7 ns      120855
shape/deep chain ×10                         332.7 ns     328.2 ns     137784
shape/deep chain ×100                        3.6 µs       3.6 µs       12824
shape/deep chain ×1000                       41.3 µs      40.7 µs      1296
shape/fan-out 1→1000 computeds (read all)    31.3 µs      31 µs        1600
shape/fan-out 1→1000 effects (immediate)     33.8 µs      33 µs        1560
shape/fan-in 1000→1 (write one)              13.1 µs      12.9 µs      2820
shape/diamond 1→2→1                          118.9 ns     113.7 ns     422034
shape/wide diamond 1→100→1                   4.4 µs       4.4 µs       10447
shape/layered grid 10×100                    4.4 µs       4.3 µs       11557
shape/dynamic deps (switch 50↔50)            1.9 µs       1.9 µs       25202
```

## older runs (not rerun since)
### v1
```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 2.8 ns       2.8 ns       14252346
prim/signal peek                             1.4 ns       1.4 ns       36193885
prim/signal read (tracked, 1×)               337.1 ns     336.2 ns     147430
prim/signal read (tracked, same ×100)        3.1 µs       3.1 µs       16428
prim/signal write (same value, equals cutoff) 3.1 ns       3.0 ns       16175289
prim/signal write (0 subscribers)            31.9 ns      31.8 ns      1565802
prim/signal write (1 subscribers)            158.4 ns     158.1 ns     315344
prim/signal write (10 subscribers)           1.3 µs       1.3 µs       37743
prim/signal write (100 subscribers)          13.0 µs      13.0 µs      3880
prim/create Signal                           21.4 ns      21.3 ns      2338240
prim/create Computed + first read            617.9 ns     547.7 ns     105089
prim/create Effect.immediate                 494.0 ns     430.6 ns     136549
shape/deep chain ×10                         7.0 µs       7.0 µs       7181
shape/deep chain ×100                        79.9 µs      78.8 µs      635
shape/deep chain ×1000                       816.3 µs     813.4 µs     60
shape/fan-out 1→1000 computeds (read all)    320.8 µs     320.0 µs     155
shape/fan-out 1→1000 effects (immediate)     222.5 µs     218.3 µs     229
shape/fan-in 1000→1 (write one)              38.1 µs      38.0 µs      1319
shape/diamond 1→2→1                          1.4 µs       1.4 µs       34590
shape/wide diamond 1→100→1                   65.4 µs      64.8 µs      759
shape/layered grid 10×100                    89.4 µs      89.0 µs      550
shape/dynamic deps (switch 50↔50)            12.3 µs      12.3 µs      4049
```

### alien-signals (naive swift port)
`Benchmarks/Sources/AlienSignals`, a line-by-line port in plain Swift (no `Unmanaged`, `@inlinable` or `@exclusivity`)
```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 12.6 ns      12.3 ns      3835614
prim/signal peek                             12.0 ns      11.7 ns      3966973
prim/signal read (tracked, 1×)               359.9 ns     350.8 ns     142635
prim/signal read (tracked, same ×100)        2.3 µs       2.2 µs       21692
prim/signal write (same value, equals cutoff) 17.1 ns      17.0 ns      2911377
prim/signal write (0 subscribers)            87.8 ns      87.3 ns      570039
prim/signal write (1 subscribers)            121.5 ns     121.4 ns     414347
prim/signal write (10 subscribers)           327.0 ns     324.1 ns     153513
prim/signal write (100 subscribers)          2.5 µs       2.4 µs       21043
prim/create Signal                           28.3 ns      28.3 ns      1763890
prim/create Computed + first read            217.0 ns     216.3 ns     228795
prim/create Effect.immediate                 135.6 ns     134.6 ns     368131
shape/deep chain ×10                         3.0 µs       2.9 µs       17266
shape/deep chain ×100                        29.3 µs      29.1 µs      1692
shape/deep chain ×1000                       294.7 µs     293.5 µs     166
shape/fan-out 1→1000 computeds (read all)    231.1 µs     228.9 µs     207
shape/fan-out 1→1000 effects (immediate)     150.1 µs     149.1 µs     335
shape/fan-in 1000→1 (write one)              35.8 µs      34.5 µs      1488
shape/diamond 1→2→1                          947.6 ns     933.7 ns     53499
shape/wide diamond 1→100→1                   28.5 µs      28.1 µs      1751
shape/layered grid 10×100                    27.6 µs      27.5 µs      1818
shape/dynamic deps (switch 50↔50)            5.8 µs       5.8 µs       8635
```

## Running it
```sh
cd Benchmarks                                          # separate SwiftPM package
swift run -c release BenchmarkV2 [check|<filter>]      # v2
swift run -c release Benchmark [check|<filter>]        # v1
swift run -c release BenchmarkAlien [check|<filter>]   # alien-signals swift port, same suite
swift run -c release BenchmarkCompute [check|<filter>] # Compute subset, see Package.swift for build flags
cd bench-js && npm i && npm run bench             # same suite on alien-signals (Node)
cd bench-js && npm run bench:bun                  # ... or Bun
```

# Todo
- effect disposal and `onDispose`
- threadlocal c shim

## Bugs
- `Effect.immediate` see glitched state. So we still need to batch this: wrap around signal mutation call. then `batch {}` is neutral.
    - also need to filter out dead sink

## Optimization
- plain struct + pointer, non recursive propagation
- `.maybe` edge versioning
- `@exclusivity(unchecked)`: partly done
- [alien signals](https://github.com/stackblitz/alien-signals) style dependency link


## qol
- propertyWrapper: `@Computed` property in a class that reference non signal field will make lifetime painful
- observation
- some kind of ordering gaurantee?
