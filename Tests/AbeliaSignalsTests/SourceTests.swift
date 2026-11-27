import AbeliaSignals
import Testing

private func readTwice(_ source: some Source<Int>) -> Int { source.value + source.peek }
private func addOne(_ source: some MutableSource<Int>) { source.value += 1 }

@Suite(.serialized)
struct SourceTests {
    @Test("Source, MutableSource, Getter, and Binding")
    func basics() {
        let s = Signal(1)
        let c = Computed { s.value * 10 }
        let g = s.getter
        let b = Binding(s)
        let cents = Binding(get: { s.value * 100 }, set: { s.value = $0 / 100 })

        #expect(readTwice(s) == 2)
        #expect(readTwice(c) == 20)
        #expect(readTwice(g) == 2)
        #expect(readTwice(Getter.constant(5)) == 10)

        var seen: [Int] = []
        let e = Effect.immediate { seen.append(g.value) }
        addOne(b)
        cents.value = 300
        #expect(seen == [1, 2, 3])
        #expect(g.peek == 3)
        blackHole(e)
    }
}
