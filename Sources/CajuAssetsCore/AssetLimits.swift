/// Limites aplicados **antes de alocar** em todos os parsers (dado externo é hostil).
///
/// Os valores padrão são conservadores para jogos móveis; ajuste por chamada se necessário.
public struct AssetLimits: Sendable, Equatable {
    /// Tamanho máximo da entrada, em bytes.
    public var maxInputBytes: Int
    /// Memória máxima de saída decodificada (pixels, vértices, índices), em bytes.
    public var maxOutputBytes: Int
    /// Lado máximo de imagem (largura ou altura), em pixels.
    public var maxImageDimension: Int
    /// Profundidade máxima de aninhamento de JSON.
    public var maxJSONDepth: Int
    /// Quantidade máxima de elementos em qualquer array/objeto JSON e de itens glTF por coleção.
    public var maxElements: Int
    /// Quantidade máxima de níveis de mip (KTX2).
    public var maxMipLevels: Int

    public init(
        maxInputBytes: Int = 256 << 20,
        maxOutputBytes: Int = 512 << 20,
        maxImageDimension: Int = 16_384,
        maxJSONDepth: Int = 64,
        maxElements: Int = 1 << 20,
        maxMipLevels: Int = 32
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxOutputBytes = maxOutputBytes
        self.maxImageDimension = maxImageDimension
        self.maxJSONDepth = maxJSONDepth
        self.maxElements = maxElements
        self.maxMipLevels = maxMipLevels
    }

    /// Limites padrão.
    public static let `default` = AssetLimits()
}
