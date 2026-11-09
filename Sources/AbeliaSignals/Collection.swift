struct SmallArray<let InlineSize: Int, T> {
    private(set) var count: Int = 0
    var inlineStorage: [InlineSize of T?] = .init(repeating: nil)
    var arrayStorage: [T]? = nil

    init() {}
}

extension SmallArray: RandomAccessCollection, MutableCollection {
    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(position: Int) -> T {
        get {
            precondition(position >= 0 && position < count, "SmallArray index out of range")
            if arrayStorage != nil {
                return arrayStorage![position]
            }
            return inlineStorage[position]!
        }
        set {
            precondition(position >= 0 && position < count, "SmallArray index out of range")
            if arrayStorage != nil {
                arrayStorage![position] = newValue
            } else {
                inlineStorage[position] = newValue
            }
        }
    }
}

extension SmallArray {
    var isSpilled: Bool { arrayStorage != nil }

    mutating func append(_ value: T) {
        if arrayStorage != nil {
            arrayStorage!.append(value)
        } else if count < InlineSize {
            inlineStorage[count] = value
        } else {
            // spill: move the inline elements out, then append
            var spilled: [T] = []
            spilled.reserveCapacity(Swift.max(InlineSize * 2, 4))
            for i in 0..<InlineSize {
                spilled.append(inlineStorage[i]!)
                inlineStorage[i] = nil
            }
            spilled.append(value)
            arrayStorage = spilled
        }
        count += 1
    }

    @discardableResult
    mutating func removeLast() -> T {
        precondition(count > 0, "removeLast on an empty SmallArray")
        count -= 1
        if arrayStorage != nil {
            return arrayStorage!.removeLast()
        }
        let value = inlineStorage[count]!
        inlineStorage[count] = nil
        return value
    }

    mutating func removeAll() {
        for i in 0..<Swift.min(count, InlineSize) {
            inlineStorage[i] = nil
        }
        arrayStorage = nil
        count = 0
    }
}

extension Array {
    @discardableResult
    mutating func swapRemove(at index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        swapAt(index, count - 1)
        return removeLast()
    }
}
