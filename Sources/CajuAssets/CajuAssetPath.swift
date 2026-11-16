/// Caminho lógico de um asset, relativo à raiz da fonte (`CajuAssetSource`), com `/` como separador.
///
/// Validado na construção (dado externo): não vazio, sem `/` inicial ou final, sem `\`, sem byte nulo e
/// sem segmento vazio, `.` ou `..`. Strings só existem nas bordas (carga, diagnóstico); o caminho quente
/// usa `CajuAssetHandle`.
public struct CajuAssetPath: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws(CajuAssetError) {
        if rawValue.isEmpty { throw .invalidPath(reason: "vazio") }
        var segmentLength = 0
        var segmentDots = 0
        var previousWasSlash = true
        for byte in rawValue.utf8 {
            switch byte {
            case 0: throw .invalidPath(reason: "byte nulo")
            case UInt8(ascii: "\\"): throw .invalidPath(reason: "barra invertida")
            case UInt8(ascii: "/"):
                if previousWasSlash { throw .invalidPath(reason: "segmento vazio ou barra inicial") }
                if segmentDots == segmentLength { throw .invalidPath(reason: "segmento '.' ou '..'") }
                segmentLength = 0
                segmentDots = 0
                previousWasSlash = true
            default:
                segmentLength += 1
                if byte == UInt8(ascii: ".") { segmentDots += 1 }
                previousWasSlash = false
            }
        }
        if previousWasSlash { throw .invalidPath(reason: "barra final") }
        if segmentDots == segmentLength { throw .invalidPath(reason: "segmento '.' ou '..'") }
        self.rawValue = rawValue
    }
}
