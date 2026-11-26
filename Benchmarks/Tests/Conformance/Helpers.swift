// AttributeGraph conformance, shared by every backend (symlinked as `Shared` into each test target):
//   SignalGraphConformance → SignalGraph (`-D SIGNALGRAPH`)
//   ComputeConformance     → Compute
//   AGConformance          → Apple's AttributeGraph via OpenAttributeGraphShims (macOS, `-D AG`)
// Expected values are what Compute does. Some cases are ported from Compute's own tests
// (MIT, James Moschou), keeping only the public API. SignalGraph's deliberate differences are
// `knownDifference`s.

import Testing

/// Everything here shares `Subgraph.current` and SignalGraph's graph state.
@Suite(.serialized)
struct Conformance {}

final class Counter {
    var runs = 0
}

final class Log {
    var entries: [String] = []
}

/// A graph and its root subgraph, current while `body` runs.
func withGraph<T>(_ body: () throws -> T) rethrows -> T {
    #if AG
    precondition(
        backendIsAttributeGraph,
        "AGConformance isn't linked against Apple's AttributeGraph; build with OPENATTRIBUTEGRAPH_OPENATTRIBUTESHIMS_ATTRIBUTEGRAPH=1"
    )
    #endif
    let graph = Graph()
    let subgraph = Subgraph(graph: graph)
    let saved = Subgraph.current
    Subgraph.current = subgraph
    defer {
        Subgraph.current = saved
        subgraph.invalidate()
        withExtendedLifetime(graph) {}
    }
    return try body()
}

/// Identity, whatever `Subgraph` is on the backend (a Swift class, or a CF/C++ reference).
func same(_ a: Subgraph?, _ b: Subgraph?) -> Bool {
    unsafeBitCast(a, to: UnsafeRawPointer?.self) == unsafeBitCast(b, to: UnsafeRawPointer?.self)
}

/// Where SignalGraph differs from AttributeGraph on purpose.
func knownDifference(_ comment: Comment, _ body: () -> Void) {
    #if SIGNALGRAPH
    withKnownIssue(comment, body)
    #else
    body()
    #endif
}
