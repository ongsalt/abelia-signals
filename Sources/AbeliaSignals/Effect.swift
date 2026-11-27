public final class Effect: ReactiveNode {
    @usableFromInline
    let effect: () -> Void
    @usableFromInline
    let allowRecurse: Bool
    @usableFromInline
    let flush: Flush
    // `EffectScheduler.current` when this effect was created: current again during each run, so
    // effects created by the body inherit it on reruns too (a rerun from a flush is outside any
    // `withEffectScheduler`)
    @usableFromInline
    let capturedScheduler: EffectScheduler?

    @usableFromInline
    @exclusivity(unchecked)
    var isReallyDirty: Bool = false

    @usableFromInline
    let innerScope: EffectScope

    @usableFromInline
    @exclusivity(unchecked)
    unowned(unsafe) var scope: EffectScope?
    @usableFromInline
    @exclusivity(unchecked)
    var indexInScope: Int = -1
    @usableFromInline
    @exclusivity(unchecked)
    var isDisposed = false

    #if DEBUG
    @usableFromInline
    @exclusivity(unchecked)
    var createdIn: IsolationKey = .unknown
    #endif

    @discardableResult
    @inlinable
    public init(
        flush: Flush? = nil, allowRecurse: Bool = false, effect: @escaping () -> Void
    ) {
        let capturedScheduler = EffectScheduler.current
        self.capturedScheduler = capturedScheduler
        self.flush = flush ?? capturedScheduler.map { .scheduler($0) } ?? .immediate
        self.allowRecurse = allowRecurse
        self.effect = effect
        self.innerScope = EffectScope(attached: false)
        super.init(isEffect: true)
        innerScope.ownerEffect = self
        EffectScope.current?.adopt(self)
        #if DEBUG
        createdIn = .current
        #endif
        node.pointee.state = .dirty
        // inside a batch, like every run: a write in the body only queues, it can't rerun this
        // effect while the body is still running
        batch { runEffect(force: true) }
    }

    @inlinable
    public func dispose() {
        if isDisposed { return }
        assertUsedWhereOwned()
        let owner = scope
        disposeOwned()
        owner?.release(self)
    }

    // the same, but called by the scope so it wont tell scope to release self again
    @inlinable
    func disposeOwned() {
        if isDisposed { return }
        isDisposed = true
        scope = nil
        // disposed mid-run: the rest of the body reads untracked (withTracking restores the
        // outer sink when the run ends)
        if Node.current == node { Node.current = nil }
        node.unlinkSources()
        innerScope.reset()
    }

    @inlinable
    override func becameDirty(confident: Bool) {
        if confident {
            isReallyDirty = true
        }

        // schedule the update
        flush.schedule(self)
    }

    // only effects with an owner the compiler can't see
    @inlinable
    func assertUsedWhereOwned() {
        #if DEBUG
        assert(
            (scope == nil && capturedScheduler == nil) || createdIn.isCurrent,
            "Effect used away from its owner (sent with `sending`?)"
        )
        #endif
    }

    // .dirty -> yes. `.maybe` -> check
    @inlinable
    func willRerun() -> Bool {
        if node.pointee.state == .maybe {
            for i in node.pointee.sources.indices {
                _ = node.pointee.sources[i].node.pull()
                if node.pointee.state == .dirty { break }
            }
        }
        return node.pointee.state == .dirty
    }

    @inlinable
    func runEffect(force: Bool = false) {
        if isDisposed { return }
        assertUsedWhereOwned()

        // Owner first, without running it here (it may be on another scheduler)
        // if parent dirty -> self gonna be disposed anywhere
        if !force {
            var owner = scope?.ownerEffect
            while let o = owner {
                if o.willRerun() { return }
                owner = o.scope?.ownerEffect
            }
        }

        let shouldRun = force || isReallyDirty || node.pull()

        // clean before run so write in effect body will mark this dirty again
        node.pointee.state = .clean
        isReallyDirty = false
        if !shouldRun { return }

        innerScope.reset()

        let prev = EffectScope.current
        EffectScope.current = innerScope
        defer { EffectScope.current = prev }
        let prevScheduler = EffectScheduler.current
        EffectScheduler.current = capturedScheduler
        defer { EffectScheduler.current = prevScheduler }
        node.pointee.isRunning = !allowRecurse
        defer { node.pointee.isRunning = false }
        node.withTracking(effect)
    }
}
