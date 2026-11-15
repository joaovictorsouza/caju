// CLI de ferramentas do Caju (alvo criado na S-0; os subcomandos chegam na trilha T-1).
// Uso: swift run caju-tools <subcomando>
#if canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    import Android
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    import Musl
#endif

/// Subcomandos previstos para a T-1 (plano §8). Ainda sem implementação.
let plannedCommands = ["texture", "validate-gltf", "manifest"]

func printUsage() {
    print("uso: caju-tools <subcomando>")
    let names = plannedCommands.joined(separator: ", ")
    print("subcomandos previstos (trilha T-1, ainda não implementados): \(names)")
}

let arguments = CommandLine.arguments.dropFirst()
if arguments.isEmpty || arguments.first == "--help" || arguments.first == "-h" {
    printUsage()
    exit(0)
}
let command = arguments.first ?? ""
if plannedCommands.contains(command) {
    print("caju-tools: '\(command)' ainda não implementado (trilha T-1)")
} else {
    print("caju-tools: subcomando desconhecido '\(command)'")
    printUsage()
}
exit(2)
