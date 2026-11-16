import Foundation
import Testing

@testable import CajuToolsCore

/// Testes nativos da CLI (os goldens de arquivo continuam em `scripts/test-caju-tools.sh`).
@Suite("CajuToolsCore: CLI")
struct CajuToolsCLITests {
    @Test func helpExitsZero() {
        let result = CajuToolsCLI.run(arguments: ["--help"])
        #expect(result.exitCode == .ok)
        #expect(result.stdout.contains("validate-gltf"))
    }

    @Test func unknownSubcommandIsUsageError() {
        let result = CajuToolsCLI.run(arguments: ["nao-existe"])
        #expect(result.exitCode == .usage)
    }

    @Test func validateGLTFRejectsGarbageWithoutCrashing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "caju-garbage-\(UUID().uuidString).gltf")
        try Data("{ não é glTF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = CajuToolsCLI.run(arguments: ["validate-gltf", url.path])
        #expect(result.exitCode == .invalid)
    }

    @Test func manifestIsDeterministic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "caju-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.bin"))
        try Data("bb".utf8).write(to: dir.appendingPathComponent("b.bin"))
        let first = CajuToolsCLI.run(arguments: ["manifest", dir.path])
        let second = CajuToolsCLI.run(arguments: ["manifest", dir.path])
        #expect(first.exitCode == .ok)
        #expect(first == second)
    }
}
