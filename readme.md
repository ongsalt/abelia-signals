# Abelia Signals
A signals implementation in Swift.

```swift
let a = Signal(1)
let b = Signal(1)

let c = Computed {
    a.value + b.value
}

// Runs immediately, then whenever `c` changes, as long as `e` is retained.
let e = Effect {
    print("c = \(c.value)")
}

a.value = 2 // prints "c = 3"
```

## Signal and Computed
- `Signal(value)` compares values with `==` and ignores writes that don't change anything. Use `Signal(value, equals:)` for custom equality. `Computed` does the same with its return value.
- Reading `.value` inside a `Computed` or `Effect` registers it as a dependency. Use `.peek` to read without tracking, or wrap a block in `untracked { }`.
- `signal.update { $0.append(x) }` mutates the value in place (avoiding copy-on-write copies) and always notifies dependents. Touching the same signal inside `update` will trap.
- `Computed` values are lazy. They only recompute when read, and only if one of their dependencies actually changed.

## Effect
```swift
let e = Effect {
    print(a.value)
}
```
- Runs once immediately, then reruns whenever any tracked dependency changes.
- An effect stays alive as long as it has an owner-your handle, an `EffectScope`, or both. Without a scope, letting the handle deallocate stops the effect. Calling `dispose()` stops it permanently.
- Effects don't trigger themselves when they write to signals they also read. Pass `allowRecurse: true` if you want an effect to keep rerunning until its dependencies stop changing.
- Writing to signals inside an effect is supported; any affected dependents run in the same flush.

## Scope and cleanup
```swift
let scope = EffectScope()
scope.run {
    Effect { print(a.value) } // owned by the scope
    onCleanup { print("bye") }
}
scope.dispose() // disposes the effect, then prints "bye"
```
- Effects and nested scopes created inside `scope.run { }` are owned by that scope. `reset()` disposes everything inside while keeping the scope reusable; `dispose()` also detaches the scope from its own parent.
- Effects own anything created in their body. Nested effects, scopes, and `onCleanup` handlers are disposed before each rerun and when the effect itself is disposed.
- If both an outer effect and a child effect are pending, the child doesn't run—the outer effect reruns first, disposing and recreating it.

## Batching
```swift
batch {
    a.value = 10
    b.value = 20
} // effects run once here
```
Every write acts as its own batch. Nested `batch` calls defer flushing until the outermost block finishes.

## Scheduling
By default, effects run at the end of a write's batch (`Flush.immediate`). To defer execution, use an `EffectScheduler` to collect pending effects and flush them when you're ready:

```swift
let scheduler = EffectScheduler { flush in
    Task { @MainActor in flush() } // or next frame, etc.
}

let e1 = Effect(scheduler: scheduler) { print(a.value) }

let e2 = withEffectScheduler(scheduler) {
    Effect { print(b.value) } // inherits the scheduler
}
```
- `onFlushNeeded` is called once per pending batch of effects. It must invoke `flush` asynchronously; calling it synchronously (`EffectScheduler { flush in flush() }`) will trap.
- An effect captures the active scheduler at creation time, so any nested effects it creates on later reruns inherit it too.
- You can also flush manually with `scheduler.flush()`.

## Threading
Tracking state is thread-local and none of the types are `Sendable`, so a graph belongs to a single thread or actor. Avoid `sending` an `Effect` or `EffectScope` that was created inside a scope, an effect body, or `withEffectScheduler`, since its owner will still access it.

# Todo
- loop detection
- yell when on another executor
- propertyWrapper: `@Computed` property in a class that reference non signal field will make lifetime painful
- observation
