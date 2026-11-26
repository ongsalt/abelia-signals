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

extension EffectScheduler {
    @inlinable
    static var current: EffectScheduler? {
        get { abelia_tls_current_scheduler.map { Unmanaged<EffectScheduler>.fromOpaque($0).takeUnretainedValue() } }
        set { abelia_tls_current_scheduler = newValue.map { Unmanaged.passUnretained($0).toOpaque() } }
    }
}

@inlinable
public func untracked<R, E>(_ body: () throws(E) -> R) throws(E) -> R {
    let prev = Node.current
    Node.current = nil
    defer { Node.current = prev }
    return try body()
}

/// Where code runs: actor, main, or thread. For debug-only `sending` checks.
@usableFromInline
@frozen
struct IsolationKey: Equatable {
    @usableFromInline
    let raw: UInt

    @inlinable
    init(raw: UInt) {
        self.raw = raw
    }

    // a task on the global executor, which can hop threads
    @inlinable
    static var unknown: IsolationKey { IsolationKey(raw: 0) }

    @inlinable
    static var current: IsolationKey { IsolationKey(raw: UInt(abelia_current_isolation_key())) }

    // unknown on either side counts as yes
    @inlinable
    var isCurrent: Bool {
        if self == .unknown { return true }
        let now = IsolationKey.current
        return now == .unknown || now == self
    }
}
