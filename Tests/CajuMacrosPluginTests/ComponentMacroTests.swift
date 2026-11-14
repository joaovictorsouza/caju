import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import CajuMacrosPlugin

// XCTest aqui: `assertMacroExpansion` reporta falhas via XCTest (docs/standards/testes.md permite XCTest "onde necessário").
final class ComponentMacroTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["Component": ComponentMacro.self]

    func testStructInternal() {
        assertMacroExpansion(
            """
            @Component(id: 20)
            struct Pos { var x: Float }
            """,
            expandedSource: """
                struct Pos { var x: Float }

                extension Pos: CajuComponent {
                    static let componentID = CajuComponentID(20)
                }
                """,
            macros: macros
        )
    }

    func testPublicEnumKeepsAccess() {
        assertMacroExpansion(
            """
            @Component(id: 1_5)
            public enum Kind: UInt8 { case a }
            """,
            expandedSource: """
                public enum Kind: UInt8 { case a }

                extension Kind: CajuComponent {
                    public static let componentID = CajuComponentID(15)
                }
                """,
            macros: macros
        )
    }

    func testClassIsRejected() {
        assertMacroExpansion(
            """
            @Component(id: 3)
            class Bad {}
            """,
            expandedSource: """
                class Bad {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Component só se aplica a struct ou enum (componentes são BitwiseCopyable)",
                    line: 1, column: 1)
            ],
            macros: macros
        )
    }

    func testOutOfRangeIDIsRejected() {
        assertMacroExpansion(
            """
            @Component(id: 64)
            struct Bad {}
            """,
            expandedSource: """
                struct Bad {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Component exige `id:` como literal inteiro em 0..<64",
                    line: 1, column: 1)
            ],
            macros: macros
        )
    }
}
