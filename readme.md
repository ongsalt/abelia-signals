# AbeliaSignals

Fine-grained reactivity for Swift: signals, lazy computeds and batched effects.
The algorithm is ported from [alien-signals](https://github.com/stackblitz/alien-signals).

```swift
@MainActor final class App {
    let runtime: Runtime
    let count = Signal(0)

    init() { runtime = Runtime() }   // flushes on the main actor, where it's created

    func setup() {
        let doubled = Computed { [count] in count.value * 2 }
        runtime.run {
            effect { [count] in print("count", count.value, "doubled", doubled.value) }   // prints now
        }
        count.value = 1
        count.value = 2   // both writes land in one re-run, on the next main actor turn
    }
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

### Property wrappers

`Signal` and `Computed` are also property wrappers:

```swift
final class Cart {
    @Signal var count = 0            // same rules: Equatable values skip equal writes
    @Computed var total: Double      // read-only, so it's set up in init

    init(price: Double) {
        _total = Computed { [count = _count] in Double(count.value) * price }
    }
}

cart.count += 1                      // writes the signal
cart.total                           // reads the computed, tracked
cart.$count                          // the Signal itself
```

Capture signals in computeds and effects, not `self`, or the object keeps itself alive
through its own nodes. Inside `init` that means the backing `_count`, since `$count`
counts as a use of `self` until every property is set. Outside `init`, `$count` is fine:
`effect { [count = cart.$count] in … }`.

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
them in one batch, on the actor it was created on. Effects, scopes and observing
computeds are created inside `runtime.run { }`, which binds `Runtime.current`; outside
of it they trap. It's a task-local, so it reaches any depth of synchronous code inside
`run`, isolated or not. Effects created inside an effect or scope use its runtime
without another `run`. Signals and computeds don't need a runtime.

### On the main actor

Create the runtime on the main actor and keep it, e.g. on the object that owns the
effects. Effects don't keep their runtime alive. Create it in `init`, not in a
property initializer: those aren't isolated, so it would get no actor to flush on.

```swift
@MainActor final class ViewModel {
    let runtime: Runtime
    let count = Signal(0)

    init() { runtime = Runtime() }

    func start() {
        runtime.run {
            effect { [count] in print(count.value) }
        }
    }
}
```

### On your own actor

Store a runtime and create the actor's effects inside `run`:

```swift
actor Store {
    lazy var runtime = Runtime(owner: self)   // doesn't keep the actor alive

    let count = Signal(0)
    let doubled = Signal(0)

    func start() {
        runtime.run {
            effect { [count, doubled] in doubled.value = count.value * 2 }
        }
    }
}
```

The actor owns the runtime, and the runtime owns the effects created in `run`, so all
three are freed together. Effects created inside those effects use the same runtime
without another `run`.

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
let runtime = Runtime()
runtime.schedule = { flush in myLoop.post(flush) }
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

That's also how tests get a runtime each.

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

## Benchmarks

`Benchmarks/` is a separate package that runs the same cases here and on alien-signals
in bun and node (whichever are installed), and prints ns/op side by side:

```sh
./Benchmarks/run.sh
```

Pass a case name to the binary to run only that one, e.g. for profiling:
`Benchmarks/.build/release/Benchmarks "propagate 10x10"`. Power and thermal state move
the numbers a lot on laptops, so only compare runs from the same session.

## License

MIT. See [LICENSE](LICENSE).
