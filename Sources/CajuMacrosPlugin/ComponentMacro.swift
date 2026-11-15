import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Implementação de `@Component(id:)` (declarada em `CajuCore`; ADR 0030).
///
/// Gera `extension T: CajuComponent { static let componentID = CajuComponentID(id) }`.
/// O `id` precisa ser um literal inteiro em `0..<64` e o tipo, um `struct` ou `enum`
/// (as colunas do ECS exigem `BitwiseCopyable`, o que exclui classes).
public struct ComponentMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: Syntax(node), message: ComponentDiagnostic.notValueType))
            return []
        }
        guard
            case .argumentList(let arguments)? = node.arguments,
            let literal = arguments.first?.expression.as(IntegerLiteralExprSyntax.self),
            let id = Int(literal.literal.text.filter { $0 != "_" }),
            (0..<64).contains(id)
        else {
            context.diagnose(Diagnostic(node: Syntax(node), message: ComponentDiagnostic.invalidID))
            return []
        }

        let isPublic = declaration.modifiers.contains {
            $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open)
        }
        let access = isPublic ? "public " : ""
        // `protocols` só traz o que o tipo ainda não declara; vazio = já conforma.
        let conformance = protocols.isEmpty ? "" : ": CajuComponent"

        let declaration: DeclSyntax = """
            extension \(type.trimmed)\(raw: conformance) {
                \(raw: access)static let componentID = CajuComponentID(\(raw: id))
            }
            """
        guard let extensionDecl = declaration.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
    }
}

enum ComponentDiagnostic: String, DiagnosticMessage {
    case notValueType = "@Component só se aplica a struct ou enum (componentes são BitwiseCopyable)"
    case invalidID = "@Component exige `id:` como literal inteiro em 0..<64"

    var message: String { rawValue }
    var diagnosticID: MessageID { MessageID(domain: "CajuMacrosPlugin", id: "\(self)") }
    var severity: DiagnosticSeverity { .error }
}

@main
struct CajuMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [ComponentMacro.self]
}
