import CajuToolsCore
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    import Android
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    import Musl
#endif

let result = CajuToolsCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.exitCode.rawValue)
