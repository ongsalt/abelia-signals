import Testing

extension Conformance {
    @Suite
    struct UpdateTests {
        struct Plus: Rule {
            @Attribute var input: Int
            let k: Int
            var value: Int { input &+ k }
        }

        struct Div1000: Rule {
            @Attribute var input: Int
            var value: Int { input / 1000 }
        }

        struct Read<T>: Rule {
            @Attribute var input: T
            let counter: Counter
            var value: T {
                counter.runs += 1
                return input
            }
        }

        struct Sum2: Rule {
            @Attribute var a: Int
            @Attribute var b: Int
            let counter: Counter
            var value: Int {
                counter.runs += 1
                return a &+ b
            }
        }

        struct Pick: Rule {
            @Attribute var flag: Bool
            @Attribute var a: Int
            @Attribute var b: Int
            let counter: Counter
            var value: Int {
                counter.runs += 1
                return flag ? a : b
            }
        }

        struct Untracked: Rule {
            @Attribute var input: Int
            let counter: Counter
            var value: Int {
                counter.runs += 1
                return Graph.withoutUpdate { input }
            }
        }

        // not Equatable: POD, and not POD
        struct PlainPOD {
            var x: Int
        }

        struct PlainBoxed {
            var s: String
        }

        struct ToPlainPOD: Rule {
            @Attribute var input: Int
            var value: PlainPOD { PlainPOD(x: input / 1000) }
        }

        struct ToPlainBoxed: Rule {
            @Attribute var input: Int
            var value: PlainBoxed { PlainBoxed(s: input < 1000 ? "small" : "big") }
        }

        struct ToNaN: Rule {
            @Attribute var input: Int
            var value: Double { input >= 0 ? .nan : 0 }
        }

        @Test("diamond: the bottom reruns once per write")
        func diamond() {
            withGraph {
                let a = Attribute(value: 0)
                let b = Attribute(Plus(input: a, k: 1))
                let c = Attribute(Plus(input: a, k: 2))
                let counter = Counter()
                let d = Attribute(Sum2(a: b, b: c, counter: counter))
                #expect(d.value == 3)
                a.value = 10
                #expect(d.value == 23)
                #expect(counter.runs == 2)
            }
        }

        @Test("lazy: writes don't run rules, reads do, once")
        func lazy() {
            withGraph {
                let a = Attribute(value: 0)
                let counter = Counter()
                let c = Attribute(Read(input: a, counter: counter))
                for i in 1...10 { a.value = i }
                #expect(counter.runs == 0)
                #expect(c.value == 10)
                #expect(c.value == 10)
                #expect(counter.runs == 1)
            }
        }

        @Test("cutoff: an unchanged Equatable value doesn't rerun dependents")
        func cutoff() {
            withGraph {
                let a = Attribute(value: 0)
                let b = Attribute(Div1000(input: a))
                let counter = Counter()
                let c = Attribute(Read(input: b, counter: counter))
                _ = c.value
                a.value = 1
                _ = c.value
                #expect(counter.runs == 1)
                a.value = 1000
                #expect(c.value == 1)
                #expect(counter.runs == 2)
            }
        }

        @Test("cutoff: a POD value that isn't Equatable compares by its bits")
        func cutoffPOD() {
            withGraph {
                let a = Attribute(value: 0)
                let counter = Counter()
                let c = Attribute(Read(input: Attribute(ToPlainPOD(input: a)), counter: counter))
                _ = c.value
                a.value = 1
                _ = c.value
                knownDifference("SignalGraph: not Equatable means always changed") {
                    #expect(counter.runs == 1)
                }
            }
        }

        @Test("cutoff: a non-POD value that isn't Equatable compares by its fields")
        func cutoffNonPOD() {
            withGraph {
                let a = Attribute(value: 0)
                let counter = Counter()
                let c = Attribute(Read(input: Attribute(ToPlainBoxed(input: a)), counter: counter))
                _ = c.value
                a.value = 1
                _ = c.value
                knownDifference("SignalGraph: not Equatable means always changed") {
                    #expect(counter.runs == 1)
                }
            }
        }

        @Test("cutoff: a rule's NaN output compares by its bits")
        func cutoffNaN() {
            withGraph {
                let a = Attribute(value: 0)
                let counter = Counter()
                let c = Attribute(Read(input: Attribute(ToNaN(input: a)), counter: counter))
                _ = c.value
                a.value = 1
                _ = c.value
                knownDifference("SignalGraph: Double uses ==, and NaN != NaN") {
                    #expect(counter.runs == 1)
                }
            }
        }

        @Test("an external compares with ==: writing NaN over NaN is a change")
        func externalNaN() {
            withGraph {
                let a = Attribute(value: Double.nan)
                #expect(a.setValue(.nan) == true)
            }
        }

        @Test("dynamic deps: an input the last run didn't read doesn't rerun it")
        func dynamicDeps() {
            withGraph {
                let flag = Attribute(value: true)
                let a = Attribute(value: 1)
                let b = Attribute(value: 2)
                let counter = Counter()
                let c = Attribute(Pick(flag: flag, a: a, b: b, counter: counter))
                #expect(c.value == 1)
                flag.value = false
                #expect(c.value == 2)
                counter.runs = 0
                a.value = 10
                #expect(c.value == 2)
                #expect(counter.runs == 0)
                b.value = 20
                #expect(c.value == 20)
                #expect(counter.runs == 1)
            }
        }

        @Test("Graph.withoutUpdate: reads inside aren't inputs")
        func withoutUpdate() {
            withGraph {
                let a = Attribute(value: 1)
                let counter = Counter()
                let c = Attribute(Untracked(input: a, counter: counter))
                #expect(c.value == 1)
                a.value = 2
                #expect(c.value == 1)
                #expect(counter.runs == 1)
            }
        }

        @Test("a long chain stays live")
        func chain() {
            withGraph {
                let head = Attribute(value: 0)
                var node = Attribute(Plus(input: head, k: 1))
                for _ in 1..<100 { node = Attribute(Plus(input: node, k: 1)) }
                for _ in 0..<5 {
                    head.value &+= 1
                    _ = node.value
                }
                #expect(node.value == 105)
            }
        }
    }

    @Suite
    struct ExternalTests {
        @Test
        func value() {
            withGraph {
                let attribute = Attribute(value: 1)
                #expect(attribute.value == 1)
                attribute.value = 2
                #expect(attribute.value == 2)
            }
        }

        @Test("setValue returns whether it changed")
        func setValue() {
            withGraph {
                let attribute = Attribute(value: 0)
                #expect(attribute.setValue(0) == false)
                #expect(attribute.setValue(1) == true)
                #expect(attribute.value == 1)
            }
        }

        @Test("Attribute(type:) has no value until set")
        func noValue() {
            withGraph {
                let attribute = Attribute(type: Int.self)
                #expect(attribute.hasValue == false)
                #expect(attribute.setValue(3) == true)
                #expect(attribute.hasValue == true)
                #expect(attribute.value == 3)
            }
        }

        @Test
        func hasValue() {
            withGraph {
                #expect(Attribute(value: 1).hasValue == true)
            }
        }
    }
}
