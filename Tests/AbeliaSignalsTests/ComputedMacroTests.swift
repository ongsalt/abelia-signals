import AbeliaSignals
import Testing

@MainActor private let globalBase = Signal(3)
@MainActor @Computed private var globalDoubled: Int { globalBase.value * 2 }

private final class MacroCart {
    struct Item {
        var id: Int
        var price: Double
    }

    @Signal var items: [Item] = []
    let taxRate: Double
    var runs = 0

    @Computed var subtotal: Double {
        runs += 1
        return items.reduce(0) { $0 + $1.price }
    }

    @Computed var total: Double {
        subtotal * (1 + taxRate)
    }

    @Computed(equals: { (a: Item?, b: Item?) in a?.id == b?.id })
    var first: Item? {
        items.first
    }

    @Computed(equals: nil)
    var always: Int {
        items.count
    }

    @MainActor static let sharedCount = Signal(1)
    @MainActor @Computed static var sharedTriple: Int { sharedCount.value * 3 }

    init(taxRate: Double = 0.25) {
        self.taxRate = taxRate
    }
}

private final class GenericBox<T: Equatable> {
    @Signal var values: [T] = []
    @Computed var count: Int { values.count }
}

@MainActor
private final class MainActorModel {
    @Signal var x = 2
    @Computed var squared: Int { x * x }
}

@Suite(.serialized)
struct ComputedMacroTests {
    @Test("class @Computed: implicit self, chaining, custom equals, equals: nil, no retain cycle")
    func classComputed() {
        weak var weakCart: MacroCart?
        do {
            let cart = MacroCart(taxRate: 0.2)
            weakCart = cart

            cart.items = [.init(id: 1, price: 10), .init(id: 2, price: 15)]
            #expect(cart.runs == 0)
            #expect(cart.total == 30)
            #expect(cart.total == 30)
            #expect(cart.runs == 1)

            var firstRuns = 0
            let e1 = Effect.immediate { firstRuns += 1; blackHole(cart.first) }
            cart.items = [.init(id: 1, price: 20), .init(id: 2, price: 5)]
            #expect(firstRuns == 1)

            var alwaysRuns = 0
            let e2 = Effect.immediate { alwaysRuns += 1; blackHole(cart.always) }
            cart.items = [.init(id: 1, price: 20), .init(id: 2, price: 5)]
            #expect(alwaysRuns == 2)

            e1.dispose()
            e2.dispose()
        }
        #expect(weakCart == nil)
    }

    @Test("generic class @Computed")
    func genericClass() {
        let box = GenericBox<String>()
        box.values = ["a", "b"]
        #expect(box.count == 2)
    }

    @Test("local function @Computed (component style)")
    func localFunction() {
        @Signal var count = 1
        @Computed var doubled = count * 2
        @Computed(equals: nil) var uncachedCutoff = count * 0
        @Computed({
            let base = count
            return base + 10
        }) var multiLine: Int

        var seen: [Int] = []
        let e1 = Effect.immediate { seen.append(doubled) }

        var alwaysRuns = 0
        let e2 = Effect.immediate { alwaysRuns += 1; blackHole(uncachedCutoff) }

        count = 4
        #expect(seen == [2, 8])
        #expect(alwaysRuns == 2)
        #expect(multiLine == 14)
        blackHole(e1)
        blackHole(e2)
    }

    @Test("global and static @Computed")
    @MainActor
    func globalAndStatic() {
        globalBase.value = 3
        #expect(globalDoubled == 6)
        globalBase.value = 7
        #expect(globalDoubled == 14)

        MacroCart.sharedCount.value = 4
        #expect(MacroCart.sharedTriple == 12)
    }

    @Test("@MainActor class @Computed")
    @MainActor
    func mainActor() {
        let m = MainActorModel()
        #expect(m.squared == 4)
        m.x = 5
        #expect(m.squared == 25)
    }
}
