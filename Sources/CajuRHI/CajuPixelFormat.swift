/// Formatos de pixel/texel suportados pelo RHI (subconjunto comum a Metal e Vulkan).
public enum CajuPixelFormat: UInt8, Sendable, Hashable, CaseIterable {
    case r8Unorm
    case rg8Unorm
    case rgba8Unorm
    case rgba8UnormSRGB
    case bgra8Unorm
    case bgra8UnormSRGB
    case rgba16Float
    case r32Float
    case rgb10a2Unorm
    case depth16Unorm
    case depth32Float
    case depth32FloatStencil8
    /// ASTC: blocos 4x4, 5x5, 6x6 e 8x8 (LDR), linear e sRGB. Formato de textura de mobile (NFR-007).
    case astc4x4
    case astc4x4SRGB
    case astc5x5
    case astc5x5SRGB
    case astc6x6
    case astc6x6SRGB
    case astc8x8
    case astc8x8SRGB

    /// `true` para formatos de profundidade (com ou sem estêncil).
    public var isDepth: Bool {
        switch self {
        case .depth16Unorm, .depth32Float, .depth32FloatStencil8: true
        default: false
        }
    }

    public var hasStencil: Bool { self == .depth32FloatStencil8 }

    public var isCompressed: Bool { blockWidth > 1 }

    public var isSRGB: Bool {
        switch self {
        case .rgba8UnormSRGB, .bgra8UnormSRGB, .astc4x4SRGB, .astc5x5SRGB, .astc6x6SRGB, .astc8x8SRGB:
            true
        default: false
        }
    }

    /// Largura do bloco em texels (1 para formatos não comprimidos).
    public var blockWidth: Int {
        switch self {
        case .astc4x4, .astc4x4SRGB: 4
        case .astc5x5, .astc5x5SRGB: 5
        case .astc6x6, .astc6x6SRGB: 6
        case .astc8x8, .astc8x8SRGB: 8
        default: 1
        }
    }

    public var blockHeight: Int { blockWidth }

    /// Bytes por bloco (ASTC: 16 bytes por bloco; demais: bytes por texel).
    public var bytesPerBlock: Int {
        switch self {
        case .r8Unorm: 1
        case .rg8Unorm, .depth16Unorm: 2
        case .rgba8Unorm, .rgba8UnormSRGB, .bgra8Unorm, .bgra8UnormSRGB, .r32Float, .rgb10a2Unorm,
            .depth32Float:
            4
        case .rgba16Float: 8
        case .depth32FloatStencil8: 8
        case .astc4x4, .astc4x4SRGB, .astc5x5, .astc5x5SRGB, .astc6x6, .astc6x6SRGB, .astc8x8,
            .astc8x8SRGB:
            16
        }
    }

    /// Bytes de uma imagem 2D `width` x `height` (sem mipmaps), arredondando para blocos inteiros.
    public func byteSize(width: Int, height: Int) -> Int {
        let blocksX = (width + blockWidth - 1) / blockWidth
        let blocksY = (height + blockHeight - 1) / blockHeight
        return blocksX * blocksY * bytesPerBlock
    }
}

/// Máscara de contagens de amostras suportadas (bit `n` ligado = `1 << n` amostras).
public struct CajuSampleCounts: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let x1 = Self(rawValue: 1 << 0)
    public static let x2 = Self(rawValue: 1 << 1)
    public static let x4 = Self(rawValue: 1 << 2)
    public static let x8 = Self(rawValue: 1 << 3)

    /// `true` se `count` (1, 2, 4 ou 8) está na máscara.
    public func supports(_ count: Int) -> Bool {
        switch count {
        case 1: contains(.x1)
        case 2: contains(.x2)
        case 4: contains(.x4)
        case 8: contains(.x8)
        default: false
        }
    }
}
