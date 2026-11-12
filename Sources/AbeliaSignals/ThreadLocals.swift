@preconcurrency import AbeliaSignalsTLS

@inlinable
var currentSinkNode: NodeRef? {
    get { abelia_tls_current_sink?.assumingMemoryBound(to: Node.self) }
    set { abelia_tls_current_sink = newValue.map { UnsafeMutableRawPointer($0) } }
}

@inlinable
var currentImmediateBatch: UnsafeMutablePointer<[EffectNode]>? {
    get { abelia_tls_immediate_batch?.assumingMemoryBound(to: [EffectNode].self) }
    set { abelia_tls_immediate_batch = newValue.map { UnsafeMutableRawPointer($0) } }
}

@inlinable
var currentScopeNode: EffectScopeNode? {
    get { abelia_tls_current_scope.map { Unmanaged<EffectScopeNode>.fromOpaque($0).takeUnretainedValue() } }
    set { abelia_tls_current_scope = newValue.map { Unmanaged.passUnretained($0).toOpaque() } }
}
