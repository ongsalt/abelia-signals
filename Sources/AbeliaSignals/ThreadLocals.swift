@preconcurrency import AbeliaSignalsTLS

@inlinable
var currentSinkNode: NodeRef? {
    get { abelia_tls_current_sink?.assumingMemoryBound(to: Node.self) }
    set { abelia_tls_current_sink = newValue.map { UnsafeMutableRawPointer($0) } }
}

@inlinable
var currentImmediateBatch: UnsafeMutablePointer<[Effect]>? {
    get { abelia_tls_immediate_batch?.assumingMemoryBound(to: [Effect].self) }
    set { abelia_tls_immediate_batch = newValue.map { UnsafeMutableRawPointer($0) } }
}

@inlinable
var currentScopeNode: EffectScope? {
    get { abelia_tls_current_scope.map { Unmanaged<EffectScope>.fromOpaque($0).takeUnretainedValue() } }
    set { abelia_tls_current_scope = newValue.map { Unmanaged.passUnretained($0).toOpaque() } }
}

@inlinable
public func untracked<R, E>(_ body: () throws(E) -> R) throws(E) -> R {
    let prev = currentSinkNode
    currentSinkNode = nil
    defer { currentSinkNode = prev }
    return try body()
}
