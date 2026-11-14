/// Glifo produzido pelo shaper.
public struct CajuShapedGlyph: Sendable, Equatable {
    public var glyph: UInt32
    /// Índice do escalar Unicode de origem na entrada.
    public var cluster: Int
    /// Avanço horizontal em em (1 = tamanho da fonte).
    public var advance: Float

    public init(glyph: UInt32, cluster: Int, advance: Float) {
        self.glyph = glyph
        self.cluster = cluster
        self.advance = advance
    }
}

/// Métricas verticais da fonte, em em.
public struct CajuFontMetrics: Sendable, Equatable {
    public var ascender: Float
    /// Negativo (abaixo da linha de base).
    public var descender: Float
    public var lineGap: Float

    public init(ascender: Float, descender: Float, lineGap: Float) {
        self.ascender = ascender
        self.descender = descender
        self.lineGap = lineGap
    }

    /// Altura natural de uma linha, em em.
    public var lineHeight: Float { ascender - descender + lineGap }
}

/// Converte escalares em glifos posicionados horizontalmente.
///
/// O backend HarfBuzz (PR dedicado ao `Package.swift`) implementa este protocolo para
/// scripts complexos, kerning e ligaduras; `CajuBasicShaper` cobre latino sem GPOS.
public protocol CajuTextShaper: Sendable {
    var metrics: CajuFontMetrics { get }
    func shape(_ scalars: [Unicode.Scalar]) -> [CajuShapedGlyph]
}

/// Shaper mínimo: um glifo por escalar via `cmap`, avanço de `hmtx`, sem kerning nem ligaduras.
public struct CajuBasicShaper: CajuTextShaper {
    public let font: CajuFont

    public init(font: CajuFont) { self.font = font }

    public var metrics: CajuFontMetrics {
        let upm = Float(font.unitsPerEm)
        return CajuFontMetrics(
            ascender: Float(font.ascender) / upm, descender: Float(font.descender) / upm,
            lineGap: Float(font.lineGap) / upm)
    }

    public func shape(_ scalars: [Unicode.Scalar]) -> [CajuShapedGlyph] {
        let upm = Float(font.unitsPerEm)
        var out: [CajuShapedGlyph] = []
        out.reserveCapacity(scalars.count)
        for (i, s) in scalars.enumerated() {
            let g = font.glyphID(for: s)
            out.append(CajuShapedGlyph(glyph: g, cluster: i, advance: Float(font.advance(of: g)) / upm))
        }
        return out
    }
}
