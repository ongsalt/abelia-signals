import Testing

extension Conformance {
    @Suite
    struct FocusTests {
        struct Pair {
            var a: Int
            var b: String
        }

        struct Read<T>: Rule {
            @Attribute var input: T
            let counter: Counter
            var value: T {
                counter.runs += 1
                return input
            }
        }

        @Test("a member attribute follows its field, and only its field")
        func member() {
            withGraph {
                let pair = Attribute(value: Pair(a: 1, b: "x"))
                let counter = Counter()
                let a = Attribute(Read(input: pair.a, counter: counter))
                #expect(a.value == 1)
                pair.value.b = "y"
                #expect(a.value == 1)
                #expect(counter.runs == 1)
                pair.value.a = 2
                #expect(a.value == 2)
                #expect(counter.runs == 2)
            }
        }

        @Test
        func keyPathSubscript() {
            withGraph {
                let pair = Attribute(value: Pair(a: 1, b: "x"))
                #expect(pair[keyPath: \.b].value == "x")
            }
        }

        @Test
        func focus() {
            withGraph {
                let pair = Attribute(value: Pair(a: 1, b: "x"))
                let b = Attribute(Focus(root: pair, keyPath: \.b))
                pair.value.b = "z"
                #expect(b.value == "z")
            }
        }
    }

    @Suite
    struct IndirectAttributeTests {
        struct Read<T>: Rule {
            @Attribute var input: T
            let counter: Counter
            var value: T {
                counter.runs += 1
                return input
            }
        }

        @Test
        func initWithSource() {
            withGraph {
                let source = Attribute(value: 1)
                let indirect = IndirectAttribute(source: source)
                #expect(indirect.identifier != source.identifier)
                #expect(indirect.source.identifier == source.identifier)
                #expect(indirect.attribute.identifier == indirect.identifier)
                #expect(indirect.value == 1)
            }
        }

        @Test("switching the source: dependents follow, the old source no longer reruns them")
        func source() {
            withGraph {
                let x = Attribute(value: 1)
                let y = Attribute(value: 2)
                let indirect = IndirectAttribute(source: x)
                let counter = Counter()
                let c = Attribute(Read(input: indirect.projectedValue, counter: counter))
                #expect(c.value == 1)
                indirect.source = y
                #expect(indirect.source.identifier == y.identifier)
                #expect(c.value == 2)
                counter.runs = 0
                x.value = 10
                #expect(c.value == 2)
                #expect(counter.runs == 0)
                y.value = 20
                #expect(c.value == 20)
            }
        }

        // Compute (and SignalGraph) only: not in AttributeGraph's Swift API
        #if !AG
        @Test
        func resetSource() {
            withGraph {
                let x = Attribute(value: 1)
                let y = Attribute(value: 2)
                let indirect = IndirectAttribute(source: x)
                indirect.source = y
                #expect(indirect.value == 2)
                indirect.resetSource()
                #expect(indirect.source.identifier == x.identifier)
                #expect(indirect.value == 1)
            }
        }
        #endif
    }

    @Suite
    struct WeakAttributeTests {
        #if !AG
        @Test
        func initDefault() {
            withGraph {
                #expect(WeakAttribute<Int>().attribute == nil)
            }
        }
        #endif

        @Test
        func initWithNil() {
            withGraph {
                #expect(WeakAttribute<Int>(nil as Attribute<Int>?).attribute == nil)
            }
        }

        @Test
        func initWithAttribute() {
            withGraph {
                let attribute = Attribute(value: 7)
                let weak = WeakAttribute(attribute)
                #expect(weak.attribute == attribute)
                #expect(weak.value == 7)
            }
        }

        @Test("invalidating the subgraph nils it")
        func invalidatingSubgraph() throws {
            try withGraph {
                let root = try #require(Subgraph.current)
                let subgraph = Subgraph(graph: root.graph)
                root.addChild(subgraph)
                let weak = subgraph.apply { WeakAttribute(Attribute(value: 0)) }
                #expect(weak.attribute != nil)
                subgraph.invalidate()
                #expect(weak.attribute == nil)
                #expect(weak.value == nil)
            }
        }
    }

    @Suite
    struct OptionalAttributeTests {
        @Test
        func empty() {
            withGraph {
                let empty = OptionalAttribute<Int>(nil as Attribute<Int>?)
                #expect(empty.attribute == nil)
                #expect(empty.value == nil)
            }
        }

        @Test
        func withAttribute() {
            withGraph {
                let attribute = Attribute(value: 3)
                let optional = OptionalAttribute(attribute)
                #expect(optional.attribute == attribute)
                #expect(optional.value == 3)
            }
        }
    }
}
