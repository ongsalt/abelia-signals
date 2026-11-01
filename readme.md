# AbeliaSignals

Fine-grained reactivity for Swift: signals, lazy computeds and batched effects.
The algorithm is ported from [alien-signals](https://github.com/stackblitz/alien-signals).

```swift
let count = Signal(0)
let doubled = Computed { count.value * 2 }

effect { print("count", count.value, "doubled", doubled.value) }   // prints now

count.value = 1
count.value = 2   // both writes land in one re-run, on the next main actor turn
```

## Installation

Requires Swift 6.4. probably break on newer versions becuase of Builtin usages. 

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

### `@Signal` and `@Computed` on classes

```swift
final class Cart {
    @Signal var count = 0            // a property wrapper: same rules as Signal
    let price: Double

    @Computed                        // a macro: cached until what it reads changes
    var total: Double {
        Double(count) * price
    }

    init(price: Double) { self.price = price }
}

cart.count += 1                      // writes the signal
cart.total                           // reads the computed, tracked
cart.$count                          // the Signal itself, as visible as `count`
cart.$total                          // the Computed itself, likewise
```

`@Computed` needs a class, an explicit type and a read-only body written directly
(`var x: T { … }`, not `get { }`). The body can use `self` as usual. Anything that reads
the property (an effect, another computed) keeps the object alive, as a closure capturing
it would; once nothing reads it, it doesn't, so the object is freed as usual.

In effects, capture signals rather than `self`, or the object keeps itself alive through
its own effects: `effect { [count = cart.$count] in … }`.

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

### Into Observation

Observation reads signals through `Observed`, an `@Observable` mirror:

```swift
@MainActor final class Model {
    @Signal var count = 0
    let label: Observed<String>

    init() {                         // not inside withObservationTracking
        label = Observed { [count = _count] in "\(count.value) items" }
    }
}

withObservationTracking { model.label.value } onChange: { … }
```

`compute` runs in an effect, so it updates `value` in the next flush and only when the
result changed (by `==` when Equatable). Freeing the `Observed` stops it.

Don't read signals or computeds directly inside `withObservationTracking`. A computed
that isn't cached would recompute there: any `@Observable` it reads joins the
subscription (Observation has no way to untrack), and a `Computed.observing` would nest
tracking, which doesn't work.

## Schedulers

Effects never re-run synchronously on write. They're queued, and an `EffectScheduler`
flushes them in one batch. There's one per serial executor: effects, scopes and observing
computeds use the scheduler of the executor running the code that creates them, however
deep in synchronous code, isolated or not. Effects created inside an effect or scope use
its scheduler. Signals and computeds don't need one.

### On the main actor

Nothing to set up. Main actor code, including main-thread callbacks that aren't in a
task, uses `EffectScheduler.main`, which flushes on the next main actor turn.

### On your own actor

Conform to `EffectSchedulerOwner`:

```swift
actor Store: EffectSchedulerOwner {
    lazy var effectScheduler = EffectScheduler(owner: self)   // doesn't keep the actor alive

    let count = Signal(0)
    let doubled = Signal(0)

    func start() {
        effect { [count, doubled] in doubled.value = count.value * 2 }
    }
}
```

The actor owns the scheduler, and the scheduler owns the effects created on the actor,
so all three are freed together. Creating an effect on an actor that doesn't conform
traps. This only works for actors on their default executor: one with a custom executor
needs `scheduler.run { }` (below).

Effect bodies on an actor should capture what they use, not `self`:

- `effect { [count, doubled] in … }` holds only those signals. It still runs on the
  actor, since that's where its scheduler flushes.
- `effect { count.value }` means `self.count.value`, so it captures `self` strongly.
  The actor then keeps itself alive through its own scheduler and is never freed,
  unless you stop the effect.
- `effect { [weak self] in … }` loses the actor's isolation, so actor state can't be
  touched from it.

So keep the state an effect needs in signals, or in other objects, and list them in
the capture list.

### Custom event loops and manual flushing

Set `schedule` to hand flushes to another loop:

```swift
let scheduler = EffectScheduler()
scheduler.schedule = { flush in myLoop.post(flush) }
```

`schedule` is called in the middle of a write, so it must not call `flush` synchronously.

Code with no serial executor (a plain thread, nonisolated async code) or on a custom
executor binds a scheduler explicitly, and may have to flush it:

```swift
let scheduler = EffectScheduler()   // keep this alive: effects don't
scheduler.schedule = { _ in }       // silences the "call flush()" warning
scheduler.run {
    effect { … }                    // effects created in here use this scheduler
}
scheduler.flush()
```

`run` takes priority over the executor's scheduler, which is also how tests get one each.

## Lifetimes

There's no garbage collector, so ownership is explicit. The rule underneath: whatever
reads a node keeps it alive, and a node never keeps its readers alive.

- An effect or computed keeps the signals and computeds it read alive. A signal never
  keeps its subscribers alive.
- A computed lives while it's referenced or read. Once nothing reads it, it lets go of
  its sources and recomputes on its next read.
- A `@Computed` property: whatever reads it keeps its object alive, as a closure
  capturing the object would. Once nothing reads it, it doesn't.
- Dropping an `Effect` handle doesn't stop it. Call `stop()`, or let its owner (the
  effect, computed or scope it was created in, or its scheduler) stop it.
- An `EffectScope` created inside an effect or scope is owned by it. One at the top
  level, or `detached`, stops when deinitialized. Freeing an `Observed` stops its effect.
- A scheduler owns its top-level effects and stops them when it's freed. Effects and
  scopes don't keep it alive. `EffectScheduler.main` is never freed; an
  `EffectSchedulerOwner` actor's scheduler is freed with the actor.
- Effect bodies, computed bodies and `onCleanup` closures hold what they capture until
  the effect stops or the computed is freed. Capture signals rather than `self` to
  avoid an object keeping itself alive.

## Differences from JS signals

| | JS libraries | AbeliaSignals |
|---|---|---|
| Effect re-runs | alien-signals, Preact: synchronously after each write, unless inside a batch. Svelte 5 and Vue batch them (a microtask, or before the next render) | Always batched into one flush per executor turn, like Svelte. Only the first run is synchronous |
| Computeds | Lazy and cached, except Solid's `createMemo`, which is eager | Lazy and cached |
| Threads | One single-threaded graph | A scheduler per serial executor. The graph isn't thread-safe, so use it from one executor |
| Stopping effects | Call the dispose function `effect()` returns, or dispose its owner (a Solid root, a Vue `effectScope`, a Svelte component). Until then it stays subscribed, so it isn't garbage-collected | `stop()`, or stopped with its owner (an effect, scope or scheduler). An `EffectScope` also stops when deinitialized |
| Equality | `!==` (alien-signals, Preact, Solid by default), `Object.is` (Vue). Objects compare by identity | `==` for `Equatable` (arrays compare by contents, in O(n)), `equals:`, or always notify |
| In-place mutation | `arr.push(x)` doesn't notify in alien-signals, Preact or Solid. Vue's deep `ref` and Svelte 5's `$state` do, tracked per index and property | `s.value.append(x)` notifies, for the whole value |
| Syntax | `s()` / `s(v)` (alien-signals), `s.value` (Preact, Vue), getter/setter pairs (Solid), plain variables (Svelte) | `s.value` / `s.peek`, like Preact's `.value` / `.peek()` |
| Cleanup | Return a teardown function (alien-signals, Preact, Svelte), `onCleanup` (Solid), `onWatcherCleanup` (Vue) | `onCleanup { }` |

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
