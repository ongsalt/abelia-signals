# Abelia Signals
Signals implementation in swift.


```swift
// in MainActor

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

## Effect flushing
`Effect` initialization must be either isolated OR has a parent `EffectScope`.

`EffectScope` must speicify its flushing mode ``

# Todo
- [alien-signals](https://github.com/stackblitz/alien-signals) style dependency link
