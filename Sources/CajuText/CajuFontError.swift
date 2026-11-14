/// Erros ao interpretar um arquivo de fonte (dado externo, sempre hostil).
public enum CajuFontError: Error, Sendable, Equatable {
    /// O arquivo termina antes do esperado ao ler `what`.
    case truncated(what: String)
    /// O cabeçalho sfnt não é TrueType/OpenType com contornos `glyf`.
    case unsupportedFormat
    /// Tabela obrigatória ausente.
    case missingTable(String)
    /// Valor fora do intervalo válido ou acima dos limites da engine.
    case invalid(what: String)
}
