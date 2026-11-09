struct SmallArray<let InlineSize: Int, T> {
    var count: Int = 0
    var inlineStorage: [InlineSize of T?]
    var arrayStorage: [T]?
}

extension SmallArray {
    mutating func append(_ value: T) {
        if count == InlineSize {
            arrayStorage = [T](unsafeUninitializedCapacity: InlineSize) { span, written in
                for i in span.indices {
                    if let value = inlineStorage[i] {
                        span[i] = value
                        inlineStorage[i] = nil
                    } else {
                        written = i
                        return
                    }
                }

                written = InlineSize + 1
            }
        } else if count > InlineSize {
            arrayStorage!.append(value)
        } else {
            inlineStorage[count] = value
        }

        count += 1
    }

    mutating func clear() {
        for i in inlineStorage.indices {
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
