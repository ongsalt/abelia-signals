# AbeliaSignals

Fine-grained reactivity for Swift: signals, lazy computeds and batched effects.
The algorithm is ported from [alien-signals](https://github.com/stackblitz/alien-signals).

```swift
@MainActor func setup() {
    let count = Signal(0)
    let doubled = Computed { count.value * 2 }

    effect { print("count", count.value, "doubled", doubled.value) }   // prints now

    count.value = 1
    count.value = 2   // both writes land in one re-run, on the next main actor turn
}
```

## Installation

Requires Swift 6.4.

```swift
.package(url: "https://github.com/ongsalt/abelia-signals.git", branch: "main")
```

```swift
.target(name: "App", dependencies: [.product(name: "AbeliaSignals", package: "abelia-signals")])
```

`Computed.observing` uses an Observation API that is only available from OS 27 on Apple platforms.

## Basics

```swift
let name = Signal("a")                  // Equatable: writing an equal value does nothing
let pos  = Signal(Point(), equals: { $0.x == $1.x })
let blob = Signal(NonEquatable())       // not Equatable: every write notifies

name.value = "b"                        // tracked read / write
name.peek                               // read without subscribing
list.value.append(x)                    // in-place mutation: always notifies, and isn't a read

let upper = Computed { name.value.uppercased() }   // lazy and cached
upper.value
upper.peek

let e = effect {
    print(name.value)
    onCleanup { print("before the next run, and on stop") }
}
e.stop()

untrack { name.value }                  // reads in here don't subscribe
```

- A computed only recomputes when something it read changed, and an unchanged result
  (by `==`, or `equals:`) stops the update there.
- Dependencies are tracked again on every run, so branches work as expected.
- A computed nobody watches lets go of its sources and recomputes on its next read.
- Effects created inside an effect are stopped before the parent re-runs.

### Scopes

```swift
let scope = EffectScope()
scope.run {
    effect { … }
    onCleanup { … }   // runs when the scope stops
}
scope.stop()          // also happens when the scope is deinitialized
```

A scope created inside an effect or another scope is owned and stopped by it.
Pass `detached: true` to opt out.

### `@Observable`

```swift
let title = Computed.observing { model.title }   // invalidated when model.title changes
```

Changes made on the computed's actor invalidate it synchronously. Changes from other
threads hop onto that actor first.

## Runtimes

Effects never re-run synchronously on write. They're queued, and a `Runtime` flushes
them in one batch. Each actor gets its own runtime, found from the caller's isolation,
so creating effects needs no setup.

### On the main actor

`MainActor` already owns a runtime. Effects created on it flush on the next main actor turn.

### On your own actor

Conform to `RuntimeOwner` and store a runtime:

```swift
actor Store: RuntimeOwner {
    let signalsRuntime = Runtime()

    let count = Signal(0)
    let doubled = Signal(0)

    func start() {
        effect { [count, doubled] in doubled.value = count.value * 2 }
    }
}
```

The actor owns the runtime, and the runtime owns the effects created on the actor, so
all three are freed together.

Effect bodies on an actor should capture what they use, not `self`:

- `effect { [count, doubled] in … }` holds only those signals. It still runs on the
  actor, since that's where its runtime flushes.
- `effect { count.value }` means `self.count.value`, so it captures `self` strongly.
  The actor then keeps itself alive through its own runtime and is never freed,
  unless you stop the effect.
- `effect { [weak self] in … }` loses the actor's isolation, so actor state can't be
  touched from it.

So keep the state an effect needs in signals, or in other objects, and list them in
the capture list.

### Custom event loops and manual flushing

Set `schedule` to hand flushes to another loop:

```swift
let signalsRuntime: Runtime = {
    let runtime = Runtime()
    runtime.schedule = { flush in myLoop.post(flush) }
    return runtime
}()
```

`schedule` is called in the middle of a write, so it must not call `flush` synchronously.

Code that isn't on any actor needs a runtime bound explicitly, and has to flush it:

```swift
let runtime = Runtime()          // keep this alive: effects don't
runtime.schedule = { _ in }      // silences the "call flush()" warning
runtime.run {
    effect { … }                 // effects created in here use this runtime
}
runtime.flush()
```

`runtime.run` takes priority over the actor's runtime, which is also how tests get
isolated runtimes. Creating a top-level effect outside both traps, with a message
saying so.

## Lifetimes

There's no garbage collector, so ownership is explicit:

- A runtime owns its top-level effects and stops them when it's freed. Effects and
  scopes don't keep their runtime alive.
- Dropping an `Effect` handle doesn't stop it. Call `stop()`, or let its owner
  (parent effect, scope or runtime) stop it.
- Effect bodies and `onCleanup` closures hold whatever they capture until the effect stops.
- A signal never keeps its subscribers alive.

## Differences from JS signals

| | JS (alien-signals, Preact, Solid) | AbeliaSignals |
|---|---|---|
| Effect re-runs | Synchronous after a write, unless in a `batch` | Always batched into a flush. Only the first run is synchronous |
| Threads | One global graph | A runtime per actor. The graph isn't thread-safe, so use it from that actor only |
| Stopping effects | Freed when unreferenced | Explicit `stop()`, or stopped with their owner |
| Equality | `Object.is` | `==` for `Equatable`, `equals:`, or always notify |
| In-place mutation | `arr.push(x)` doesn't notify | `s.value.append(x)` notifies |
| Syntax | `s()` / `s(v)` | `s.value` / `s.peek` |
| Cleanup | Return a function, or `onCleanup` | `onCleanup { }` |

## License

MIT. See [LICENSE](LICENSE).
