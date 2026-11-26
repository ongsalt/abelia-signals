import Testing

extension Conformance {
    @Suite
    struct ChangedValueTests {
        struct WhichChanged: Rule {
            @Attribute var a: Int
            @Attribute var b: Int
            let log: Log
            var value: Int {
                let (av, ac) = context.changedValue(of: $a, options: [])
                let (bv, bc) = context.changedValue(of: $b, options: [])
                log.entries.append(ac || bc ? (ac ? "a" : "") + (bc ? "b" : "") : "-")
                return av &+ bv
            }
        }

        // same, through Attribute.changedValue() while the rule is current
        struct WhichChangedDirect: Rule {
            @Attribute var a: Int
            @Attribute var b: Int
            let log: Log
            var value: Int {
                let (av, ac) = $a.changedValue()
                let (bv, bc) = $b.changedValue()
                log.entries.append(ac || bc ? (ac ? "a" : "") + (bc ? "b" : "") : "-")
                return av &+ bv
            }
        }

        struct Plus: Rule {
            @Attribute var input: Int
            var value: Int { input }
        }

        @Test("context.changedValue(of:): changed since this rule last ran")
        func contextChangedValue() {
            withGraph {
                let a = Attribute(value: 1)
                let b = Attribute(value: 2)
                let log = Log()
                let c = Attribute(WhichChanged(a: a, b: b, log: log))
                _ = c.value
                b.value = 20
                _ = c.value
                a.value = 10
                b.value = 30
                _ = c.value
                #expect(log.entries == ["ab", "b", "ab"])
            }
        }

        @Test("Attribute.changedValue() inside a rule: relative to that rule")
        func attributeChangedValueInRule() {
            withGraph {
                let a = Attribute(value: 1)
                let b = Attribute(value: 2)
                let log = Log()
                let c = Attribute(WhichChangedDirect(a: a, b: b, log: log))
                _ = c.value
                a.value = 10
                _ = c.value
                #expect(log.entries == ["ab", "a"])
            }
        }

        @Test("changedValue() outside a rule: whether this read recomputed a new value")
        func outside() {
            withGraph {
                let a = Attribute(value: 0)
                let c = Attribute(Plus(input: a))
                #expect(c.changedValue().changed == true)
                #expect(c.changedValue().changed == false)
                a.value = 1
                #expect(c.changedValue() == (1, true))
                a.value = 2
                #expect(a.changedValue().changed == false)
            }
        }
    }

    @Suite
    struct RuleContextTests {
        struct Current: Rule {
            let log: Log
            var value: Int {
                log.entries.append(AnyAttribute.current == attribute.identifier ? "current" : "other")
                return 0
            }
        }

        struct Subscripted: Rule {
            @Attribute var input: Int
            #if SIGNALGRAPH || AG
            var value: Int { context[attribute: $input] &+ 1 }
            #else
            // Compute's spelling
            var value: Int { context[$input] &+ 1 }
            #endif
        }

        @Test("AnyAttribute.current is the rule being updated")
        func currentInRule() {
            withGraph {
                let log = Log()
                let attribute = Attribute(Current(log: log))
                _ = attribute.value
                #expect(log.entries == ["current"])
                #expect(AnyAttribute.current == nil)
            }
        }

        @Test
        func anyRuleContextUpdateMakesAttributeCurrent() {
            withGraph {
                let attribute = Attribute(value: 1)
                var current: AnyAttribute?
                var calls = 0
                AnyRuleContext(attribute: attribute.identifier).update {
                    current = AnyAttribute.current
                    calls += 1
                }
                #expect(calls == 1)
                #expect(current == attribute.identifier)
                #expect(AnyAttribute.current == nil)
            }
        }

        @Test
        func ruleContextUpdateMakesAttributeCurrent() {
            withGraph {
                let attribute = Attribute(value: 1)
                var current: AnyAttribute?
                RuleContext(attribute: attribute).update {
                    current = AnyAttribute.current
                }
                #expect(current == attribute.identifier)
                #expect(AnyAttribute.current == nil)
            }
        }

        @Test("context[input] reads the input")
        func subscriptInput() {
            withGraph {
                let input = Attribute(value: 1)
                let attribute = Attribute(Subscripted(input: input))
                #expect(attribute.value == 2)
                input.value = 5
                #expect(attribute.value == 6)
            }
        }
    }
}
