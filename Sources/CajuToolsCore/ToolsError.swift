/// Códigos de saída padronizados da CLI `caju-tools`.
public enum ExitCode: Int32, Sendable, Equatable {
    /// Execução concluída com sucesso.
    case ok = 0
    /// Entrada inválida, corrompida, recurso não suportado ou falha de E/S.
    case invalid = 1
    /// Erro de uso da linha de comando (argumento ausente ou desconhecido).
    case usage = 2
}

/// Erro tipado para todas as operações de `CajuTools`.
///
/// Todas as falhas em dados externos retornam um caso de ``CajuToolsError`` sem abortar.
public enum CajuToolsError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Argumentos inválidos ou faltantes na linha de comando.
    case usage(String)
    /// Erro ao ler ou gravar arquivos no sistema de arquivos.
    case io(path: String, reason: String)
    /// Os dados de entrada terminaram antes do esperado.
    case truncated(context: String)
    /// Os dados violam o formato especificado.
    case invalid(context: String, reason: String)
    /// Um limite de segurança seria excedido; nenhuma alocação grande foi feita.
    case limitExceeded(context: String, limit: Int, requested: Int)
    /// Recurso válido do formato ainda não suportado sem dependência externa.
    case unsupported(context: String, reason: String)

    /// Código de saída correspondente para o processo.
    public var exitCode: ExitCode {
        switch self {
        case .usage:
            .usage
        case .io, .truncated, .invalid, .limitExceeded, .unsupported:
            .invalid
        }
    }

    public var description: String {
        switch self {
        case .usage(let message):
            "uso inválido: \(message)"
        case .io(let path, let reason):
            "erro de E/S em '\(path)': \(reason)"
        case .truncated(let context):
            "entrada truncada em '\(context)'"
        case .invalid(let context, let reason):
            "entrada inválida em '\(context)': \(reason)"
        case .limitExceeded(let context, let limit, let requested):
            "limite excedido em '\(context)': solicitado \(requested), máximo \(limit)"
        case .unsupported(let context, let reason):
            "não suportado em '\(context)': \(reason)"
        }
    }
}
