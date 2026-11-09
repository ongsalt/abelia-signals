// Line-by-line port of alien-signals 3.2.1 `esm/system.mjs` (MIT).
// Benchmark baseline only: single-threaded, plain globals, deliberately unoptimized Swift.
//
// The one thing that can't be ported literally is the GC. Ownership instead:
//   - a sub owns its dep chain (`deps` → `nextDep` → ...), a link owns its `dep`
//   - every pointer back up the graph is `unowned(unsafe)`
//   - a node unlinks itself in `deinit` (ReactiveNode)
// Strong locals keep links alive during walks, like the GC does in JS.

public enum ReactiveFlags {
    public static let none = 0
    public static let mutable = 1
    public static let watching = 2
    public static let recursedCheck = 4
    public static let recursed = 8
    public static let dirty = 16
    public static let pending = 32
}

public class ReactiveNode {
    var flags: Int
    var deps: Link?
    unowned(unsafe) var depsTail: Link?
    unowned(unsafe) var subs: Link?
    unowned(unsafe) var subsTail: Link?

    init(flags: Int) {
        self.flags = flags
    }

    // JS: `update` callback, dispatching on 'getter' in node / 'currentValue' in node
    func update() -> Bool {
        flags = 1
        return true
    }

    // JS: `unwatched` callback
    func unwatched() {}

    // not in JS: the GC would collect the links
    deinit {
        var link = deps
        while link != nil {
            link = unlink(link!, self)
        }
    }
}

final class Link {
    var version: Int
    let dep: ReactiveNode
    unowned(unsafe) let sub: ReactiveNode
    unowned(unsafe) var prevDep: Link?
    var nextDep: Link?
    unowned(unsafe) var prevSub: Link?
    unowned(unsafe) var nextSub: Link?

    init(version: Int, dep: ReactiveNode, sub: ReactiveNode, prevDep: Link?, nextDep: Link?, prevSub: Link?, nextSub: Link?) {
        self.version = version
        self.dep = dep
        self.sub = sub
        self.prevDep = prevDep
        self.nextDep = nextDep
        self.prevSub = prevSub
        self.nextSub = nextSub
    }
}

// JS: `stack = { value, prev: stack }`
final class Stack<T> {
    let value: T
    let prev: Stack<T>?

    init(value: T, prev: Stack<T>?) {
        self.value = value
        self.prev = prev
    }
}

func link(_ dep: ReactiveNode, _ sub: ReactiveNode, _ version: Int) {
    let prevDep = sub.depsTail
    if prevDep != nil && prevDep!.dep === dep {
        return
    }
    let nextDep = prevDep != nil ? prevDep!.nextDep : sub.deps
    if nextDep != nil && nextDep!.dep === dep {
        nextDep!.version = version
        sub.depsTail = nextDep
        return
    }
    let prevSub = dep.subsTail
    if prevSub != nil && prevSub!.version == version && prevSub!.sub === sub {
        return
    }
    let newLink = Link(
        version: version,
        dep: dep,
        sub: sub,
        prevDep: prevDep,
        nextDep: nextDep,
        prevSub: prevSub,
        nextSub: nil
    )
    sub.depsTail = newLink
    dep.subsTail = newLink
    if nextDep != nil {
        nextDep!.prevDep = newLink
    }
    if prevDep != nil {
        prevDep!.nextDep = newLink
    } else {
        sub.deps = newLink
    }
    if prevSub != nil {
        prevSub!.nextSub = newLink
    } else {
        dep.subs = newLink
    }
}

@discardableResult
func unlink(_ link: Link, _ sub: ReactiveNode? = nil) -> Link? {
    let sub = sub ?? link.sub
    let dep = link.dep
    let prevDep = link.prevDep
    let nextDep = link.nextDep
    let nextSub = link.nextSub
    let prevSub = link.prevSub
    if nextDep != nil {
        nextDep!.prevDep = prevDep
    } else {
        sub.depsTail = prevDep
    }
    if prevDep != nil {
        prevDep!.nextDep = nextDep
    } else {
        sub.deps = nextDep
    }
    if nextSub != nil {
        nextSub!.prevSub = prevSub
    } else {
        dep.subsTail = prevSub
    }
    if prevSub != nil {
        prevSub!.nextSub = nextSub
    } else {
        dep.subs = nextSub
        if nextSub == nil {
            dep.unwatched()
        }
    }
    return nextDep
}

func propagate(_ start: Link, _ innerWrite: Bool) {
    var link: Link = start
    var next = link.nextSub
    var stack: Stack<Link?>?
    top: repeat {
        let sub = link.sub
        var flags = sub.flags
        if flags & (4 | 8 | 16 | 32) == 0 {
            sub.flags = flags | 32
            if innerWrite {
                sub.flags |= 8
            }
        } else if flags & (4 | 8) == 0 {
            flags = 0
        } else if flags & 4 == 0 {
            sub.flags = (flags & ~8) | 32
        } else if flags & (16 | 32) == 0 && isValidLink(link, sub) {
            sub.flags = flags | (8 | 32)
            flags &= 1
        } else {
            flags = 0
        }
        if flags & 2 != 0 {
            notify(sub)
        }
        if flags & 1 != 0 {
            let subSubs = sub.subs
            if subSubs != nil {
                link = subSubs!
                let nextSub = link.nextSub
                if nextSub != nil {
                    stack = Stack(value: next, prev: stack)
                    next = nextSub
                }
                continue
            }
        }
        if next != nil {
            link = next!
            next = link.nextSub
            continue
        }
        while stack != nil {
            let value = stack!.value
            stack = stack!.prev
            if value != nil {
                link = value!
                next = link.nextSub
                continue top
            }
        }
        break
    } while true
}

func checkDirty(_ start: Link, _ startSub: ReactiveNode) -> Bool {
    var link = start
    var sub = startSub
    var stack: Stack<Link>?
    var checkDepth = 0
    var dirty = false
    top: repeat {
        let dep = link.dep
        let flags = dep.flags
        if sub.flags & 16 != 0 {
            dirty = true
        } else if flags & (1 | 16) == (1 | 16) {
            let subs = dep.subs!
            if dep.update() {
                if subs.nextSub != nil {
                    shallowPropagate(subs)
                }
                dirty = true
            }
        } else if flags & (1 | 32) == (1 | 32) {
            stack = Stack(value: link, prev: stack)
            link = dep.deps!
            sub = dep
            checkDepth += 1
            continue
        }
        if !dirty {
            let nextDep = link.nextDep
            if nextDep != nil {
                link = nextDep!
                continue
            }
        }
        while checkDepth > 0 {
            checkDepth -= 1
            link = stack!.value
            stack = stack!.prev
            if dirty {
                let subs = sub.subs!
                if sub.update() {
                    if subs.nextSub != nil {
                        shallowPropagate(subs)
                    }
                    sub = link.sub
                    continue
                }
                dirty = false
            } else {
                sub.flags &= ~32
            }
            sub = link.sub
            let nextDep = link.nextDep
            if nextDep != nil {
                link = nextDep!
                continue top
            }
        }
        return dirty && sub.flags != 0
    } while true
}

func shallowPropagate(_ start: Link) {
    var link: Link? = start
    repeat {
        let sub = link!.sub
        let flags = sub.flags
        if flags & (32 | 16) == 32 {
            sub.flags = flags | 16
            if flags & (2 | 4) == 2 {
                notify(sub)
            }
        }
        link = link!.nextSub
    } while link != nil
}

func isValidLink(_ checkLink: Link, _ sub: ReactiveNode) -> Bool {
    var link = sub.depsTail
    while link != nil {
        if link === checkLink {
            return true
        }
        link = link!.prevDep
    }
    return false
}
