import Testing

extension Conformance {
    @Suite
    struct SubgraphTests {
        @Test
        func current() {
            let saved = Subgraph.current
            defer { Subgraph.current = saved }
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            Subgraph.current = subgraph
            #expect(same(Subgraph.current, subgraph))
            Subgraph.current = nil
            #expect(Subgraph.current == nil)
        }

        @Test("invalidating the current subgraph clears current")
        func invalidateCurrent() {
            let saved = Subgraph.current
            defer { Subgraph.current = saved }
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            Subgraph.current = subgraph
            subgraph.invalidate()
            #expect(Subgraph.current == nil)
        }

        @Test("apply makes it current, then restores")
        func apply() throws {
            try withGraph {
                let root = try #require(Subgraph.current)
                let other = Subgraph(graph: root.graph)
                let inside = other.apply { Subgraph.current }
                #expect(same(inside, other))
                #expect(same(Subgraph.current, root))
            }
        }

        @Test
        func graph() {
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            #expect(unsafeBitCast(subgraph.graph, to: UnsafeRawPointer.self) == unsafeBitCast(graph, to: UnsafeRawPointer.self))
        }
    }

    @Suite
    struct SubgraphObserverTests {
        @Test("invalidate notifies observers, once")
        func invalidate() {
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            var notified = 0
            _ = subgraph.addObserver { notified += 1 }
            #expect(subgraph.isValid == true)
            #expect(notified == 0)
            subgraph.invalidate()
            #expect(subgraph.isValid == false)
            #expect(notified == 1)
            subgraph.invalidate()
            #expect(notified == 1)
        }

        @Test
        func removedObserverNotNotified() {
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            var notified = 0
            let id = subgraph.addObserver { notified += 1 }
            subgraph.removeObserver(numericCast(id))
            subgraph.invalidate()
            #expect(notified == 0)
        }

        @Test
        func removeObserverDuringInvalidation() {
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            var notified = 0
            var id = 0
            id = subgraph.addObserver {
                notified += 1
                subgraph.removeObserver(numericCast(id))
            }
            subgraph.invalidate()
            #expect(subgraph.isValid == false)
            #expect(notified == 1)
        }

        @Test("a subgraph going away notifies its observers")
        func notifiedOnSubgraphDestroyed() {
            var notified = 0
            let graph = Graph()
            do {
                let subgraph = Subgraph(graph: graph)
                _ = subgraph.addObserver { notified += 1 }
            }
            #expect(notified == 1)
            withExtendedLifetime(graph) {}
        }

        @Test("a graph going away invalidates its subgraphs")
        func notifiedOnGraphDestroyed() throws {
            var notified = 0
            var subgraph: Subgraph?
            do {
                let graph = Graph()
                subgraph = Subgraph(graph: graph)
                _ = subgraph!.addObserver { notified += 1 }
                #expect(notified == 0)
                #expect(subgraph!.isValid == true)
            }
            #expect(notified == 1)
            #expect(try #require(subgraph).isValid == false)
        }
    }

    @Suite
    struct SubgraphChildrenTests {
        @Test
        func child() {
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            #expect(subgraph.childCount == 0)
            let child = Subgraph(graph: graph)
            subgraph.addChild(child)
            #expect(subgraph.childCount == 1)
            #expect(same(subgraph.child(at: 0, tag: nil), child))
            #expect(subgraph.isAncestor(of: child) == true)
            #expect(child.parentCount == 1)
            #expect(same(child.parent(at: 0), subgraph))
            subgraph.removeChild(child)
            #expect(subgraph.childCount == 0)
            #expect(subgraph.isAncestor(of: child) == false)
            #expect(child.parentCount == 0)
        }

        @Test
        func multipleChildren() {
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            let child1 = Subgraph(graph: graph)
            let child2 = Subgraph(graph: graph)
            subgraph.addChild(child1)
            subgraph.addChild(child2)
            #expect(subgraph.childCount == 2)
            #expect(same(subgraph.child(at: 0, tag: nil), child1))
            #expect(same(subgraph.child(at: 1, tag: nil), child2))
            subgraph.removeChild(child1)
            #expect(subgraph.childCount == 1)
            #expect(same(subgraph.child(at: 0, tag: nil), child2))
            #expect(subgraph.isAncestor(of: child1) == false)
            #expect(subgraph.isAncestor(of: child2) == true)
            #expect(child1.parentCount == 0)
            #expect(child2.parentCount == 1)
        }

        @Test
        func multipleParents() {
            let graph = Graph()
            let parent1 = Subgraph(graph: graph)
            let parent2 = Subgraph(graph: graph)
            let child = Subgraph(graph: graph)
            parent1.addChild(child)
            parent2.addChild(child)
            #expect(child.parentCount == 2)
            #expect(same(child.parent(at: 0), parent1))
            #expect(same(child.parent(at: 1), parent2))
            parent1.removeChild(child)
            #expect(parent1.isAncestor(of: child) == false)
            #expect(parent2.isAncestor(of: child) == true)
            #expect(child.parentCount == 1)
            #expect(same(child.parent(at: 0), parent2))
        }

        @Test
        func invalidatingInvalidatesChildren() {
            let graph = Graph()
            let subgraph = Subgraph(graph: graph)
            let child = Subgraph(graph: graph)
            let grandchild = Subgraph(graph: graph)
            subgraph.addChild(child)
            child.addChild(grandchild)
            subgraph.invalidate()
            #expect(subgraph.isValid == false)
            #expect(child.isValid == false)
            #expect(grandchild.isValid == false)
        }

        @Test
        func ancestorThroughIntermediates() {
            let graph = Graph()
            let root1 = Subgraph(graph: graph)
            let root2 = Subgraph(graph: graph)
            let intermediate = Subgraph(graph: graph)
            let child = Subgraph(graph: graph)
            root1.addChild(intermediate)
            root2.addChild(intermediate)
            intermediate.addChild(child)
            #expect(intermediate.parentCount == 2)
            #expect(root1.isAncestor(of: child) == true)
            #expect(root2.isAncestor(of: child) == true)
            #expect(child.isAncestor(of: root1) == false)
        }

        @Test("an attribute in a child reads its parent's attributes")
        func crossSubgraph() throws {
            try withGraph {
                let root = try #require(Subgraph.current)
                let input = Attribute(value: 1)
                let child = Subgraph(graph: root.graph)
                root.addChild(child)
                let derived = child.apply { Attribute(Map(input) { $0 + 1 }) }
                #expect(derived.value == 2)
                input.value = 5
                #expect(derived.value == 6)
                child.invalidate()
                #expect(input.value == 5)
            }
        }
    }
}
