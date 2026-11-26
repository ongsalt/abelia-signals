public final class EffectScope {
    // where this scope sits in its parent, for O(1) removal on its own `dispose()`
    @usableFromInline
    @exclusivity(unchecked)
    unowned(unsafe) var parent: EffectScope?
    @usableFromInline
    @exclusivity(unchecked)
    var indexInParent: Int = -1

    @usableFromInline
    @exclusivity(unchecked)
    unowned(unsafe) var ownerEffect: Effect?

    @usableFromInline
    @exclusivity(unchecked)
    var effects: [Effect] = []
    @usableFromInline
    @exclusivity(unchecked)
    var scopes: [EffectScope] = []
    @usableFromInline
    @exclusivity(unchecked)
    var cleanups: [() -> Void] = []

    #if DEBUG
    @usableFromInline
    @exclusivity(unchecked)
    var createdIn: IsolationKey = .unknown
    #endif

    @inlinable
    public convenience init() {
        self.init(attached: true)
    }

    @inlinable
    init(attached: Bool) {
        if attached, let parent = EffectScope.current {
            parent.adopt(self)
        }
        #if DEBUG
        createdIn = .current
        #endif
    }

    // only scopes owned by another scope
    @inlinable
    func assertUsedWhereOwned() {
        #if DEBUG
        assert(parent == nil || createdIn.isCurrent, "EffectScope used away from its parent (sent with `sending`?)")
        #endif
    }

    @inlinable
    public func run<R, E>(_ body: () throws(E) -> R) throws(E) -> R {
        assertUsedWhereOwned()
        let prev = EffectScope.current
        EffectScope.current = self
        defer { EffectScope.current = prev }
        return try body()
    }

    /// Resets then detaches
    @inlinable
    public func dispose() {
        assertUsedWhereOwned()
        reset()
        parent?.release(self)
    }

    /// Releases everything it owns
    @inlinable
    public func reset() {
        // an effect's inner scope is reset before every rerun, usually with nothing in it
        if effects.isEmpty && scopes.isEmpty && cleanups.isEmpty { return }

        let effects = self.effects
        let scopes = self.scopes
        let cleanups = self.cleanups
        self.effects = []
        self.scopes = []
        self.cleanups = []

        untracked {
            for effect in effects.reversed() { effect.disposeOwned() }
            for scope in scopes.reversed() { scope.disposeOwned() }
            for cleanup in cleanups.reversed() { cleanup() }
        }
    }

    // disposed by the parent, which drops its lists itself
    @inlinable
    func disposeOwned() {
        parent = nil
        reset()
    }

    @inlinable
    func adopt(_ scope: EffectScope) {
        scope.parent = self
        scope.indexInParent = scopes.count
        scopes.append(scope)
    }

    @inlinable
    func adopt(_ effect: Effect) {
        effect.scope = self
        effect.indexInScope = effects.count
        effects.append(effect)
    }

    // Both releases tolerate a child that's no longer in the list: during `reset()` the lists are
    // already detached, and a cleanup may dispose a sibling that hasn't been reached yet.
    @inlinable
    func release(_ scope: EffectScope) {
        let i = scope.indexInParent
        guard i >= 0, i < scopes.count, scopes[i] === scope else {
            scope.parent = nil
            return
        }
        let last = scopes.count - 1
        if i != last {
            scopes[i] = scopes[last]
            scopes[i].indexInParent = i
        }
        scopes.removeLast()
        scope.parent = nil
    }

    @inlinable
    func release(_ effect: Effect) {
        let i = effect.indexInScope
        guard i >= 0, i < effects.count, effects[i] === effect else {
            effect.scope = nil
            return
        }
        let last = effects.count - 1
        if i != last {
            effects[i] = effects[last]
            effects[i].indexInScope = i
        }
        effects.removeLast()
        effect.scope = nil
    }

    deinit {
        reset()
    }
}

@inlinable
public func onCleanup(_ cleanup: @escaping () -> Void) {
    EffectScope.current?.cleanups.append(cleanup)
}
