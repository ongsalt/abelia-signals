@preconcurrency import AbeliaSignalsTLS

extension Node {
    @inlinable
    static var current: NodeRef? {
        get { abelia_tls_current_sink?.assumingMemoryBound(to: Node.self) }
        set { abelia_tls_current_sink = newValue.map { UnsafeMutableRawPointer($0) } }
    }
}

@usableFromInline
enum ImmediateBatch {
    @inlinable
    static var current: UnsafeMutablePointer<[Effect]>? {
        get { abelia_tls_immediate_batch?.assumingMemoryBound(to: [Effect].self) }
        set { abelia_tls_immediate_batch = newValue.map { UnsafeMutableRawPointer($0) } }
    }
}

extension EffectScope {
    @inlinable
    static var current: EffectScope? {
        get { abelia_tls_current_scope.map { Unmanaged<EffectScope>.fromOpaque($0).takeUnretainedValue() } }
        set { abelia_tls_current_scope = newValue.map { Unmanaged.passUnretained($0).toOpaque() } }
    }
}

@inlinable
public func untracked<R, E>(_ body: () throws(E) -> R) throws(E) -> R {
    let prev = Node.current
    Node.current = nil
    defer { Node.current = prev }
    return try body()
}
