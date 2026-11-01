import AbeliaSignalsMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

private let macros: [String: any Macro.Type] = ["Computed": ComputedMacro.self]

final class ComputedMacroTests: XCTestCase {
    func testExpansion() {
        assertMacroExpansion(
            """
            final class Model {
                @Computed
                var doubled: Int {
                    count * 2
                }
            }
            """,
            expandedSource: """
                final class Model {
                    var doubled: Int {
                        $doubled.value
                    }

                    var $doubled: AbeliaSignals.Computed<Int> {
                        if let computed = _$computed_doubled {
                            return computed
                        }
                        let computed = AbeliaSignals._makeComputed(self, Model._$compute_doubled)
                        _$computed_doubled = computed
                        return computed
                    }

                    private var _$computed_doubled: AbeliaSignals.Computed<Int>?

                    private func _$compute_doubled() -> Int {
                        count * 2
                    }
                }
                """,
            macros: macros)
    }

    func testProjectionHasThePropertysAccess() {
        assertMacroExpansion(
            """
            public final class Model {
                @Computed
                public var doubled: Int {
                    2
                }
            }
            """,
            expandedSource: """
                public final class Model {
                    public var doubled: Int {
                        $doubled.value
                    }

                    public var $doubled: AbeliaSignals.Computed<Int> {
                        if let computed = _$computed_doubled {
                            return computed
                        }
                        let computed = AbeliaSignals._makeComputed(self, Model._$compute_doubled)
                        _$computed_doubled = computed
                        return computed
                    }

                    private var _$computed_doubled: AbeliaSignals.Computed<Int>?

                    private func _$compute_doubled() -> Int {
                        2
                    }
                }
                """,
            macros: macros)
    }

    func testNeedsAClass() {
        assertMacroExpansion(
            "struct Model { @Computed var doubled: Int { 2 } }",
            expandedSource: "struct Model { var doubled: Int { 2 } \n}",
            diagnostics: [DiagnosticSpec(message: "@Computed is only supported in classes", line: 1, column: 16)],
            macros: macros)
    }

    func testNeedsAType() {
        assertMacroExpansion(
            "final class Model { @Computed var doubled { 2 } }",
            expandedSource: "final class Model { var doubled { 2 } \n}",
            diagnostics: [DiagnosticSpec(message: "@Computed needs an explicit type", line: 1, column: 35)],
            macros: macros)
    }

    func testNeedsAReadOnlyBody() {
        assertMacroExpansion(
            "final class Model { @Computed var doubled: Int { get { 2 } set {} } }",
            expandedSource: "final class Model { var doubled: Int { get { 2 } set {} } \n}",
            diagnostics: [
                DiagnosticSpec(
                    message: "@Computed needs a read-only body: `var doubled: Int { … }`", line: 1, column: 35)
            ],
            macros: macros)
    }
}
