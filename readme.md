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

```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 5.0 ns       4.9 ns       9956941
prim/signal peek                             4.3 ns       4.2 ns       11477040
prim/signal read (tracked, 1×)               53.8 ns      53.2 ns      927359
prim/signal read (tracked, same ×100)        54.2 ns      52.2 ns      907946
prim/signal write (same value, equals cutoff) 11.9 ns      11.9 ns      3613410
prim/signal write (0 subscribers)            47.2 ns      47.0 ns      1029645
prim/signal write (1 subscribers)            171.2 ns     170.8 ns     291695
prim/signal write (10 subscribers)           1.4 µs       1.3 µs       36575
prim/signal write (100 subscribers)          13.1 µs      13.0 µs      3801
prim/create Signal                           50.4 ns      49.1 ns      985616
prim/create Computed + first read            553.0 ns     529.5 ns     105124
prim/create Effect.immediate                 439.3 ns     399.7 ns     144967
shape/deep chain ×10                         54.6 ns      52.5 ns      939095
shape/deep chain ×100                        54.6 ns      54.1 ns      906056
shape/deep chain ×1000                       54.6 ns      53.8 ns      917338
shape/fan-out 1→1000 computeds (read all)    6.7 µs       6.6 µs       6416
shape/fan-out 1→1000 effects (immediate)     232.7 µs     229.0 µs     215
shape/fan-in 1000→1 (write one)              75.1 ns      73.5 ns      416707
shape/diamond 1→2→1                          55.9 ns      54.2 ns      789492
shape/wide diamond 1→100→1                   55.4 ns      54.9 ns      900535
shape/layered grid 10×100                    743.7 ns     741.3 ns     66850
shape/dynamic deps (switch 50↔50)            53.3 ns      52.7 ns      927397
```

## alien-signals (bun)
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
swift run -c release Benchmark [check|<filter>]   # Swift
cd bench-js && npm i && npm run bench             # same suite on alien-signals (Node)
cd bench-js && npm run bench:bun                  # ... or Bun
```

# Todo
- effect disposal and `onDispose`
- threadlocal c shim

## Bugs
- `Effect.immediate` see glitched state
-  The same dependency is tracked more than once
- `.maybe` state never short-circuits

## Optimization
- spam `@inlinable`, `@usableFromInline`, `@exclusivity(unchecked)`
- [alien signals](https://github.com/stackblitz/alien-signals) style dependency link

## qol
- propertyWrapper: `@Computed` property in a class that reference non signal field will make lifetime painful
- observation
- some kind of ordering gaurantee?