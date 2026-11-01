import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// @Computed var doubled: Int { count * 2 } becomes
//     var doubled: Int { $doubled.value }
//     var $doubled: Computed<Int> { the stored one, created on first use }
//     private var _$computed_doubled: Computed<Int>?
//     private func _$compute_doubled() -> Int { count * 2 }
// Created on first read: a lazy var whose initializer uses self doesn't compile
// when a macro adds it.
public struct ComputedMacro: BodyMacro, PeerMacro {
    // `declaration` is the getter; the peer role checks the property and reports errors
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard
            let variable = context.lexicalContext.lazy.compactMap({ $0.as(VariableDeclSyntax.self) }).first,
            let binding = variable.bindings.first, binding.typeAnnotation != nil,
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
            context.lexicalContext.contains(where: { $0.is(ClassDeclSyntax.self) })
        else { return [] }
        return ["\(raw: ComputedProperty.projectionName(name.trimmedDescription)).value"]
    }

    public static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let property = ComputedProperty(declaration, in: context) else { return [] }
        return [
            """
            \(raw: property.access)var \(raw: property.projection): AbeliaSignals.Computed<\(property.type)> {
                if let computed = \(raw: property.storage) { return computed }
                let computed = AbeliaSignals._makeComputed(self, \(property.owner).\(raw: property.compute))
                \(raw: property.storage) = computed
                return computed
            }
            """,
            "private var \(raw: property.storage): AbeliaSignals.Computed<\(property.type)>?",
            "private func \(raw: property.compute)() -> \(property.type) \(property.body)",
        ]
    }
}

struct ComputedProperty {
    static func projectionName(_ name: String) -> String { "$\(name)" }

    let type: TypeSyntax
    let owner: TokenSyntax
    // the property's, for the projection: as a property wrapper's $name
    let access: String
    let projection: String
    let body: CodeBlockSyntax
    let storage: String
    let compute: String

    init?(_ declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) {
        func diagnose(_ message: String, at node: some SyntaxProtocol) {
            context.diagnose(Diagnostic(node: node, message: ComputedDiagnostic(message: message)))
        }

        guard let variable = declaration.as(VariableDeclSyntax.self),
            variable.bindings.count == 1, let binding = variable.bindings.first,
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.trimmedDescription
        else { diagnose("@Computed applies to a single `var`", at: declaration); return nil }
        guard let owner = context.lexicalContext.first?.as(ClassDeclSyntax.self) else {
            diagnose("@Computed is only supported in classes", at: declaration); return nil
        }
        guard let type = binding.typeAnnotation?.type else {
            diagnose("@Computed needs an explicit type", at: binding); return nil
        }

        // body macros only attach to an implicit getter, not to `get { }` or `set { }`
        guard case .getter(let statements) = binding.accessorBlock?.accessors else {
            diagnose("@Computed needs a read-only body: `var \(name): \(type.trimmedDescription) { … }`", at: binding)
            return nil
        }

        self.type = type.trimmed
        self.owner = owner.name.trimmed
        self.body = CodeBlockSyntax(statements: statements.trimmed)
        let accessModifier = variable.modifiers.first { modifier in
            modifier.detail == nil
                && [.keyword(.open), .keyword(.public), .keyword(.package), .keyword(.internal),
                    .keyword(.fileprivate), .keyword(.private)].contains(modifier.name.tokenKind)
        }
        switch accessModifier?.name.tokenKind {
        case nil: access = ""
        case .keyword(.open): access = "public "
        default: access = "\(accessModifier!.name.text) "
        }
        projection = Self.projectionName(name)
        storage = "_$computed_\(name)"
        compute = "_$compute_\(name)"
    }
}

struct ComputedDiagnostic: DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "AbeliaSignals", id: "Computed") }
    var severity: DiagnosticSeverity { .error }
}

@main
struct AbeliaSignalsMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [ComputedMacro.self]
}
