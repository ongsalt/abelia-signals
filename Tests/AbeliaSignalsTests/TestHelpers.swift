import AbeliaSignals

extension Signal {
    var peek: T { peak }
}

extension Effect {
    // the suite's name for an effect flushed in the current batch
    static func immediate(effect: @escaping () -> Void) -> Effect {
        Effect(flush: .immediate, effect: effect)
    }
}
