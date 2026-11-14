import CajuMath

/// Alinhamento horizontal das linhas.
public enum CajuTextAlignment: Sendable, Equatable {
    case leading, center, trailing
}

/// Parâmetros de medida e quebra de linha.
public struct CajuTextStyle: Sendable, Equatable {
    /// Tamanho da fonte (altura de 1 em), em unidades de layout.
    public var fontSize: Float
    /// Largura máxima; `nil` = sem quebra automática (só `\n`).
    public var maxWidth: Float?
    /// Altura da linha em unidades de layout; `nil` usa a métrica da fonte.
    public var lineHeight: Float?
    public var alignment: CajuTextAlignment

    public init(
        fontSize: Float, maxWidth: Float? = nil, lineHeight: Float? = nil,
        alignment: CajuTextAlignment = .leading
    ) {
        self.fontSize = fontSize
        self.maxWidth = maxWidth
        self.lineHeight = lineHeight
        self.alignment = alignment
    }
}

/// Glifo posicionado. `x` é a origem do glifo; `baseline` a linha de base (y para baixo).
public struct CajuPlacedGlyph: Sendable, Equatable {
    public var glyph: UInt32
    public var cluster: Int
    public var x: Float
    public var baseline: Float
    public var advance: Float
}

/// Uma linha do layout.
public struct CajuTextLine: Sendable, Equatable {
    /// Faixa em `CajuTextLayout.glyphs`.
    public var glyphRange: Range<Int>
    /// Faixa de escalares Unicode do texto de origem (sem a quebra de linha).
    public var scalarRange: Range<Int>
    /// Largura sem os espaços finais.
    public var width: Float
    public var baseline: Float
    /// Deslocamento horizontal aplicado pelo alinhamento.
    public var xOffset: Float
}

/// Resultado de medir e quebrar um texto. Aloca; recalcule só quando texto/estilo mudam.
///
/// ```swift
/// let layout = CajuTextLayout(text: "olá mundo", shaper: shaper, style: .init(fontSize: 16, maxWidth: 80))
/// layout.size   // largura e altura medidas
/// ```
public struct CajuTextLayout: Sendable, Equatable {
    public private(set) var glyphs: [CajuPlacedGlyph] = []
    public private(set) var lines: [CajuTextLine] = []
    public private(set) var size: CajuVec2 = .zero
    public private(set) var scalarCount: Int = 0
    public private(set) var lineHeight: Float = 0
    let style: CajuTextStyle

    public init(text: String, shaper: some CajuTextShaper, style: CajuTextStyle) {
        self.init(scalars: Array(text.unicodeScalars), shaper: shaper, style: style)
    }

    public init(scalars: [Unicode.Scalar], shaper: some CajuTextShaper, style: CajuTextStyle) {
        self.style = style
        scalarCount = scalars.count
        let metrics = shaper.metrics
        let size = max(style.fontSize, 0)
        let natural = metrics.lineHeight * size
        let lineHeight = style.lineHeight ?? natural
        let shaped = shaper.shape(scalars)
        let n = shaped.count
        let maxWidth = style.maxWidth.map { max($0, 0) }

        func scalar(_ g: CajuShapedGlyph) -> Unicode.Scalar? {
            g.cluster >= 0 && g.cluster < scalars.count ? scalars[g.cluster] : nil
        }
        func isHardBreak(_ s: Unicode.Scalar?) -> Bool {
            s == "\n" || s == "\u{2028}" || s == "\u{2029}"
        }
        func isSpace(_ s: Unicode.Scalar?) -> Bool { s == " " || s == "\t" }

        func width(_ from: Int, _ to: Int) -> Float {
            var w: Float = 0
            var k = from
            while k < to {
                w += shaped[k].advance * size
                k += 1
            }
            var t = to - 1
            while t >= from, isSpace(scalar(shaped[t])) {
                w -= shaped[t].advance * size
                t -= 1
            }
            return max(w, 0)
        }

        var i = 0
        var maxLine: Float = 0
        var raw: [(start: Int, end: Int, width: Float, scalarStart: Int, scalarEnd: Int)] = []
        while true {
            var j = i
            var x: Float = 0
            var lastBreak = -1
            var end = n
            var next = n
            var finished = true
            var scalarEnd = scalars.count
            let scalarStart = i < n ? shaped[i].cluster : scalars.count
            while j < n {
                let g = shaped[j]
                let s = scalar(g)
                if isHardBreak(s) {
                    end = j
                    next = j + 1
                    scalarEnd = g.cluster
                    finished = false
                    break
                }
                let adv = g.advance * size
                if let mw = maxWidth, !isSpace(s), j > i, x + adv > mw + 1e-4 {
                    end = lastBreak > i ? lastBreak : j
                    next = end
                    scalarEnd = shaped[next].cluster
                    finished = false
                    break
                }
                x += adv
                j += 1
                let following = j < n ? scalar(shaped[j]) : nil
                let afterHyphen =
                    s == "-" && j - 1 > i && following != nil && !isSpace(following)
                    && !isHardBreak(following)
                if isSpace(s) || s == "\u{200B}" || afterHyphen { lastBreak = j }
            }
            let w = width(i, end)
            raw.append((i, end, w, scalarStart, scalarEnd))
            maxLine = max(maxLine, w)
            if finished || raw.count >= 1 << 20 { break }
            i = next
        }

        let boundWidth = maxWidth ?? maxLine
        var placed: [CajuPlacedGlyph] = []
        placed.reserveCapacity(n)
        var out: [CajuTextLine] = []
        for (k, line) in raw.enumerated() {
            let baseline = Float(k) * lineHeight + (lineHeight - natural) / 2 + metrics.ascender * size
            let slack = max(boundWidth - line.width, 0)
            let offset: Float =
                switch style.alignment {
                case .leading: 0
                case .center: slack / 2
                case .trailing: slack
                }
            let first = placed.count
            var pen: Float = 0
            for gi in line.start..<line.end {
                let g = shaped[gi]
                placed.append(
                    CajuPlacedGlyph(
                        glyph: g.glyph, cluster: g.cluster, x: offset + pen, baseline: baseline,
                        advance: g.advance * size))
                pen += g.advance * size
            }
            out.append(
                CajuTextLine(
                    glyphRange: first..<placed.count,
                    scalarRange: line.scalarStart..<max(line.scalarStart, line.scalarEnd),
                    width: line.width, baseline: baseline, xOffset: offset))
        }
        glyphs = placed
        lines = out
        self.lineHeight = lineHeight
        self.size = CajuVec2(maxLine, Float(out.count) * lineHeight)
    }

    // MARK: Caret e hit-testing

    /// Posição do cursor (x, topo da linha) para um deslocamento em escalares.
    public func caretPosition(scalarOffset: Int) -> (line: Int, x: Float, top: Float, height: Float) {
        let offset = max(0, min(scalarOffset, scalarCount))
        // Em fronteira de quebra suave, o cursor fica no início da linha seguinte.
        var li = 0
        for (k, line) in lines.enumerated() where line.scalarRange.lowerBound <= offset { li = k }
        let line = lines[li]
        var x = line.xOffset
        for g in glyphs[line.glyphRange] {
            if g.cluster >= offset {
                x = g.x
                break
            }
            x = g.x + g.advance
        }
        let lh = lineHeight
        return (li, x, Float(li) * lh, lh)
    }

    /// Deslocamento em escalares mais próximo de um ponto (coordenadas do layout, y para baixo).
    public func scalarOffset(at point: CajuVec2) -> Int {
        guard !lines.isEmpty else { return 0 }
        let li = max(0, min(lines.count - 1, Int((point.y / max(lineHeight, 1e-6)).rounded(.down))))
        let line = lines[li]
        for g in glyphs[line.glyphRange] where point.x < g.x + g.advance / 2 { return g.cluster }
        if let last = glyphs[line.glyphRange].last { return last.cluster + 1 }
        return line.scalarRange.lowerBound
    }
}
