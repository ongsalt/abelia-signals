// Port of alien-signals' system.ts (MIT, see LICENSE).
import CAbeliaSignals

@usableFromInline @frozen struct ReactiveFlags: OptionSet, Sendable {
    @usableFromInline var rawValue: UInt8

    @inlinable init(rawValue: UInt8) { self.rawValue = rawValue }

    @inlinable static var mutable: Self { Self(rawValue: 1) }
    @inlinable static var watching: Self { Self(rawValue: 2) }
    @inlinable static var recursedCheck: Self { Self(rawValue: 4) }
    @inlinable static var recursed: Self { Self(rawValue: 8) }
    @inlinable static var dirty: Self { Self(rawValue: 16) }
    @inlinable static var pending: Self { Self(rawValue: 32) }
    // an effect or scope among the deps; they're disposed before a re-run
    @inlinable static var hasChildEffect: Self { Self(rawValue: 64) }
}

var activeSub: ReactiveNode? {
    get { csignals_get_active_sub().map { Unmanaged.fromOpaque($0).takeUnretainedValue() } }
    set { csignals_set_active_sub(newValue.map { Unmanaged.passUnretained($0).toOpaque() }) }
}

// no retain, for the read path
var activeSubRef: NodeRef? {
    csignals_get_active_sub().map { NodeRef.fromOpaque($0) }
}

// set and restore without retaining, around a run
func swapActiveSub(_ sub: ReactiveNode) -> UnsafeMutableRawPointer? {
    let prev = csignals_get_active_sub()
    csignals_set_active_sub(Unmanaged.passUnretained(sub).toOpaque())
    return prev
}

func restoreActiveSub(_ prev: UnsafeMutableRawPointer?) {
    csignals_set_active_sub(prev)
}

var cycle: UInt64 { csignals_get_cycle() }

func nextCycle() { _ = csignals_next_cycle() }

var runDepth: UInt32 {
    get { csignals_get_run_depth() }
    set { csignals_set_run_depth(newValue) }
}

// A sub owns its dep links, and through them its deps. Graph pointers are
// Unmanaged so walks never retain; a link holds +1 until unlink (see releaseLink).
// No exclusivity checks: only this module touches these, never overlapping.
public class ReactiveNode {
    @exclusivity(unchecked) var flags: ReactiveFlags
    @exclusivity(unchecked) var deps: LinkRef?
    @exclusivity(unchecked) var depsTail: LinkRef?
    @exclusivity(unchecked) var subs: LinkRef?
    @exclusivity(unchecked) var subsTail: LinkRef?

    @usableFromInline init(flags: ReactiveFlags) {
        self.flags = flags
    }

    // past depsTail first: a node freed mid-run has links depsTail doesn't reach
    deinit {
        purgeDeps(self)
        disposeAllDepsInReverse(self)
    }

    func update() -> Bool { false }

    func unwatched() {}

    var subscriberCount: Int {
        var count = 0
        var link = subs
        while let l = link {
            count += 1
            link = l.nextSub
        }
        return count
    }
}

final class Link {
    @exclusivity(unchecked) var version: UInt64
    let dep: ReactiveNode
    let sub: NodeRef
    @exclusivity(unchecked) var prevDep: LinkRef?
    @exclusivity(unchecked) var nextDep: LinkRef?
    @exclusivity(unchecked) var prevSub: LinkRef?
    @exclusivity(unchecked) var nextSub: LinkRef?
    // the deferred-release list, see releaseLink
    @exclusivity(unchecked) var nextDeferred: LinkRef?

    init(
        version: UInt64, dep: ReactiveNode, sub: NodeRef, prevDep: LinkRef?, nextDep: LinkRef?,
        prevSub: LinkRef?
    ) {
        self.version = version
        self.dep = dep
        self.sub = sub
        self.prevDep = prevDep
        self.nextDep = nextDep
        self.prevSub = prevSub
    }
}

typealias LinkRef = Unmanaged<Link>
typealias NodeRef = Unmanaged<ReactiveNode>

extension Unmanaged where Instance == Link {
    var dep: NodeRef { _withUnsafeGuaranteedRef { .passUnretained($0.dep) } }
    var sub: NodeRef { _withUnsafeGuaranteedRef { $0.sub } }
    var nextDep: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.nextDep } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.nextDep = newValue } }
    }
    var prevDep: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.prevDep } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.prevDep = newValue } }
    }
    var nextSub: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.nextSub } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.nextSub = newValue } }
    }
    var prevSub: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.prevSub } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.prevSub = newValue } }
    }
    var version: UInt64 {
        get { _withUnsafeGuaranteedRef { $0.version } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.version = newValue } }
    }
    static func === (a: Self, b: Self) -> Bool { a.toOpaque() == b.toOpaque() }
}

extension Unmanaged where Instance == ReactiveNode {
    var flags: ReactiveFlags {
        get { _withUnsafeGuaranteedRef { $0.flags } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.flags = newValue } }
    }
    var deps: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.deps } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.deps = newValue } }
    }
    var depsTail: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.depsTail } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.depsTail = newValue } }
    }
    var subs: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.subs } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.subs = newValue } }
    }
    var subsTail: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.subsTail } }
        nonmutating set { _withUnsafeGuaranteedRef { $0.subsTail = newValue } }
    }
    func update() -> Bool { _withUnsafeGuaranteedRef { $0.update() } }
    func unwatched() { _withUnsafeGuaranteedRef { $0.unwatched() } }
    static func === (a: Self, b: Self) -> Bool { a.toOpaque() == b.toOpaque() }
}

func link(_ dep: ReactiveNode, _ sub: NodeRef, _ version: UInt64) {
    let depRef = NodeRef.passUnretained(dep)
    let prevDep = sub.depsTail
    if let prevDep, prevDep.dep === depRef { return }

    let nextDep = prevDep != nil ? prevDep!.nextDep : sub.deps
    if let nextDep, nextDep.dep === depRef {
        nextDep.version = version
        sub.depsTail = nextDep
        return
    }

    let prevSub = depRef.subsTail
    if let prevSub, prevSub.version == version, prevSub.sub === sub { return }

    // the +1 held by sub's dep list
    let newLink = LinkRef.passRetained(
        Link(
            version: version, dep: dep, sub: sub, prevDep: prevDep, nextDep: nextDep,
            prevSub: prevSub))
    sub.depsTail = newLink
    depRef.subsTail = newLink
    nextDep?.prevDep = newLink
    if let prevDep { prevDep.nextDep = newLink } else { sub.deps = newLink }
    if let prevSub { prevSub.nextSub = newLink } else { depRef.subs = newLink }
}

// removes `link` from both lists, then releases it, which can free its dep
@discardableResult
func unlink(_ link: LinkRef, _ sub: NodeRef) -> LinkRef? {
    let dep = link.dep
    let prevDep = link.prevDep
    let nextDep = link.nextDep
    let prevSub = link.prevSub
    let nextSub = link.nextSub

    if let nextDep { nextDep.prevDep = prevDep } else { sub.depsTail = prevDep }
    if let prevDep { prevDep.nextDep = nextDep } else { sub.deps = nextDep }
    if let nextSub { nextSub.prevSub = prevSub } else { dep.subsTail = prevSub }
    if let prevSub {
        prevSub.nextSub = nextSub
    } else {
        dep.subs = nextSub
        // dep is still held by the link
        if nextSub == nil { dep.unwatched() }
    }
    releaseLink(link)
    return nextDep
}

// computeds can unlink what a checkDirty walk is on, so links unlinked during
// a walk are freed when the outermost walk ends
private func releaseLink(_ link: LinkRef) {
    if csignals_get_walk_depth() == 0 {
        link.release()
    } else {
        link._withUnsafeGuaranteedRef {
            $0.nextDeferred = csignals_get_deferred_links().map { LinkRef.fromOpaque($0) }
        }
        csignals_set_deferred_links(link.toOpaque())
    }
}

private func releaseDeferredLinks() {
    while let next = csignals_get_deferred_links() {
        let link = LinkRef.fromOpaque(next)
        csignals_set_deferred_links(link._withUnsafeGuaranteedRef { $0.nextDeferred?.toOpaque() })
        link.release()
    }
}

// on the caller's stack, spilling to the heap past `buffer.count`
struct ScratchStack<Element> {
    let buffer: UnsafeMutableBufferPointer<Element>
    var count = 0
    var spill: [Element] = []

    init(_ buffer: UnsafeMutableBufferPointer<Element>) { self.buffer = buffer }

    mutating func push(_ element: Element) {
        if count < buffer.count {
            (buffer.baseAddress! + count).initialize(to: element)
        } else {
            spill.append(element)
        }
        count += 1
    }

    mutating func pop() -> Element? {
        if count == 0 { return nil }
        count -= 1
        return count < buffer.count ? (buffer.baseAddress! + count).move() : spill.removeLast()
    }
}

// fits withUnsafeTemporaryAllocation's 1KB stack limit
let scratchCapacity = 120

func propagate(_ start: LinkRef, innerWrite: Bool) {
    withUnsafeTemporaryAllocation(of: LinkRef?.self, capacity: scratchCapacity) { buffer in
        var stack = ScratchStack(buffer)
        var link = start
        var next = link.nextSub

        top: while true {
            let sub = link.sub
            var flags = sub.flags

            if flags.isDisjoint(with: [.recursedCheck, .recursed, .dirty, .pending]) {
                sub.flags = flags.union(innerWrite ? [.pending, .recursed] : .pending)
            } else if flags.isDisjoint(with: [.recursedCheck, .recursed]) {
                flags = []
            } else if !flags.contains(.recursedCheck) {
                sub.flags = flags.subtracting(.recursed).union(.pending)
            } else if flags.isDisjoint(with: [.dirty, .pending]) && isValidLink(link, sub) {
                sub.flags = flags.union([.recursed, .pending])
                flags.formIntersection(.mutable)
            } else {
                flags = []
            }

            if flags.contains(.watching) { notify(sub) }

            if flags.contains(.mutable), let subSubs = sub.subs {
                link = subSubs
                if let nextSub = subSubs.nextSub {
                    stack.push(next)
                    next = nextSub
                }
                continue
            }

            if let n = next {
                link = n
                next = n.nextSub
                continue
            }

            while let saved = stack.pop() {
                if let saved {
                    link = saved
                    next = saved.nextSub
                    continue top
                }
            }

            break
        }
    }
}

func checkDirty(_ start: LinkRef, _ startSub: ReactiveNode) -> Bool {
    let depth = csignals_get_walk_depth()
    csignals_set_walk_depth(depth + 1)
    let dirty = walkDirty(start, startSub)
    csignals_set_walk_depth(depth)
    if depth == 0, csignals_get_deferred_links() != nil { releaseDeferredLinks() }
    return dirty
}

private func walkDirty(_ start: LinkRef, _ startSub: ReactiveNode) -> Bool {
    withUnsafeTemporaryAllocation(of: LinkRef.self, capacity: scratchCapacity) { buffer in
        var stack = ScratchStack(buffer)
        var link = start
        var sub = NodeRef.passUnretained(startSub)
        var checkDepth = 0
        var dirty = false

        top: while true {
            let dep = link.dep
            let flags = dep.flags

            if sub.flags.contains(.dirty) {
                dirty = true
            } else if flags.intersection([.mutable, .dirty]) == [.mutable, .dirty] {
                if dep.update() {
                    // read after: update() may have changed them
                    if let subs = dep.subs, subs.nextSub != nil { shallowPropagate(subs) }
                    dirty = true
                }
            } else if flags.intersection([.mutable, .pending]) == [.mutable, .pending] {
                stack.push(link)
                link = dep.deps!
                sub = dep
                checkDepth += 1
                continue
            }

            if !dirty, let nextDep = link.nextDep {
                link = nextDep
                continue
            }

            while checkDepth > 0 {
                checkDepth -= 1
                link = stack.pop()!
                if dirty {
                    if sub.update() {
                        if let subs = sub.subs, subs.nextSub != nil { shallowPropagate(subs) }
                        sub = link.sub
                        continue
                    }
                    dirty = false
                } else {
                    sub.flags.remove(.pending)
                }
                sub = link.sub
                if let nextDep = link.nextDep {
                    link = nextDep
                    continue top
                }
            }

            return dirty && !sub.flags.isEmpty
        }
    }
}

func shallowPropagate(_ start: LinkRef) {
    var link: LinkRef? = start
    while let l = link {
        let sub = l.sub
        let flags = sub.flags
        if flags.intersection([.pending, .dirty]) == .pending {
            sub.flags = flags.union(.dirty)
            if flags.intersection([.watching, .recursedCheck]) == .watching { notify(sub) }
        }
        link = l.nextSub
    }
}

private func isValidLink(_ checkLink: LinkRef, _ sub: NodeRef) -> Bool {
    var link = sub.depsTail
    while let l = link {
        if l === checkLink { return true }
        link = l.prevDep
    }
    return false
}

private func notify(_ effect: NodeRef) {
    effect._withUnsafeGuaranteedRef {
        let effect = unsafeDowncast($0, to: Effect.self)
        effect.runtimeHandle.runtime?._withUnsafeGuaranteedRef { $0.enqueue(effect) }
    }
}

func purgeDeps(_ sub: ReactiveNode) {
    let sub = NodeRef.passUnretained(sub)
    var link = sub.depsTail != nil ? sub.depsTail!.nextDep : sub.deps
    while let l = link {
        link = unlink(l, sub)
    }
}

func disposeAllDepsInReverse(_ sub: ReactiveNode) {
    let sub = NodeRef.passUnretained(sub)
    var link = sub.depsTail
    while let l = link {
        link = l.prevDep
        unlink(l, sub)
    }
}

func disposeChildEffects(_ sub: ReactiveNode) {
    let sub = NodeRef.passUnretained(sub)
    var link = sub.depsTail
    while let l = link {
        link = l.prevDep
        let dep = l.dep.takeUnretainedValue()
        if dep is Effect || dep is EffectScope { unlink(l, sub) }
    }
}
