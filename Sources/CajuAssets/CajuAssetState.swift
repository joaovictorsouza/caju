import CajuAssetsCore

/// Estado de carga de um handle.
///
/// Máquina de estados (ADR 0021): `queued → loading → loaded | failed`; `loaded → reloading → loaded`
/// (o valor antigo continua legível durante o *reload*); `release` até zero invalida o handle (`stale`).
public enum CajuAssetState: UInt8, Sendable, BitwiseCopyable {
    /// Reservado, ainda sem carga iniciada.
    case queued
    /// Carga em andamento, ainda sem valor.
    case loading
    /// Valor disponível.
    case loaded
    /// Recarga em andamento; o valor anterior continua disponível até a troca.
    case reloading
    /// Carga falhou e não há valor; `error(of:)` diz por quê.
    case failed
    /// Handle velho (geração diferente), `invalid` ou de outro servidor: não aponta para nada.
    case stale

    /// Há valor legível (`loaded` ou `reloading`).
    @inlinable public var hasValue: Bool { self == .loaded || self == .reloading }
    /// A carga ainda pode terminar (`queued`, `loading`, `reloading`).
    @inlinable public var isPending: Bool { self == .queued || self == .loading || self == .reloading }
}

/// Erro tipado do módulo. Strings só no caminho de erro.
public enum CajuAssetError: Error, Equatable, Sendable {
    /// `CajuAssetPath` recusado na construção.
    case invalidPath(reason: String)
    /// A fonte não tem o caminho.
    case notFound(path: String)
    /// Falha de leitura na fonte (disco, rede, CDN).
    case io(path: String, reason: String)
    /// Nenhum `CajuAssetLoader` registrado para o tipo pedido.
    case noLoader(type: String)
    /// O parser (`CajuAssetsCore`) recusou os bytes.
    case decode(AssetError)
    /// Carga cancelada (descarregada antes de terminar, ou servidor encerrado).
    case cancelled
}

/// Evento de ciclo de vida, entregue no limite do quadro (nunca no meio dele).
///
/// `BitwiseCopyable` para caber em `CajuMessageQueue`; não aloca.
public struct CajuAssetEvent: Sendable, BitwiseCopyable, Equatable {
    public enum Kind: UInt8, Sendable, BitwiseCopyable {
        /// Primeira carga concluída (`loaded`).
        case loaded
        /// Carga falhou (`failed`).
        case failed
        /// Recarga concluída: mesmo handle, `revision` maior, valor novo.
        case reloaded
        /// Slot liberado; o handle passa a `stale`.
        case unloaded
    }

    public var kind: Kind
    public var asset: CajuAnyAssetHandle

    public init(kind: Kind, asset: CajuAnyAssetHandle) {
        self.kind = kind
        self.asset = asset
    }
}
