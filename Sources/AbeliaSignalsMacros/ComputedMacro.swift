import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct AbeliaSignalsPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ComputedMacro.self
    ]
}

public struct ComputedMacro: BodyMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        let varDecl: VariableDeclSyntax
        let enclosing: [Syntax]

        if let direct = declaration.as(VariableDeclSyntax.self) {
            varDecl = direct
            enclosing = context.lexicalContext
        } else if declaration.is(AccessorDeclSyntax.self),
            let parentVar = context.lexicalContext.first?.as(VariableDeclSyntax.self)
        {
            // Note: `asMacroLexicalContext()` strips `accessorBlock` on `parentVar`,
            // so `parseHeader` must not require `binding.accessorBlock` here.
            varDecl = parentVar
            enclosing = Array(context.lexicalContext.dropFirst())
        } else {
            return []
        }

        guard let header = try? parseHeader(node: node, varDecl: varDecl, enclosing: enclosing) else {
            return []
        }

        switch header.kind {
        case .classInstance:
            return ["return \(raw: header.storageName).value(self)"]
        case .standalone:
            return ["return \(raw: header.storageName).value"]
        case .localUnsupported:
            throw MacroError(
                "@Computed with '{ ... }' is not supported on local variables; use '@Computed var \(header.rawName) = ...' or 'Computed { ... }'"
            )
        }
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
            let binding = varDecl.bindings.first
        else {
            throw MacroError("@Computed can only be applied to a computed 'var' property")
        }

        let header = try parseHeader(node: node, varDecl: varDecl, enclosing: context.lexicalContext)
        let body = try extractGetterBody(from: binding)

        switch header.kind {
        case .classInstance(let ownerType, let isolationPrefix):
            let bodyName = context.makeUniqueName(header.rawName)
            let bodyDecl: DeclSyntax = """
                \(raw: isolationPrefix)private var \(bodyName): \(header.type) {
                    \(body)
                }
                """
            let storageDecl: DeclSyntax
            if let equals = header.equals {
                storageDecl = """
                    \(raw: isolationPrefix)private let \(raw: header.storageName) = ComputedStorage<\(raw: ownerType), \(header.type)>(equals: \(equals)) { $0.\(bodyName) }
                    """
            } else {
                storageDecl = """
                    \(raw: isolationPrefix)private let \(raw: header.storageName) = ComputedStorage<\(raw: ownerType), \(header.type)> { $0.\(bodyName) }
                    """
            }
            return [bodyDecl, storageDecl]

        case .standalone(let prefix):
            let storageDecl: DeclSyntax
            if let equals = header.equals {
                storageDecl = """
                    \(raw: prefix)let \(raw: header.storageName) = Computed<\(header.type)>({
                        \(body)
                    }, equals: \(equals))
                    """
            } else {
                storageDecl = """
                    \(raw: prefix)let \(raw: header.storageName) = Computed<\(header.type)> {
                        \(body)
                    }
                    """
            }
            return [storageDecl]

        case .localUnsupported:
            return []
        }
    }
}

private struct ParsedHeader {
    enum Kind {
        case classInstance(ownerType: String, isolationPrefix: String)
        case standalone(prefix: String)
        case localUnsupported
    }

    let rawName: String
    var storageName: String { "_$\(rawName)" }
    let type: TypeSyntax
    let equals: ExprSyntax?
    let kind: Kind
}

private func parseHeader(
    node: AttributeSyntax,
    varDecl: VariableDeclSyntax,
    enclosing: [Syntax]
) throws -> ParsedHeader {
    guard varDecl.bindingSpecifier.tokenKind == .keyword(.var),
        varDecl.bindings.count == 1,
        let binding = varDecl.bindings.first,
        let identPattern = binding.pattern.as(IdentifierPatternSyntax.self)
    else {
        throw MacroError("@Computed requires a single 'var' declaration")
    }

    if binding.initializer != nil {
        throw MacroError("@Computed must use a computed getter body '{ ... }', not '= ...'")
    }

    guard let type = binding.typeAnnotation?.type.trimmed else {
        throw MacroError("@Computed requires an explicit type annotation")
    }

    let rawName = identPattern.identifier.trimmedDescription.filter { $0 != "`" }
    let equals = extractEquals(from: node)

    let hasClassModifier = varDecl.modifiers.contains { $0.name.tokenKind == .keyword(.class) }
    if hasClassModifier {
        throw MacroError("@Computed does not support 'class var'; use 'static var' or an instance property")
    }
    let isStatic = varDecl.modifiers.contains { $0.name.tokenKind == .keyword(.static) }
    let isolationPrefix = extractIsolationPrefix(from: varDecl)

    let kind: ParsedHeader.Kind
    if isStatic {
        kind = .standalone(prefix: "\(isolationPrefix)private static ")
    } else if let first = enclosing.first {
        if let classDecl = first.as(ClassDeclSyntax.self) {
            let ownerType = buildOwnerType(classDecl)
            kind = .classInstance(ownerType: ownerType, isolationPrefix: isolationPrefix)
        } else if first.is(StructDeclSyntax.self)
            || first.is(EnumDeclSyntax.self)
            || first.is(ExtensionDeclSyntax.self)
            || first.is(ProtocolDeclSyntax.self)
            || first.is(ActorDeclSyntax.self)
        {
            throw MacroError("@Computed instance properties are only supported on classes")
        } else {
            // Swift does not expand PeerMacro on local declarations inside function bodies.
            kind = .localUnsupported
        }
    } else {
        // Global / file scope
        kind = .standalone(prefix: "\(isolationPrefix)private ")
    }

    return ParsedHeader(
        rawName: rawName,
        type: type,
        equals: equals,
        kind: kind
    )
}

private func extractIsolationPrefix(from varDecl: VariableDeclSyntax) -> String {
    var parts: [String] = []
    for attrElem in varDecl.attributes {
        if let attr = attrElem.as(AttributeSyntax.self),
            attr.attributeName.trimmedDescription == "MainActor"
        {
            parts.append("@MainActor ")
        }
    }
    if varDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.nonisolated) }) {
        parts.append("nonisolated ")
    }
    return parts.joined()
}

private func extractGetterBody(from binding: PatternBindingSyntax) throws -> CodeBlockItemListSyntax {
    guard let accessorBlock = binding.accessorBlock else {
        throw MacroError("@Computed requires a getter body")
    }
    switch accessorBlock.accessors {
    case .getter(let items):
        return items
    case .accessors(let list):
        guard list.count == 1,
            let accessor = list.first,
            accessor.accessorSpecifier.tokenKind == .keyword(.get),
            let body = accessor.body
        else {
            throw MacroError("@Computed properties are read-only and only support a getter")
        }
        return body.statements
    }
}

private func extractEquals(from node: AttributeSyntax) -> ExprSyntax? {
    guard case .argumentList(let args) = node.arguments else { return nil }
    for arg in args where arg.label?.text == "equals" {
        return arg.expression.trimmed
    }
    return nil
}

private func buildOwnerType(_ classDecl: ClassDeclSyntax) -> String {
    let base = classDecl.name.trimmedDescription
    guard let genericClause = classDecl.genericParameterClause,
        !genericClause.parameters.isEmpty
    else {
        return base
    }
    let params = genericClause.parameters.map { param -> String in
        let name = param.name.trimmedDescription
        return param.specifier != nil ? "repeat each \(name)" : name
    }.joined(separator: ", ")
    return "\(base)<\(params)>"
}

private struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
