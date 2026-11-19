// The suite's names for a few things AbeliaSignals spells differently. Not symlinked into
// BenchmarkAlien (AlienSignals has these natively).
import AbeliaSignals

extension Signal {
    var peek: T { peak }
}

extension Effect {
    static func immediate(effect: @escaping () -> Void) -> Effect {
        Effect(flush: .immediate, effect: effect)
    }
}
