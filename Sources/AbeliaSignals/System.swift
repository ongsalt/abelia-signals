// Port of alien-signals' system.ts (MIT, see LICENSE).
import CAbeliaSignals

struct ReactiveFlags: OptionSet {
    var rawValue: UInt8

    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let mutable = Self(rawValue: 1)
    static let watching = Self(rawValue: 2)
    static let recursedCheck = Self(rawValue: 4)
    static let recursed = Self(rawValue: 8)
    static let dirty = Self(rawValue: 16)
    static let pending = Self(rawValue: 32)
    // an effect or scope among the deps; they're disposed before a re-run
    static let hasChildEffect = Self(rawValue: 64)
}

var activeSub: ReactiveNode? {
    get { csignals_get_active_sub().map { Unmanaged.fromOpaque($0).takeUnretainedValue() } }
    set { csignals_set_active_sub(newValue.map { Unmanaged.passUnretained($0).toOpaque() }) }
}

// no retain, for the read path
var activeSubRef: NodeRef? {
    csignals_get_active_sub().map { NodeRef.fromOpaque($0) }
}

var cycle: UInt64 { csignals_get_cycle() }

func nextCycle() { _ = csignals_next_cycle() }

var runDepth: UInt32 {
    get { csignals_get_run_depth() }
    set { csignals_set_run_depth(newValue) }
}

// A sub owns its dep links, and through them its deps. Everything else
// points unowned(unsafe); a link is removed from both lists before release.
// Graph fields skip dynamic exclusivity checks: only this module touches them,
// never with overlapping accesses.
public class ReactiveNode {
    @exclusivity(unchecked) var flags: ReactiveFlags
    @exclusivity(unchecked) var deps: Link?
    @exclusivity(unchecked) unowned(unsafe) var depsTail: Link?
    @exclusivity(unchecked) unowned(unsafe) var subs: Link?
    @exclusivity(unchecked) unowned(unsafe) var subsTail: Link?

    init(flags: ReactiveFlags) {
        self.flags = flags
    }

    deinit { disposeAllDepsInReverse(self) }

    func update() -> Bool { false }

    func unwatched() {}

    final var subsRef: LinkRef? { subs.map { .passUnretained($0) } }
    final var depsRef: LinkRef? { deps.map { .passUnretained($0) } }

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
    unowned(unsafe) let sub: ReactiveNode
    @exclusivity(unchecked) var nextDep: Link?
    @exclusivity(unchecked) unowned(unsafe) var prevDep: Link?
    @exclusivity(unchecked) unowned(unsafe) var prevSub: Link?
    @exclusivity(unchecked) unowned(unsafe) var nextSub: Link?

    init(
        version: UInt64, dep: ReactiveNode, sub: ReactiveNode, prevDep: Link?, nextDep: Link?,
        prevSub: Link?
    ) {
        self.version = version
        self.dep = dep
        self.sub = sub
        self.prevDep = prevDep
        self.nextDep = nextDep
        self.prevSub = prevSub
    }
}

// The hot paths below walk the graph through Unmanaged refs so traversal
// doesn't retain. Nodes and links stay alive while they're linked.
typealias LinkRef = Unmanaged<Link>
typealias NodeRef = Unmanaged<ReactiveNode>

extension Unmanaged where Instance == Link {
    var dep: NodeRef { _withUnsafeGuaranteedRef { .passUnretained($0.dep) } }
    var sub: NodeRef { _withUnsafeGuaranteedRef { .passUnretained($0.sub) } }
    var nextDep: LinkRef? { _withUnsafeGuaranteedRef { $0.nextDep.map { .passUnretained($0) } } }
    var prevDep: LinkRef? { _withUnsafeGuaranteedRef { $0.prevDep.map { .passUnretained($0) } } }
    var nextSub: LinkRef? { _withUnsafeGuaranteedRef { $0.nextSub.map { .passUnretained($0) } } }
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
    var deps: LinkRef? { _withUnsafeGuaranteedRef { $0.deps.map { .passUnretained($0) } } }
    var subs: LinkRef? { _withUnsafeGuaranteedRef { $0.subs.map { .passUnretained($0) } } }
    var depsTail: LinkRef? {
        get { _withUnsafeGuaranteedRef { $0.depsTail.map { .passUnretained($0) } } }
        nonmutating set {
            _withUnsafeGuaranteedRef { $0.depsTail = newValue?.takeUnretainedValue() }
        }
    }
    func update() -> Bool { _withUnsafeGuaranteedRef { $0.update() } }
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

    let prevSub = dep.subsTail.map { LinkRef.passUnretained($0) }
    if let prevSub, prevSub.version == version, prevSub.sub === sub { return }

    sub._withUnsafeGuaranteedRef { sub in
        let newLink = Link(
            version: version, dep: dep, sub: sub,
            prevDep: prevDep?.takeUnretainedValue(), nextDep: nextDep?.takeUnretainedValue(),
            prevSub: prevSub?.takeUnretainedValue())
        sub.depsTail = newLink
        dep.subsTail = newLink
        nextDep?._withUnsafeGuaranteedRef { $0.prevDep = newLink }
        if let prevDep {
            prevDep._withUnsafeGuaranteedRef { $0.nextDep = newLink }
        } else {
            sub.deps = newLink
        }
        if let prevSub {
            prevSub._withUnsafeGuaranteedRef { $0.nextSub = newLink }
        } else {
            dep.subs = newLink
        }
    }
}

// caller keeps `link` alive
@discardableResult
func unlink(_ link: Link, _ sub: ReactiveNode) -> Link? {
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
        if nextSub == nil { dep.unwatched() }
    }
    return nextDep
}

func propagate(_ start: LinkRef, innerWrite: Bool) {
    var link = start
    var next = link.nextSub
    var stack: [LinkRef?] = []

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
                stack.append(next)
                next = nextSub
            }
            continue
        }

        if let n = next {
            link = n
            next = n.nextSub
            continue
        }

        while let saved = stack.popLast() {
            if let saved {
                link = saved
                next = saved.nextSub
                continue top
            }
        }

        break
    }
}

// update() runs user code that can unlink and free nodes on the walk, so the
// stack and anything used across an update() are held strongly
func checkDirty(_ start: LinkRef, _ startSub: ReactiveNode) -> Bool {
    var link = start
    var sub = NodeRef.passUnretained(startSub)
    var stack: [Link] = []
    var checkDepth = 0
    var dirty = false

    top: while true {
        let dep = link.dep
        let flags = dep.flags

        if sub.flags.contains(.dirty) {
            dirty = true
        } else if flags.intersection([.mutable, .dirty]) == [.mutable, .dirty] {
            let subs = dep.subs!
            let changed = withExtendedLifetime(
                (link.takeUnretainedValue(), subs.takeUnretainedValue())
            ) {
                dep.update()
            }
            if changed {
                if subs.nextSub != nil { shallowPropagate(subs) }
                dirty = true
            }
        } else if flags.intersection([.mutable, .pending]) == [.mutable, .pending] {
            stack.append(link.takeUnretainedValue())
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
            let popped = stack.removeLast()
            link = .passUnretained(popped)
            if dirty {
                let subs = sub.subs!
                let changed = withExtendedLifetime((popped, subs.takeUnretainedValue())) {
                    sub.update()
                }
                if changed {
                    if subs.nextSub != nil { shallowPropagate(subs) }
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
        effect.runtime?.enqueue(effect)
    }
}

func purgeDeps(_ sub: ReactiveNode) {
    var link = sub.depsTail != nil ? sub.depsTail!.nextDep : sub.deps
    while let l = link {
        link = unlink(l, sub)
    }
}

func disposeAllDepsInReverse(_ sub: ReactiveNode) {
    var link = sub.depsTail
    while let l = link {
        link = l.prevDep
        unlink(l, sub)
    }
}

func disposeChildEffects(_ sub: ReactiveNode) {
    var link = sub.depsTail
    while let l = link {
        link = l.prevDep
        if l.dep is Effect || l.dep is EffectScope { unlink(l, sub) }
    }
}
