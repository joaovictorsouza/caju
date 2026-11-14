/// Erro tipado de todos os parsers de `CajuAssetsCore`.
///
/// `context` é um caminho legível do campo ou da posição (por exemplo `"accessors[3].bufferView"`).
/// Strings só são criadas no caminho de erro.
public enum AssetError: Error, Equatable, Sendable {
    /// A entrada acabou antes do esperado.
    case truncated(context: String)
    /// A entrada viola o formato (valor ilegal, índice fora de faixa, inconsistência).
    case invalid(context: String, reason: String)
    /// Um limite de `AssetLimits` seria excedido; nada foi alocado.
    case limitExceeded(context: String, limit: Int, requested: Int)
    /// Recurso válido do formato que este módulo (ainda) não implementa.
    case unsupported(context: String, reason: String)
}
