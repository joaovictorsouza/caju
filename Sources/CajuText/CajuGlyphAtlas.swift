import CajuMath

/// Entrada de um glifo no atlas MSDF.
public struct CajuAtlasGlyph: Sendable, Equatable {
    /// Retângulo no bitmap, em pixels (origem no topo esquerdo). Vazio para glifos sem contorno.
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// Caixa do quad em unidades de em (1 = tamanho da fonte), relativa à origem do glifo na linha
    /// de base, já incluindo a margem de `pixelRange`.
    public var planeMin: CajuVec2
    public var planeMax: CajuVec2
    /// Avanço horizontal em em.
    public var advance: Float
}

/// Erros do atlas.
public enum CajuAtlasError: Error, Sendable, Equatable {
    /// Não há espaço para o glifo; crie outra página ou use um atlas maior.
    case full
    case invalidConfiguration
}

/// Atlas MSDF de uma fonte, em bitmap RGBA8 de CPU, com empacotamento em prateleiras.
///
/// Os glifos são gerados sob demanda (`glyph(_:)`); `dirtyRect` informa a região a reenviar à GPU.
/// Consulta de glifo já presente não aloca.
public struct CajuGlyphAtlas: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var pageSize: Int = 1024
        /// Tamanho de em em pixels no atlas (resolução de geração).
        public var emPixels: Float = 32
        /// Alcance da distância, em pixels do atlas.
        public var pixelRange: Float = 4
        public init() {}
    }

    public let configuration: Configuration
    public private(set) var pixels: [UInt8]
    /// Região modificada desde a última chamada a `clearDirty()`; `nil` se limpa.
    public private(set) var dirtyRect: (x: Int, y: Int, width: Int, height: Int)?

    private let font: CajuFont
    private var glyphs: [UInt32: CajuAtlasGlyph] = [:]
    private var shelfY = 0
    private var shelfHeight = 0
    private var cursorX = 0

    public init(font: CajuFont, configuration: Configuration = Configuration()) throws(CajuAtlasError) {
        let c = configuration
        guard c.pageSize >= 64, c.pageSize <= 4096, c.emPixels >= 8, c.emPixels <= 256,
            c.pixelRange >= 1, c.pixelRange <= c.emPixels
        else { throw .invalidConfiguration }
        self.font = font
        self.configuration = c
        pixels = [UInt8](repeating: 0, count: c.pageSize * c.pageSize * 4)
    }

    /// Número de glifos já gerados.
    public var glyphCount: Int { glyphs.count }

    public mutating func clearDirty() { dirtyRect = nil }

    /// Entrada do glifo; gera o MSDF e empacota na primeira consulta.
    public mutating func glyph(_ id: UInt32) throws(CajuAtlasError) -> CajuAtlasGlyph {
        if let g = glyphs[id] { return g }
        let upm = Float(font.unitsPerEm)
        let advance = Float(font.advance(of: id)) / upm
        let outline = font.outline(of: id)
        guard let b = outline.bounds else {
            let g = CajuAtlasGlyph(
                x: 0, y: 0, width: 0, height: 0, planeMin: .zero, planeMax: .zero, advance: advance)
            glyphs[id] = g
            return g
        }
        let scale = configuration.emPixels / upm
        let pad = configuration.pixelRange
        let w = Int(((b.max.x - b.min.x) * scale + 2 * pad).rounded(.up))
        let h = Int(((b.max.y - b.min.y) * scale + 2 * pad).rounded(.up))
        guard w <= configuration.pageSize, h <= configuration.pageSize else { throw .full }
        if cursorX + w > configuration.pageSize {
            shelfY += shelfHeight
            shelfHeight = 0
            cursorX = 0
        }
        guard shelfY + h <= configuration.pageSize else { throw .full }
        let origin = CajuVec2(b.min.x - pad / scale, b.min.y - pad / scale)
        let bitmap = CajuMSDF.render(
            outline: outline, width: w, height: h, scale: scale, origin: origin, pixelRange: pad)
        let size = configuration.pageSize
        for row in 0..<h {
            let src = row * w * 4
            let dst = ((shelfY + row) * size + cursorX) * 4
            for i in 0..<(w * 4) { pixels[dst + i] = bitmap[src + i] }
        }
        let plane0 = CajuVec2(origin.x / upm, origin.y / upm)
        let plane1 = CajuVec2(
            plane0.x + Float(w) / configuration.emPixels, plane0.y + Float(h) / configuration.emPixels)
        let g = CajuAtlasGlyph(
            x: cursorX, y: shelfY, width: w, height: h, planeMin: plane0, planeMax: plane1, advance: advance)
        glyphs[id] = g
        merge(dirty: (cursorX, shelfY, w, h))
        cursorX += w
        shelfHeight = max(shelfHeight, h)
        return g
    }

    private mutating func merge(dirty r: (x: Int, y: Int, width: Int, height: Int)) {
        guard let d = dirtyRect else {
            dirtyRect = r
            return
        }
        let x0 = min(d.x, r.x)
        let y0 = min(d.y, r.y)
        let x1 = max(d.x + d.width, r.x + r.width)
        let y1 = max(d.y + d.height, r.y + r.height)
        dirtyRect = (x0, y0, x1 - x0, y1 - y0)
    }
}
