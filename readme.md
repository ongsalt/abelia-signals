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
prim/signal read (untracked)                 12.5 ns      12.3 ns      3997339
prim/signal peek                             11.8 ns      11.8 ns      4246534
prim/signal read (tracked, 1×)               87.4 ns      85.7 ns      572271
prim/signal read (tracked, same ×100)        87.0 ns      85.8 ns      568469
prim/signal write (same value, equals cutoff) 18.4 ns      18.1 ns      2761354
prim/signal write (0 subscribers)            46.3 ns      45.0 ns      1080022
prim/signal write (1 subscribers)            166.4 ns     161.7 ns     299693
prim/signal write (10 subscribers)           1.3 µs       1.3 µs       37876
prim/signal write (100 subscribers)          12.7 µs      12.3 µs      3859
prim/create Signal                           49.2 ns      48.5 ns      967289
prim/create Computed + first read            640.6 ns     568.1 ns     88866
prim/create Effect.immediate                 457.1 ns     391.0 ns     135764
shape/deep chain ×10                         88.8 ns      87.1 ns      569558
shape/deep chain ×100                        88.9 ns      87.9 ns      561925
shape/deep chain ×1000                       87.9 ns      87.3 ns      565139
shape/fan-out 1→1000 computeds (read all)    41.9 µs      41.8 µs      1198
shape/fan-out 1→1000 effects (immediate)     235.7 µs     230.4 µs     209
shape/fan-in 1000→1 (write one)              108.3 ns     107.5 ns     367014
shape/diamond 1→2→1                          88.6 ns      87.8 ns      565092
shape/wide diamond 1→100→1                   88.3 ns      87.9 ns      561527
shape/layered grid 10×100                    4.1 µs       4.1 µs       12075
shape/dynamic deps (switch 50↔50)            89.2 ns      87.9 ns      564773
```

## Compare to alien-signals
holy shit
```
case	                        Swift	Node	Bun
signal read (untracked)	        13.1 ns	2.2 ns	1.5 ns
signal write (0 subs)	        45 ns	14.7 ns	8.5 ns
tracked read ×100 (same signal)	30.1 µs	267 ns	280 ns
write → 100 subscribers	        8.5 µs	425 ns	393 ns
diamond 1→2→1	                2.5 µs	122 ns	100 ns
deep chain ×1000	            717 µs	40 µs	33 µs
fan-out 1→1000 computeds	    68.5 ms	31 µs	32 µs
wide diamond 1→100→1	        820 µs	4.4 µs	3.8 µs
layered grid 10×100	            157 µs	4.5 µs	4.7 µs
dynamic deps 50↔50	            12.2 µs	1.9 µs	1.9 µs
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