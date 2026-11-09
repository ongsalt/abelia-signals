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
Same suite on three implementations (`median`, release build, same machine):
- **abelia**: this library
- **alien-signals (swift)**: `Sources/AlienSignals`, a line-by-line port of alien-signals in plain Swift (no `Unmanaged`, `@inlinable` or `@exclusivity`). Same algorithm, so it shows what the *language* costs
- **alien-signals (node)**: the original, via `bench-js/`

| case | abelia | alien (swift) | alien (node) |
|---|---|---|---|
| signal read (untracked) | 2.8 ns | 12.6 ns | 2.2 ns |
| signal write (0 subscribers) | 31.9 ns | 87.8 ns | 14.6 ns |
| signal write (100 subscribers) | 13.0 µs | 2.5 µs | 427 ns |
| deep chain ×1000 | 816 µs | 295 µs | 37.9 µs |
| fan-out 1→1000 computeds | 321 µs | 231 µs | 31.5 µs |
| diamond 1→2→1 | 1.4 µs | 948 ns | 132 ns |
| wide diamond 1→100→1 | 65.4 µs | 28.5 µs | 4.4 µs |
| layered grid 10×100 | 89.4 µs | 27.6 µs | 4.3 µs |

- abelia / alien (swift) = **algorithm** (same language): ~1.3–3.4×, 5× on wide notify
- alien (swift) / alien (node) = **language** (same algorithm): ~3–8×
- primitives aren't apples to apples: alien reads also commit a pending (batched) write

## abelia
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

## alien-signals (swift port)
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

## alien-signals (node)
holy shit
```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 2.2 ns       2.2 ns       21102772
prim/signal peek                             5.9 ns       5.8 ns       8520182
prim/signal read (tracked, 1×)               39.7 ns      39.6 ns      1248933
prim/signal read (tracked, same ×100)        265 ns       264 ns       188539
prim/signal write (same value, equals cutoff) 5.9 ns       5.9 ns       8349099
prim/signal write (0 subscribers)            14.6 ns      14.5 ns      3347313
prim/signal write (1 subscribers)            38.5 ns      38 ns        1297439
prim/signal write (10 subscribers)           72.6 ns      71.5 ns      684879
prim/signal write (100 subscribers)          427.4 ns     425.6 ns     116912
prim/create Signal                           12.9 ns      12.5 ns      3325943
prim/create Computed + first read            301.6 ns     112.1 ns     367667
prim/create Effect.immediate                 49.8 ns      45.4 ns      138688
shape/deep chain ×10                         341.2 ns     333.7 ns     136990
shape/deep chain ×100                        4 µs         3.9 µs       13130
shape/deep chain ×1000                       37.9 µs      37.3 µs      1281
shape/fan-out 1→1000 computeds (read all)    31.5 µs      31 µs        1612
shape/fan-out 1→1000 effects (immediate)     34.9 µs      33.6 µs      1542
shape/fan-in 1000→1 (write one)              13.4 µs      13.1 µs      2732
shape/diamond 1→2→1                          131.8 ns     123.2 ns     360681
shape/wide diamond 1→100→1                   4.4 µs       4.3 µs       10499
shape/layered grid 10×100                    4.3 µs       4.2 µs       11588
shape/dynamic deps (switch 50↔50)            1.9 µs       1.8 µs       26354
```

## Running it
```sh
swift run -c release Benchmark [check|<filter>]        # abelia
swift run -c release BenchmarkAlien [check|<filter>]   # alien-signals swift port, same suite
cd bench-js && npm i && npm run bench             # same suite on alien-signals (Node)
cd bench-js && npm run bench:bun                  # ... or Bun
```

# Todo
- effect disposal and `onDispose`
- threadlocal c shim

## Bugs
- `Effect.immediate` see glitched state. So we still need to batch this: wrap aroudn signal mutation call. then `batch {}` is neutral.

## Optimization
- ~~spam `@inlinable`, `@usableFromInline`~~ done, only on the typed public API (`value`, `peek`, inits): primitives 1.5–3× faster. Inlining the graph internals too made chains/effects slower
- `@exclusivity(unchecked)`: partly done
- plain struct + pointer
- [alien signals](https://github.com/stackblitz/alien-signals) style dependency link


## qol
- propertyWrapper: `@Computed` property in a class that reference non signal field will make lifetime painful
- observation
- some kind of ordering gaurantee?