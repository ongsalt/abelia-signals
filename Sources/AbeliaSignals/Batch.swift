@inlinable
public func batch<T>(body: () -> T) -> T {
    // nested: ignored
    if ImmediateBatch.current != nil { return body() }

    var queue: [Effect] = []
    return withUnsafeMutablePointer(to: &queue) { queue in
        ImmediateBatch.current = queue
        defer { ImmediateBatch.current = nil }

        let ret = body()

        // by index: effects may append to the queue while it drains
        var i = 0
        while i < queue.pointee.count {
            // only the queue holds it: nobody owns it any more
            if isKnownUniquelyReferenced(&queue.pointee[i]) {
                i += 1
                continue
            }
            let effect = queue.pointee[i]
            i += 1
            effect.runEffect()
        }
        return ret
    }
}
