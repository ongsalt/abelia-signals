# Abelia Signals
Signals implementation in swift.


```swift
let a = Signal(1)
let b = Signal(1)

let c = Computed {
    a.value + b.value
}

Effect(flushing: .immediate) {
    print("[immediate] \(c.value)")
}

Effect {
    print("[isolated] \(c.value)")
}
```

EffectScope is not finished yet.

# Todo
- [alien-signals](https://github.com/stackblitz/alien-signals) style dependency link
