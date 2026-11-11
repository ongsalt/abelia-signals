// Maps the suite's v1 names onto Reactivity2's node API. Module-local declarations
// shadow the imported v1 `Signal` / `Computed` / `Effect`.
import AbeliaSignals

typealias Signal = SignalNode
typealias Computed = ComputedNode
typealias Effect = EffectNode

extension SignalNode {
    var peek: T { peak }
}

extension EffectNode {
    static func immediate(effect: @escaping () -> Void) -> EffectNode {
        EffectNode(immediate: true, effect: effect)
    }
}
