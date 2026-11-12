// Port of alien-signals 3.2.1 `esm/system.mjs` (MIT), same algorithm, tuned for Swift.
// Benchmark baseline only: single-threaded, plain globals, no actors.
// (The plain, unoptimized line-by-line port is in git: 50af4fb.)
//
// Layout: the graph lives in plain structs behind pointers, so walks do no ARC
// and no exclusivity checks:
//   - `Node` is a node's graph state, allocated by its `ReactiveNode` object
//   - `Link` is an edge, from a free-list pool
// Deviation from alien-signals: a dep's subscribers are a contiguous array
// (`Node.sinks`) instead of the `subs`/`nextSub` linked list, so propagation
// reads them without a dependent load per sibling. Removal is swap-remove, each
// link knows its index (`Link.subIndex`). Subscriber order is not stable.
// The sub side (`deps`/`nextDep`, reused through `depsTail`) is unchanged.
// Ownership (replacing JS's GC):
//   - a link retains its dep's object; a node unlinks its deps in `deinit`
//   - links unlinked during a checkDirty walk are recycled after the walk ends
// Flags are raw numbers, like the JS:
//   1 Mutable, 2 Watching, 4 RecursedCheck, 8 Recursed, 16 Dirty, 32 Pending, 64 HasChildEffect

@usableFromInline
typealias NodePtr = UnsafeMutablePointer<Node>

@usableFromInline
typealias LinkPtr = UnsafeMutablePointer<Link>

@usableFromInline
enum Kind: UInt8 {
    case signal  // 'currentValue' in node
    case computed  // 'getter' in node
    case effect  // 'fn' in node
    case scope
    case trigger
}

@usableFromInline
struct Node {
    @usableFromInline
    var flags: Int
    var deps: LinkPtr? = nil
    var depsTail: LinkPtr? = nil
    // subscribers: links whose `dep` is this node. Starts as the inline space
    // right after this struct (see allocNode), moves to the heap past `inlineSinks`
    var sinks: UnsafeMutablePointer<Sink>
    var sinkCount: Int32 = 0
    var sinkCapacity: Int32 = Int32(inlineSinks)
    let kind: Kind
    // the owning object, for update() / effect fn / retain by links
    let object: Unmanaged<ReactiveNode>
}

// the sub is stored next to its link so propagation reads it without going through the link
struct Sink {
    var sub: NodePtr
    var link: LinkPtr
}

let inlineSinks = 2

@usableFromInline
struct Link {
    var version: Int
    var dep: NodePtr
    var sub: NodePtr
    var prevDep: LinkPtr?
    var nextDep: LinkPtr?
    // position in dep.sinks
    var subIndex: Int32
}

public class ReactiveNode {
    @usableFromInline
    let node: NodePtr
    // signal: currentValue = pendingValue; computed: value = getter(). Returns "changed".
    // Built in the subclasses' inlinable inits, so it is specialized on the value type.
    @usableFromInline
    let apply: (ReactiveNode) -> Bool

    @usableFromInline
    init(kind: Kind, flags: Int, apply: @escaping (ReactiveNode) -> Bool) {
        node = allocNode()
        self.apply = apply
        node.initialize(
            to: Node(flags: flags, sinks: inlineSinkStorage(node), kind: kind, object: .passUnretained(self)))
    }

    // not in JS: the GC would collect the links
    deinit {
        var link = node.pointee.deps
        while let l = link {
            link = unlink(l, node)
        }
        // no sinks left: every one would have retained us
        if node.pointee.sinks != inlineSinkStorage(node) {
            node.pointee.sinks.deallocate()
        }
        node.deinitialize(count: 1)
        freeNode(node)
    }
}

// MARK: sinks array

// the inline sinks live right after the Node, in the same allocation
@inline(__always)
func inlineSinkStorage(_ node: NodePtr) -> UnsafeMutablePointer<Sink> {
    UnsafeMutableRawPointer(node + 1).assumingMemoryBound(to: Sink.self)
}

@inline(__always)
func sink(_ dep: NodePtr, _ i: Int32) -> LinkPtr {
    dep.pointee.sinks[Int(i)].link
}

func appendSink(_ dep: NodePtr, _ link: LinkPtr) {
    let count = dep.pointee.sinkCount
    if count == dep.pointee.sinkCapacity {
        let capacity = count * 2
        let grown = UnsafeMutablePointer<Sink>.allocate(capacity: Int(capacity))
        let old = dep.pointee.sinks
        grown.moveInitialize(from: old, count: Int(count))
        if old != inlineSinkStorage(dep) {
            old.deallocate()
        }
        dep.pointee.sinks = grown
        dep.pointee.sinkCapacity = capacity
    }
    link.pointee.subIndex = count
    (dep.pointee.sinks + Int(count)).initialize(to: Sink(sub: link.pointee.sub, link: link))
    dep.pointee.sinkCount = count + 1
}

// swap-remove: the last sink takes the hole and learns its new index
func removeSink(_ dep: NodePtr, _ link: LinkPtr) {
    let i = link.pointee.subIndex
    let last = dep.pointee.sinkCount - 1
    if i != last {
        let moved = dep.pointee.sinks[Int(last)]
        dep.pointee.sinks[Int(i)] = moved
        moved.link.pointee.subIndex = i
    }
    dep.pointee.sinkCount = last
}

// MARK: pools

@exclusivity(unchecked)
nonisolated(unsafe) var freeLinks: LinkPtr? = nil

@exclusivity(unchecked)
nonisolated(unsafe) var freeNodes: ContiguousArray<NodePtr> = []

// Node and its inline sinks in one allocation
let nodeAllocSize = MemoryLayout<Node>.stride + inlineSinks * MemoryLayout<Sink>.stride

func allocNode() -> NodePtr {
    if let node = freeNodes.popLast() {
        return node
    }
    return UnsafeMutableRawPointer.allocate(byteCount: nodeAllocSize, alignment: 16)
        .bindMemory(to: Node.self, capacity: 1)
}

func freeNode(_ node: NodePtr) {
    freeNodes.append(node)
}

func allocLink(_ link: Link) -> LinkPtr {
    let ptr: LinkPtr
    if let free = freeLinks {
        freeLinks = free.pointee.nextDep
        ptr = free
    } else {
        ptr = LinkPtr.allocate(capacity: 1)
    }
    ptr.initialize(to: link)
    _ = link.dep.pointee.object.retain()
    return ptr
}

// JS keeps an unlinked link readable until the GC runs. Recycling one a walk still
// points at would corrupt the walk, so during checkDirty they wait here.
@exclusivity(unchecked)
nonisolated(unsafe) var walkDepth = 0

@exclusivity(unchecked)
nonisolated(unsafe) var deferredLinks: ContiguousArray<LinkPtr> = []

func releaseLink(_ link: LinkPtr) {
    if walkDepth != 0 {
        deferredLinks.append(link)
        return
    }
    let dep = link.pointee.dep.pointee.object
    link.pointee.nextDep = freeLinks
    freeLinks = link
    // last: can free the dep, whose deinit unlinks more
    dep.release()
}

// MARK: walk stacks

// propagate: where to resume in each ancestor's sinks
struct Frame {
    var node: NodePtr
    var index: Int32
}

@exclusivity(unchecked)
nonisolated(unsafe) var frames: UnsafeMutablePointer<Frame>? = nil

@exclusivity(unchecked)
nonisolated(unsafe) var frameCount = 0

@exclusivity(unchecked)
nonisolated(unsafe) var frameCapacity = 0

@inline(__always)
func pushFrame(_ frame: Frame) {
    if frameCount == frameCapacity {
        let capacity = max(64, frameCapacity * 2)
        let grown = UnsafeMutablePointer<Frame>.allocate(capacity: capacity)
        if let old = frames {
            grown.moveInitialize(from: old, count: frameCount)
            old.deallocate()
        }
        frames = grown
        frameCapacity = capacity
    }
    (frames! + frameCount).initialize(to: frame)
    frameCount += 1
}

@exclusivity(unchecked)
nonisolated(unsafe) var checkStack: ContiguousArray<LinkPtr> = []

// MARK: createReactiveSystem

func link(_ dep: NodePtr, _ sub: NodePtr, _ version: Int) {
    let prevDep = sub.pointee.depsTail
    if let prevDep, prevDep.pointee.dep == dep {
        return
    }
    let nextDep = prevDep != nil ? prevDep!.pointee.nextDep : sub.pointee.deps
    if let nextDep, nextDep.pointee.dep == dep {
        nextDep.pointee.version = version
        sub.pointee.depsTail = nextDep
        return
    }
    // JS: dep.subsTail, the most recent subscriber
    let count = dep.pointee.sinkCount
    if count > 0 {
        let prevSub = dep.pointee.sinks[Int(count - 1)]
        if prevSub.sub == sub, prevSub.link.pointee.version == version {
            return
        }
    }
    let newLink = allocLink(
        Link(
            version: version,
            dep: dep,
            sub: sub,
            prevDep: prevDep,
            nextDep: nextDep,
            subIndex: 0
        ))
    sub.pointee.depsTail = newLink
    if let nextDep {
        nextDep.pointee.prevDep = newLink
    }
    if let prevDep {
        prevDep.pointee.nextDep = newLink
    } else {
        sub.pointee.deps = newLink
    }
    appendSink(dep, newLink)
}

@discardableResult
func unlink(_ link: LinkPtr) -> LinkPtr? {
    unlink(link, link.pointee.sub)
}

@discardableResult
func unlink(_ link: LinkPtr, _ sub: NodePtr) -> LinkPtr? {
    let dep = link.pointee.dep
    let prevDep = link.pointee.prevDep
    let nextDep = link.pointee.nextDep
    if let nextDep {
        nextDep.pointee.prevDep = prevDep
    } else {
        sub.pointee.depsTail = prevDep
    }
    if let prevDep {
        prevDep.pointee.nextDep = nextDep
    } else {
        sub.pointee.deps = nextDep
    }
    removeSink(dep, link)
    if dep.pointee.sinkCount == 0 {
        unwatched(dep)
    }
    releaseLink(link)
    return nextDep
}

// JS: propagate(link = dep.subs, innerWrite). Same visit order: depth-first,
// a sub's own subscribers right after it.
func propagate(_ start: NodePtr, _ innerWrite: Bool) {
    var node = start
    var index: Int32 = 0
    let stackBase = frameCount
    while true {
        if index < node.pointee.sinkCount {
            let entry = node.pointee.sinks[Int(index)]
            index += 1
            let sub = entry.sub
            var flags = sub.pointee.flags
            if flags & (4 | 8 | 16 | 32) == 0 {
                sub.pointee.flags = flags | 32
                if innerWrite {
                    sub.pointee.flags |= 8
                }
            } else if flags & (4 | 8) == 0 {
                flags = 0
            } else if flags & 4 == 0 {
                sub.pointee.flags = (flags & ~8) | 32
            } else if flags & (16 | 32) == 0 && isValidLink(entry.link, sub) {
                sub.pointee.flags = flags | (8 | 32)
                flags &= 1
            } else {
                flags = 0
            }
            if flags & 2 != 0 {
                notify(sub)
            }
            if flags & 1 != 0 && sub.pointee.sinkCount > 0 {
                // JS only saves `next` when there is a sibling left; same here
                if index < node.pointee.sinkCount {
                    pushFrame(Frame(node: node, index: index))
                }
                node = sub
                index = 0
            }
            continue
        }
        if frameCount == stackBase {
            break
        }
        frameCount -= 1
        let frame = frames![frameCount]
        node = frame.node
        index = frame.index
    }
}

func checkDirty(_ start: LinkPtr, _ startSub: NodePtr) -> Bool {
    walkDepth += 1
    let dirty = checkDirtyWalk(start, startSub)
    walkDepth -= 1
    if walkDepth == 0 {
        while let link = deferredLinks.popLast() {
            releaseLink(link)
        }
    }
    return dirty
}

private func checkDirtyWalk(_ start: LinkPtr, _ startSub: NodePtr) -> Bool {
    var link = start
    var sub = startSub
    var checkDepth = 0
    var dirty = false
    top: while true {
        let dep = link.pointee.dep
        let flags = dep.pointee.flags
        if sub.pointee.flags & 16 != 0 {
            dirty = true
        } else if flags & (1 | 16) == (1 | 16) {
            if update(dep) {
                // JS: subs.nextSub !== undefined
                if dep.pointee.sinkCount > 1 {
                    shallowPropagate(dep)
                }
                dirty = true
            }
        } else if flags & (1 | 32) == (1 | 32) {
            checkStack.append(link)
            link = dep.pointee.deps!
            sub = dep
            checkDepth += 1
            continue
        }
        if !dirty {
            if let nextDep = link.pointee.nextDep {
                link = nextDep
                continue
            }
        }
        while checkDepth > 0 {
            checkDepth -= 1
            link = checkStack.removeLast()
            if dirty {
                if update(sub) {
                    if sub.pointee.sinkCount > 1 {
                        shallowPropagate(sub)
                    }
                    sub = link.pointee.sub
                    continue
                }
                dirty = false
            } else {
                sub.pointee.flags &= ~32
            }
            sub = link.pointee.sub
            if let nextDep = link.pointee.nextDep {
                link = nextDep
                continue top
            }
        }
        return dirty && sub.pointee.flags != 0
    }
}

// JS: shallowPropagate(link = dep.subs)
func shallowPropagate(_ dep: NodePtr) {
    var i: Int32 = 0
    while i < dep.pointee.sinkCount {
        let sub = dep.pointee.sinks[Int(i)].sub
        let flags = sub.pointee.flags
        if flags & (32 | 16) == 32 {
            sub.pointee.flags = flags | 16
            if flags & (2 | 4) == 2 {
                notify(sub)
            }
        }
        i += 1
    }
}

func isValidLink(_ checkLink: LinkPtr, _ sub: NodePtr) -> Bool {
    var link = sub.pointee.depsTail
    while let l = link {
        if l == checkLink {
            return true
        }
        link = l.pointee.prevDep
    }
    return false
}
