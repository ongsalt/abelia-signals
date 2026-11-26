import AbeliaSignals
import Testing

// Effects made in actor-isolated code can't be sent at all: their closures are actor-isolated, so
// region analysis keeps the effect on that actor. The gap is nonisolated code, made here.

// an effect owned by a scope (ownership the compiler can't see), handed out as if it were free
nonisolated func makeScopeOwnedEffect() -> sending Effect {
    let scope = EffectScope()
    _ = Unmanaged.passRetained(scope)  // keep the owner alive in the child process
    return scope.run { Effect {} }
}

// an effect with no owner: legitimately sendable
nonisolated func makeFreeEffect() -> sending Effect {
    Effect {}
}

actor Home {
    func makeOwned() -> sending Effect { makeScopeOwnedEffect() }
    func makeFree() -> sending Effect { makeFreeEffect() }
}

actor Elsewhere {
    func dispose(_ effect: sending Effect) {
        effect.dispose()
    }
}

@Suite
struct IsolationTests {
    @Test("isolation: an owned effect used on another actor traps (debug)")
    func sendingOwnedEffectTraps() async {
        await #expect(processExitsWith: .failure) {
            let effect = await Home().makeOwned()
            await Elsewhere().dispose(effect)
        }
    }

    @Test("isolation: an effect with no owner can be sent")
    func sendingFreeEffectIsFine() async {
        await #expect(processExitsWith: .success) {
            let effect = await Home().makeFree()
            await Elsewhere().dispose(effect)
        }
    }
}
