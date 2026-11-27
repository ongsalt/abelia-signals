import AbeliaSignals
import Testing

final class Model {
    @Signal var count = 0
    @Signal var name = "a"
}

struct Item {
    var id: Int
    var label: String
}

final class Holder {
    @Signal(equals: { $0.id == $1.id }) var item = Item(id: 1, label: "a")
    @Signal(equals: nil) var always = 0
}

struct Value {
    @Signal var x = 1
}

@Suite(.serialized)
struct PropertyWrapperTests {
    @Test("reads are tracked, writes notify")
    func tracked() {
        let model = Model()
        var seen: [Int] = []
        let e = Effect.immediate { seen.append(model.count) }
        model.count += 1
        model.count = 5
        #expect(seen == [0, 1, 5])
        blackHole(e)
    }

    @Test("Equatable: writing the same value is not a change")
    func equatableCutoff() {
        let model = Model()
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(model.name) }
        model.name = "a"
        #expect(runs == 1)
        model.name = "b"
        #expect(runs == 2)
        blackHole(e)
    }

    @Test("$x is the signal")
    func projection() {
        let model = Model()
        let c = Computed { model.$count.value * 2 }
        model.$count.update { $0 += 3 }
        #expect(model.count == 3)
        #expect(model.$count.peek == 3)
        #expect(c.value == 6)
    }

    @Test("custom equality")
    func customEquals() {
        let holder = Holder()
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(holder.item) }
        holder.item = Item(id: 1, label: "b")
        #expect(runs == 1)
        #expect(holder.item.label == "a")
        holder.item = Item(id: 2, label: "c")
        #expect(runs == 2)
        blackHole(e)
    }

    @Test("equals: nil, every write notifies")
    func noEquality() {
        let holder = Holder()
        var runs = 0
        let e = Effect.immediate { runs += 1; blackHole(holder.always) }
        holder.always = 0
        holder.always = 0
        #expect(runs == 3)
        blackHole(e)
    }

    @Test("local variables")
    func local() {
        @Signal var x = 1
        let c = Computed { x + 1 }
        #expect(c.value == 2)
        x = 10
        #expect(c.value == 11)
        #expect($x.peek == 10)
    }

    @Test("in a struct, copies share the signal")
    func structCopies() {
        let a = Value()
        let b = a
        b.x = 7
        #expect(a.x == 7)
    }
}
