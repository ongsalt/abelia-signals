// The suite's name for something AbeliaSignals spells differently. Not symlinked into
// BenchmarkAlien (AlienSignals has these natively).
import AbeliaSignals

extension Effect {
    static func immediate(effect: @escaping () -> Void) -> Effect {
        Effect(flush: .immediate, effect: effect)
    }
}
