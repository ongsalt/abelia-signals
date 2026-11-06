# Abelia Signals
Signals implementation in swift.


```swift
let a = Signal(1)
let b = Signal(1)

let c = Computed {
    a.value + b.value
}

// Effect without owner scope will be dropped if not explicitly reference
Effect(flushing: .immediate) {
    print("[immediate] \(c.value)")
}

// this wont
let e = Effect {
    print("[isolated] \(c.value)")
}
```


## Effect flushing
`Effect` initialization must be either isolated OR has a parent `EffectScope` which is a thread local.

`EffectScope` must speicify its flushing mode.

# Todo
- Effect: lifetime and disposal
- threadlocal
- [alien-signals](https://github.com/stackblitz/alien-signals) style dependency link