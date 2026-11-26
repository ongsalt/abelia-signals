import Testing

extension Conformance {
    @Suite
    struct RuleTests {
        struct Constant: Rule {
            var value: String { "computed" }
        }

        struct Derived: Rule {
            @Attribute var input: String
            var value: String { "derived: \(input)" }
        }

        struct Modified: Rule {
            @Attribute var input: Int
            var value: String {
                _ = input
                return "modified = \(AnyAttribute.currentWasModified)"
            }
        }

        struct Adder: Rule {
            @Attribute var input: Int
            var k: Int
            let counter: Counter
            var value: Int {
                counter.runs += 1
                return input &+ k
            }
        }

        @Test
        func value() {
            withGraph {
                #expect(Attribute(Constant()).value == "computed")
            }
        }

        // `initialValue:` is Compute (and SignalGraph) only: AttributeGraph has `static var initialValue`
        #if !AG
        @Test("an initial value is the value until invalidated")
        func initialValue() {
            withGraph {
                let attribute = Attribute(Constant(), initialValue: "initial")
                #expect(attribute.value == "initial")
                attribute.invalidateValue()
                #expect(attribute.value == "computed")
            }
        }
        #endif

        @Test
        func input() {
            withGraph {
                let input = Attribute(Constant())
                #expect(Attribute(Derived(input: input)).value == "derived: computed")
            }
        }

        // `initialValue:` is Compute (and SignalGraph) only: AttributeGraph has `static var initialValue`
        #if !AG
        @Test("an input's initial value is what dependents see")
        func inputInitialValue() {
            withGraph {
                let input = Attribute(Constant(), initialValue: "initial")
                let derived = Attribute(Derived(input: input))
                #expect(derived.value == "derived: initial")
                input.invalidateValue()
                #expect(derived.value == "derived: computed")
            }
        }
        #endif

        @Test("currentWasModified: after mutateBody(invalidating: true) or invalidateValue, not an input change")
        func currentWasModified() {
            withGraph {
                let input = Attribute(value: 0)
                let attribute = Attribute(Modified(input: input))
                #expect(attribute.value == "modified = false")
                attribute.mutateBody(as: Modified.self, invalidating: false) { _ in }
                #expect(attribute.value == "modified = false")
                input.value = 1
                #expect(attribute.value == "modified = false")
                attribute.mutateBody(as: Modified.self, invalidating: true) { _ in }
                #expect(attribute.value == "modified = true")
                input.value = 2
                #expect(attribute.value == "modified = false")
                attribute.invalidateValue()
                #expect(attribute.value == "modified = true")
            }
        }

        @Test("mutateBody: the new body is used once invalidated")
        func mutateBodyFields() {
            withGraph {
                let input = Attribute(value: 1)
                let counter = Counter()
                let attribute = Attribute(Adder(input: input, k: 0, counter: counter))
                #expect(attribute.value == 1)
                attribute.mutateBody(as: Adder.self, invalidating: false) { $0.k = 100 }
                #expect(attribute.value == 1)
                #expect(counter.runs == 1)
                attribute.mutateBody(as: Adder.self, invalidating: true) { $0.k = 10 }
                #expect(attribute.value == 11)
                input.value = 2
                #expect(attribute.value == 12)
                #expect(counter.runs == 3)
            }
        }

        @Test
        func map() {
            withGraph {
                let input = Attribute(value: 3)
                let doubled = Attribute(Map(input) { $0 * 2 })
                #expect(doubled.value == 6)
                input.value = 4
                #expect(doubled.value == 8)
            }
        }
    }

    @Suite
    struct StatefulRuleTests {
        struct Constant: StatefulRule {
            typealias Value = String
            func updateValue() {
                value = "computed"
            }
        }

        struct Derived: StatefulRule {
            typealias Value = String
            @Attribute var input: String
            func updateValue() {
                value = "derived: \(input)"
            }
        }

        struct RunningSum: StatefulRule {
            typealias Value = Int
            @Attribute var input: Int
            func updateValue() {
                value = (hasValue ? value : 0) &+ input
            }
        }

        // state kept in the body between updates
        struct Counting: StatefulRule {
            typealias Value = Int
            @Attribute var input: Int
            var count = 0
            mutating func updateValue() {
                _ = input
                count += 1
                value = count
            }
        }

        @Test
        func value() {
            withGraph {
                #expect(Attribute(Constant()).value == "computed")
            }
        }

        // `initialValue:` is Compute (and SignalGraph) only: AttributeGraph has `static var initialValue`
        #if !AG
        @Test("an initial value is the value until invalidated")
        func initialValue() {
            withGraph {
                let attribute = Attribute(Constant(), initialValue: "initial")
                #expect(attribute.value == "initial")
                attribute.invalidateValue()
                #expect(attribute.value == "computed")
            }
        }
        #endif

        // `initialValue:` is Compute (and SignalGraph) only: AttributeGraph has `static var initialValue`
        #if !AG
        @Test
        func inputInitialValue() {
            withGraph {
                let input = Attribute(Constant(), initialValue: "initial")
                let derived = Attribute(Derived(input: input))
                #expect(derived.value == "derived: initial")
                input.invalidateValue()
                #expect(derived.value == "derived: computed")
            }
        }
        #endif

        @Test("value reads the previous output")
        func runningSum() {
            withGraph {
                let input = Attribute(value: 1)
                let sum = Attribute(RunningSum(input: input))
                var seen = [sum.value]
                for v in [2, 3] {
                    input.value = v
                    seen.append(sum.value)
                }
                seen.append(sum.value)
                #expect(seen == [1, 3, 6, 6])
            }
        }

        // `initialValue:` is Compute (and SignalGraph) only: AttributeGraph has `static var initialValue`
        #if !AG
        @Test("an initial value: no run yet, so no inputs; once invalidated it's the previous output")
        func runningSumFromInitialValue() {
            withGraph {
                let input = Attribute(value: 1)
                let sum = Attribute(RunningSum(input: input), initialValue: 100)
                #expect(sum.value == 100)
                input.value = 2
                #expect(sum.value == 100)
                sum.invalidateValue()
                #expect(sum.value == 102)
                input.value = 3
                #expect(sum.value == 105)
            }
        }
        #endif

        @Test("mutating the body in updateValue persists")
        func bodyState() {
            withGraph {
                let input = Attribute(value: 0)
                let counting = Attribute(Counting(input: input))
                #expect(counting.value == 1)
                input.value = 1
                #expect(counting.value == 2)
                input.value = 2
                #expect(counting.value == 3)
            }
        }
    }
}
