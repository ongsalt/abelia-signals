import Testing

extension Conformance {
    @Suite
    struct TrapTests {
        struct Derived: Rule {
            @Attribute var input: Int
            var value: Int { input }
        }

        @Test("creating an attribute with no current subgraph")
        func noSubgraph() async {
            await #expect(processExitsWith: .failure) {
                Subgraph.current = nil
                _ = Attribute(value: 1)
            }
        }

        @Test("setting the value of a computed attribute that has inputs and a value")
        func setComputed() async {
            await #expect(processExitsWith: .failure) {
                withGraph {
                    let input = Attribute(value: 1)
                    let derived = Attribute(Derived(input: input))
                    _ = derived.value
                    _ = derived.setValue(2)
                }
            }
        }

        @Test("setting a value through an indirect attribute")
        func setIndirect() async {
            await #expect(processExitsWith: .failure) {
                withGraph {
                    let indirect = IndirectAttribute(source: Attribute(value: 1))
                    indirect.value = 2
                }
            }
        }
    }
}
