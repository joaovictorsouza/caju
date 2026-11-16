/// Resultado puro de uma execução da CLI `caju-tools`.
public struct CLIResult: Sendable, Equatable {
    public let exitCode: ExitCode
    public let stdout: String
    public let stderr: String
}

/// Roteador puro de argumentos e subcomandos de `caju-tools`.
public enum CajuToolsCLI {
    public static let rootHelpText = """
        uso: caju-tools <subcomando> [opções]

        subcomandos:
          texture         converte imagem (PNG/PPM) para KTX2 RGBA8 ou valida .ktx2
          validate-gltf   valida arquivo glTF 2.0 (.gltf) ou GLB (.glb)
          manifest        gera manifesto JSON determinístico de um diretório de assets

        opções globais:
          -h, --help      exibe esta ajuda
        """

    /// Interpreta os argumentos (sem o nome do executável) e executa o subcomando correspondente.
    public static func run(arguments: [String]) -> CLIResult {
        guard let first = arguments.first else {
            return CLIResult(exitCode: .ok, stdout: rootHelpText + "\n", stderr: "")
        }

        if first == "--help" || first == "-h" {
            return CLIResult(exitCode: .ok, stdout: rootHelpText + "\n", stderr: "")
        }

        let subArgs = Array(arguments.dropFirst())
        let wantsHelp = subArgs.contains("--help") || subArgs.contains("-h")

        do {
            switch first {
            case "texture":
                if wantsHelp {
                    return CLIResult(exitCode: .ok, stdout: TextureCommand.helpText + "\n", stderr: "")
                }
                let out = try TextureCommand.run(arguments: subArgs)
                return CLIResult(exitCode: .ok, stdout: out, stderr: "")

            case "validate-gltf":
                if wantsHelp {
                    return CLIResult(exitCode: .ok, stdout: ValidateGLTFCommand.helpText + "\n", stderr: "")
                }
                let out = try ValidateGLTFCommand.run(arguments: subArgs)
                return CLIResult(exitCode: .ok, stdout: out, stderr: "")

            case "manifest":
                if wantsHelp {
                    return CLIResult(exitCode: .ok, stdout: ManifestCommand.helpText + "\n", stderr: "")
                }
                let out = try ManifestCommand.run(arguments: subArgs)
                return CLIResult(exitCode: .ok, stdout: out, stderr: "")

            default:
                let msg = "caju-tools: subcomando desconhecido '\(first)'\n\(rootHelpText)\n"
                return CLIResult(exitCode: .usage, stdout: "", stderr: msg)
            }
        } catch {
            let prefix = "caju-tools: \(error.description)\n"
            if error.exitCode == .usage {
                let help = helpForSubcommand(first)
                return CLIResult(exitCode: .usage, stdout: "", stderr: prefix + help + "\n")
            }
            return CLIResult(exitCode: error.exitCode, stdout: "", stderr: prefix)
        }
    }

    private static func helpForSubcommand(_ subcommand: String) -> String {
        switch subcommand {
        case "texture": TextureCommand.helpText
        case "validate-gltf": ValidateGLTFCommand.helpText
        case "manifest": ManifestCommand.helpText
        default: rootHelpText
        }
    }
}
