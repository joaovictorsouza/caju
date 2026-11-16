/// Marcador de tipo de asset carregável pelo `CajuAssetServing`.
///
/// O tipo (malha, textura, clipe...) é definido pelo módulo dono; o servidor o identifica por
/// `ObjectIdentifier(A.self)`. `Sendable` porque o valor atravessa da *thread* de carga para o quadro.
public protocol CajuAsset: Sendable {}

/// Referência **tipada** a um asset: índice de *slot* + geração (detecta uso após descarregar).
///
/// É um valor de 8 bytes, `BitwiseCopyable`: pode morar em componentes do ECS e em mensagens sem ARC.
/// O handle **não** mantém o asset vivo por si só; a posse é explícita (`retain`/`release` do servidor).
/// Consultar um handle velho (geração diferente) nunca falha nem lê lixo: devolve `.stale`/`nil`.
/// Geração começa em 1, então o valor `invalid` (tudo zero) nunca é válido.
public struct CajuAssetHandle<A: CajuAsset>: Hashable, Sendable, BitwiseCopyable {
    public let index: UInt32
    public let generation: UInt32

    @inlinable public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }

    /// Handle que nunca aponta para um asset.
    public static var invalid: Self { Self(index: 0, generation: 0) }

    /// Versão sem tipo, para mensagens e tabelas heterogêneas.
    @inlinable public var erased: CajuAnyAssetHandle {
        CajuAnyAssetHandle(type: ObjectIdentifier(A.self), index: index, generation: generation)
    }
}

/// Handle sem tipo estático (identifica o tipo por `ObjectIdentifier`). Só para eventos e diagnóstico;
/// o código de jogo usa `CajuAssetHandle<A>`.
public struct CajuAnyAssetHandle: Hashable, Sendable, BitwiseCopyable {
    public let type: ObjectIdentifier
    public let index: UInt32
    public let generation: UInt32

    @inlinable public init(type: ObjectIdentifier, index: UInt32, generation: UInt32) {
        self.type = type
        self.index = index
        self.generation = generation
    }

    /// Recupera o handle tipado; `nil` se o tipo não for `A`.
    @inlinable public func typed<A: CajuAsset>(as _: A.Type) -> CajuAssetHandle<A>? {
        type == ObjectIdentifier(A.self) ? CajuAssetHandle(index: index, generation: generation) : nil
    }
}
