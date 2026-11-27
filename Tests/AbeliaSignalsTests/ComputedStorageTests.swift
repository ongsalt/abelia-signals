import AbeliaSignals
import Testing

private final class Cart {
    struct Entry {
        var id: Int
        var price: Double
    }

    @Signal var items: [Entry] = []
    let taxRate: Double
    var computeCount = 0

    private let _subtotal = ComputedStorage<Cart, Double> {
        $0.computeCount += 1
        return $0.items.reduce(0) { $0 + $1.price }
    }
    var subtotal: Double { _subtotal.value(self) }
    var subtotalPeek: Double { _subtotal.peek(self) }

    private let _total = ComputedStorage<Cart, Double> {
        $0.subtotal * (1 + $0.taxRate)
    }
    var total: Double { _total.value(self) }

    private let _first = ComputedStorage<Cart, Entry?>(equals: { $0?.id == $1?.id }) {
        $0.items.first
    }
    var first: Entry? { _first.value(self) }

    init(taxRate: Double = 0.1) {
        self.taxRate = taxRate
    }
}

private final class Store {
    @Signal var ids: [Int] = []

    private let _rows = ComputedStorage<Store, [RowVM]> { store in
        store.ids.map { RowVM(store: store, id: $0) }
    }
    var rows: [RowVM] { _rows.value(self) }
}

private final class RowVM {
    unowned let store: Store
    let id: Int

    private let _isLast = ComputedStorage<RowVM, Bool> { row in
        row.store.rows.last === row
    }
    var isLast: Bool { _isLast.value(self) }

    init(store: Store, id: Int) {
        self.store = store
        self.id = id
    }
}

@MainActor
private final class MainActorCart {
    @Signal var count = 0

    private let _doubled = ComputedStorage<MainActorCart, Int> { $0.count * 2 }
    var doubled: Int { _doubled.value(self) }
}

@Suite(.serialized)
struct ComputedStorageTests {
    @Test("lazy caching, chaining, and plain property access")
    func basics() {
        let cart = Cart(taxRate: 0.2)
        #expect(cart.computeCount == 0)

        cart.items = [.init(id: 1, price: 10), .init(id: 2, price: 15)]
        #expect(cart.computeCount == 0)
        #expect(cart.total == 30)
        #expect(cart.computeCount == 1)

        // cached read does not recompute
        #expect(cart.subtotal == 25)
        #expect(cart.computeCount == 1)

        // write that preserves total value still stops downstream via Equatable cutoff
        var seen: [Double] = []
        let e = Effect.immediate { seen.append(cart.total) }
        cart.items = [.init(id: 1, price: 20), .init(id: 2, price: 5)]
        #expect(cart.computeCount == 2)
        #expect(seen == [30])

        cart.items = [.init(id: 1, price: 50)]
        #expect(seen == [30, 60])
        blackHole(e)
    }

    @Test("custom equals and optional value")
    func customEqualsAndOptional() {
        let cart = Cart()
        var runs = 0
        let e = Effect.immediate {
            runs += 1
            blackHole(cart.first)
        }
        #expect(cart.first == nil)
        #expect(runs == 1)

        cart.items = [.init(id: 1, price: 10)]
        #expect(cart.first?.id == 1)
        #expect(runs == 2)

        // same id -> equals cutoff
        cart.items = [.init(id: 1, price: 99)]
        #expect(runs == 2)

        cart.items = [.init(id: 2, price: 5)]
        #expect(runs == 3)
        blackHole(e)
    }

    @Test("peek does not track")
    func peekUntracked() {
        let cart = Cart()
        var runs = 0
        let e = Effect.immediate {
            runs += 1
            blackHole(cart.subtotalPeek)
        }
        #expect(runs == 1)
        cart.items = [.init(id: 1, price: 10)]
        #expect(runs == 1)
        blackHole(e)
    }

    @Test("no retain cycle: owner deallocates with active chained computeds")
    func noRetainCycle() {
        weak var weakCart: Cart?
        do {
            let cart = Cart(taxRate: 0.25)
            weakCart = cart
            cart.items = [.init(id: 1, price: 10)]
            #expect(cart.total == 12.5)
        }
        #expect(weakCart == nil)
    }

    @Test("owner deallocates while a weak sink is still alive and pulling")
    func ownerDiesDuringPull() {
        let store = Store()
        store.ids = [1, 2]

        weak var weakRow: RowVM?
        var seen: [Bool] = []
        let effect: Effect
        do {
            let row = store.rows[1]
            weakRow = row
            effect = Effect.immediate { [weak row] in
                guard let row else { return }
                seen.append(row.isLast)
            }
        }
        #expect(seen == [true])

        // Dropping row 2 during pull must not UAF or OOB, and should not rerun the dead-row effect
        store.ids = [1]
        #expect(weakRow == nil)
        #expect(seen == [true])
        blackHole(effect)
    }

    @Test("MainActor isolated class")
    @MainActor
    func mainActorClass() {
        let cart = MainActorCart()
        var seen: [Int] = []
        let e = Effect.immediate { seen.append(cart.doubled) }
        cart.count = 3
        #expect(seen == [0, 6])
        blackHole(e)
    }
}
