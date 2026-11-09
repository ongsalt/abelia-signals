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

Before using a map for sink list
```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 12.9 ns      12.8 ns      3976115
prim/signal peek                             12.5 ns      12.3 ns      3830220
prim/signal read (tracked, 1×)               597.4 ns     592.4 ns     82527
prim/signal read (tracked, same ×100)        28.4 µs      28.2 µs      1703
prim/signal write (same value, equals cutoff) 19.1 ns      18.8 ns      2567303
prim/signal write (0 subscribers)            40.5 ns      39.8 ns      1192081
prim/signal write (1 subscribers)            136.2 ns     133.8 ns     349601
prim/signal write (10 subscribers)           981.3 ns     966.2 ns     49359
prim/signal write (100 subscribers)          8.3 µs       8.2 µs       5915
prim/create Signal                           50.9 ns      50.3 ns      963782
prim/create Computed + first read            450.7 ns     440.9 ns     99761
prim/create Effect.immediate                 296.7 ns     270.7 ns     163333
shape/deep chain ×10                         6.4 µs       6.3 µs       7772
shape/deep chain ×100                        68.0 µs      67.1 µs      706
shape/deep chain ×1000                       684.3 µs     679.1 µs     70
shape/fan-out 1→1000 computeds (read all)    66.6 ms      65.2 ms      1
shape/fan-out 1→1000 effects (immediate)     67.7 ms      67.0 ms      1
shape/fan-in 1000→1 (write one)              231.0 µs     226.0 µs     214
shape/diamond 1→2→1                          2.4 µs       2.3 µs       20660
shape/wide diamond 1→100→1                   1.0 ms       818.3 µs     47
shape/layered grid 10×100                    94.7 µs      90.8 µs      501
shape/dynamic deps (switch 50↔50)            11.8 µs      11.7 µs      4146
```

after
```
benchmark                                    median       min          iters/sample
prim/signal read (untracked)                 12.1 ns      12.0 ns      4048803
prim/signal peek                             11.6 ns      11.3 ns      4313079
prim/signal read (tracked, 1×)               662.1 ns     655.9 ns     77855
prim/signal read (tracked, same ×100)        17.0 µs      16.8 µs      2906
prim/signal write (same value, equals cutoff) 18.1 ns      17.8 ns      2728712
prim/signal write (0 subscribers)            44.4 ns      44.3 ns      1124878
prim/signal write (1 subscribers)            162.2 ns     161.3 ns     301482
prim/signal write (10 subscribers)           1.3 µs       1.3 µs       37767
prim/signal write (100 subscribers)          12.4 µs      12.3 µs      3925
prim/create Signal                           48.4 ns      47.7 ns      1027700
prim/create Computed + first read            578.6 ns     531.0 ns     96172
prim/create Effect.immediate                 421.9 ns     378.2 ns     160567
shape/deep chain ×10                         6.8 µs       6.7 µs       7387
shape/deep chain ×100                        72.7 µs      71.4 µs      687
shape/deep chain ×1000                       732.5 µs     722.8 µs     68
shape/fan-out 1→1000 computeds (read all)    645.5 µs     632.3 µs     76
shape/fan-out 1→1000 effects (immediate)     457.3 µs     445.3 µs     108
shape/fan-in 1000→1 (write one)              175.6 µs     168.2 µs     281
shape/diamond 1→2→1                          2.3 µs       2.2 µs       21598
shape/wide diamond 1→100→1                   98.4 µs      97.3 µs      446
shape/layered grid 10×100                    89.1 µs      87.0 µs      548
shape/dynamic deps (switch 50↔50)            9.5 µs       9.5 µs       5226
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