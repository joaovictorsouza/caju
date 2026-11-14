import CajuMath

/// Fonte TrueType (`glyf`) carregada de bytes, com validação de limites em toda leitura.
///
/// Suporta o necessário para texto latino no MVP: `head`, `maxp`, `hhea`, `hmtx`, `cmap`
/// (formatos 4 e 12), `loca` e `glyf` (simples e compostos). Kerning/GPOS, OpenType CFF e
/// scripts complexos entram com o backend HarfBuzz/FreeType (PR dedicado ao `Package.swift`).
///
/// ```swift
/// let font = try CajuFont(data: bytes)
/// let id = font.glyphID(for: "A")
/// let advance = font.advance(of: id)   // em unidades da fonte
/// ```
public struct CajuFont: Sendable {
    /// Limite de tamanho aceito de arquivo de fonte (16 MiB).
    public static let maxFileSize = 16 << 20
    static let maxCompositeDepth = 6
    static let maxPointsPerGlyph = 20_000

    public let unitsPerEm: Int
    public let ascender: Int
    public let descender: Int
    public let lineGap: Int
    public let glyphCount: Int

    private let reader: CajuByteReader
    private let locaOffset: Int
    private let locaLength: Int
    private let longLoca: Bool
    private let glyfOffset: Int
    private let glyfLength: Int
    private let hmtxOffset: Int
    private let hMetricCount: Int
    private let cmapSubtable: (offset: Int, format: Int)

    public init(data: [UInt8]) throws(CajuFontError) {
        guard data.count <= Self.maxFileSize else { throw .invalid(what: "tamanho do arquivo") }
        let r = CajuByteReader(bytes: data)
        guard let tag = r.u32(0) else { throw .truncated(what: "cabeçalho sfnt") }
        guard tag == 0x0001_0000 || tag == 0x7472_7565 else { throw .unsupportedFormat }  // 1.0 ou 'true'
        guard let numTables = r.u16(4) else { throw .truncated(what: "diretório de tabelas") }

        var tables: [UInt32: (offset: Int, length: Int)] = [:]
        for i in 0..<Int(numTables) {
            let rec = 12 + i * 16
            guard let t = r.u32(rec), let off = r.u32(rec + 8), let len = r.u32(rec + 12) else {
                throw .truncated(what: "registro de tabela")
            }
            guard r.contains(offset: Int(off), length: Int(len)) else {
                throw .invalid(what: "tabela fora do arquivo")
            }
            tables[t] = (Int(off), Int(len))
        }
        func table(_ name: String) throws(CajuFontError) -> (offset: Int, length: Int) {
            var tagValue: UInt32 = 0
            for b in name.utf8 { tagValue = tagValue << 8 | UInt32(b) }
            guard let t = tables[tagValue] else { throw .missingTable(name) }
            return t
        }

        let head = try table("head")
        guard head.length >= 54, let upm = r.u16(head.offset + 18), let locFmt = r.i16(head.offset + 50)
        else {
            throw .truncated(what: "head")
        }
        guard upm >= 16, upm <= 16_384 else { throw .invalid(what: "unitsPerEm") }
        guard locFmt == 0 || locFmt == 1 else { throw .invalid(what: "indexToLocFormat") }

        let maxp = try table("maxp")
        guard maxp.length >= 6, let ng = r.u16(maxp.offset + 4) else { throw .truncated(what: "maxp") }
        guard ng >= 1 else { throw .invalid(what: "numGlyphs") }

        let hhea = try table("hhea")
        guard hhea.length >= 36, let asc = r.i16(hhea.offset + 4), let desc = r.i16(hhea.offset + 6),
            let gap = r.i16(hhea.offset + 8), let nh = r.u16(hhea.offset + 34)
        else { throw .truncated(what: "hhea") }
        guard nh >= 1, Int(nh) <= Int(ng) else { throw .invalid(what: "numberOfHMetrics") }

        let hmtx = try table("hmtx")
        let hmtxNeeded = Int(nh) * 4 + (Int(ng) - Int(nh)) * 2
        guard hmtx.length >= hmtxNeeded else { throw .truncated(what: "hmtx") }

        let loca = try table("loca")
        let locaNeeded = (Int(ng) + 1) * (locFmt == 1 ? 4 : 2)
        guard loca.length >= locaNeeded else { throw .truncated(what: "loca") }
        let glyf = try table("glyf")

        let cmap = try table("cmap")
        guard let sub = Self.pickCmapSubtable(r, cmap: cmap) else {
            throw .invalid(what: "cmap sem subtabela Unicode")
        }

        reader = r
        unitsPerEm = Int(upm)
        ascender = Int(asc)
        descender = Int(desc)
        lineGap = Int(gap)
        glyphCount = Int(ng)
        locaOffset = loca.offset
        locaLength = loca.length
        longLoca = locFmt == 1
        glyfOffset = glyf.offset
        glyfLength = glyf.length
        hmtxOffset = hmtx.offset
        hMetricCount = Int(nh)
        cmapSubtable = sub
    }

    private static func pickCmapSubtable(
        _ r: CajuByteReader, cmap: (offset: Int, length: Int)
    ) -> (offset: Int, format: Int)? {
        guard let n = r.u16(cmap.offset + 2) else { return nil }
        var best: (offset: Int, format: Int, score: Int)?
        for i in 0..<Int(n) {
            let rec = cmap.offset + 4 + i * 8
            guard let platform = r.u16(rec), let encoding = r.u16(rec + 2), let off = r.u32(rec + 4) else {
                return nil
            }
            let sub = cmap.offset + Int(off)
            guard Int(off) < cmap.length, let format = r.u16(sub), format == 4 || format == 12 else {
                continue
            }
            let unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10))
            guard unicode else { continue }
            let score = (format == 12 ? 2 : 1)
            if best == nil || score > best!.score { best = (sub, Int(format), score) }
        }
        return best.map { ($0.offset, $0.format) }
    }

    // MARK: Consultas

    /// Glifo para um escalar Unicode; `0` (`.notdef`) quando a fonte não cobre.
    public func glyphID(for scalar: Unicode.Scalar) -> UInt32 {
        let cp = Int(scalar.value)
        let base = cmapSubtable.offset
        let found: Int?
        if cmapSubtable.format == 12 {
            found = lookupFormat12(base, cp)
        } else {
            found = cp <= 0xFFFF ? lookupFormat4(base, cp) : nil
        }
        guard let id = found, id > 0, id < glyphCount else { return 0 }
        return UInt32(id)
    }

    private func lookupFormat12(_ base: Int, _ cp: Int) -> Int? {
        guard let groups = reader.u32(base + 12) else { return nil }
        var lo = 0
        var hi = Int(min(groups, 1 << 20)) - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let rec = base + 16 + mid * 12
            guard let start = reader.u32(rec), let end = reader.u32(rec + 4), let gid = reader.u32(rec + 8)
            else {
                return nil
            }
            if cp < Int(start) {
                hi = mid - 1
            } else if cp > Int(end) {
                lo = mid + 1
            } else {
                return Int(gid) + (cp - Int(start))
            }
        }
        return nil
    }

    private func lookupFormat4(_ base: Int, _ cp: Int) -> Int? {
        guard let segX2 = reader.u16(base + 6) else { return nil }
        let segCount = Int(segX2) / 2
        let endCodes = base + 14
        let startCodes = endCodes + segCount * 2 + 2
        let deltas = startCodes + segCount * 2
        let rangeOffsets = deltas + segCount * 2
        var lo = 0
        var hi = segCount - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            guard let end = reader.u16(endCodes + mid * 2), let start = reader.u16(startCodes + mid * 2)
            else {
                return nil
            }
            if cp > Int(end) {
                lo = mid + 1
            } else if cp < Int(start) {
                hi = mid - 1
            } else {
                guard let delta = reader.u16(deltas + mid * 2), let ro = reader.u16(rangeOffsets + mid * 2)
                else {
                    return nil
                }
                if ro == 0 { return (cp + Int(delta)) & 0xFFFF }
                let addr = rangeOffsets + mid * 2 + Int(ro) + (cp - Int(start)) * 2
                guard let g = reader.u16(addr) else { return nil }
                return g == 0 ? 0 : (Int(g) + Int(delta)) & 0xFFFF
            }
        }
        return nil
    }

    /// Avanço horizontal em unidades da fonte (`0` para glifo inválido).
    public func advance(of glyph: UInt32) -> Int {
        let g = Int(glyph)
        guard g < glyphCount else { return 0 }
        let index = min(g, hMetricCount - 1)
        return Int(reader.u16(hmtxOffset + index * 4) ?? 0)
    }

    private func glyphRange(_ g: Int) -> (offset: Int, length: Int)? {
        guard g >= 0, g < glyphCount else { return nil }
        let a: Int?
        let b: Int?
        if longLoca {
            a = reader.u32(locaOffset + g * 4).map(Int.init)
            b = reader.u32(locaOffset + g * 4 + 4).map(Int.init)
        } else {
            a = reader.u16(locaOffset + g * 2).map { Int($0) * 2 }
            b = reader.u16(locaOffset + g * 2 + 2).map { Int($0) * 2 }
        }
        guard let s = a, let e = b, e >= s, e <= glyfLength else { return nil }
        return (glyfOffset + s, e - s)
    }

    /// Contorno do glifo em unidades da fonte; vazio para glifos sem contorno (espaço) ou inválidos.
    public func outline(of glyph: UInt32) -> CajuOutline {
        var points: [GlyphPoint] = []
        var ends: [Int] = []
        guard appendGlyph(Int(glyph), depth: 0, transform: .identity, points: &points, ends: &ends) else {
            return CajuOutline()
        }
        return Self.buildOutline(points: points, contourEnds: ends)
    }

    // MARK: glyf

    struct GlyphPoint {
        var x: Float
        var y: Float
        var onCurve: Bool
    }

    struct Affine {
        var a: Float = 1
        var b: Float = 0
        var c: Float = 0
        var d: Float = 1
        var tx: Float = 0
        var ty: Float = 0
        static let identity = Affine()
    }

    private func appendGlyph(
        _ glyph: Int, depth: Int, transform t: Affine, points: inout [GlyphPoint], ends: inout [Int]
    ) -> Bool {
        guard depth <= Self.maxCompositeDepth, let range = glyphRange(glyph) else { return false }
        if range.length == 0 { return true }  // glifo vazio é válido
        guard let nc = reader.i16(range.offset), range.length >= 10 else { return false }
        if nc >= 0 {
            return appendSimple(range, contours: Int(nc), transform: t, points: &points, ends: &ends)
        }
        return appendComposite(range, depth: depth, transform: t, points: &points, ends: &ends)
    }

    private func appendSimple(
        _ range: (offset: Int, length: Int), contours: Int, transform t: Affine,
        points: inout [GlyphPoint], ends: inout [Int]
    ) -> Bool {
        if contours == 0 { return true }
        var p = range.offset + 10
        let limit = range.offset + range.length
        var lastEnd = -1
        var localEnds: [Int] = []
        localEnds.reserveCapacity(contours)
        for _ in 0..<contours {
            guard let e = reader.u16(p), Int(e) > lastEnd else { return false }
            localEnds.append(Int(e))
            lastEnd = Int(e)
            p += 2
        }
        let count = lastEnd + 1
        guard count <= Self.maxPointsPerGlyph, points.count + count <= Self.maxPointsPerGlyph else {
            return false
        }
        guard let insLen = reader.u16(p) else { return false }
        p += 2 + Int(insLen)
        guard p <= limit else { return false }

        var flags = [UInt8](repeating: 0, count: count)
        var i = 0
        while i < count {
            guard p < limit, let f = reader.u8(p) else { return false }
            p += 1
            flags[i] = f
            i += 1
            if f & 8 != 0 {
                guard p < limit, let rep = reader.u8(p) else { return false }
                p += 1
                for _ in 0..<Int(rep) {
                    guard i < count else { return false }
                    flags[i] = f
                    i += 1
                }
            }
        }
        var xs = [Int](repeating: 0, count: count)
        var ys = [Int](repeating: 0, count: count)
        var cur = 0
        for k in 0..<count {
            let f = flags[k]
            if f & 2 != 0 {
                guard p < limit, let d = reader.u8(p) else { return false }
                p += 1
                cur += f & 16 != 0 ? Int(d) : -Int(d)
            } else if f & 16 == 0 {
                guard p + 2 <= limit, let d = reader.i16(p) else { return false }
                p += 2
                cur += Int(d)
            }
            xs[k] = cur
        }
        cur = 0
        for k in 0..<count {
            let f = flags[k]
            if f & 4 != 0 {
                guard p < limit, let d = reader.u8(p) else { return false }
                p += 1
                cur += f & 32 != 0 ? Int(d) : -Int(d)
            } else if f & 32 == 0 {
                guard p + 2 <= limit, let d = reader.i16(p) else { return false }
                p += 2
                cur += Int(d)
            }
            ys[k] = cur
        }
        let base = points.count
        for k in 0..<count {
            let x = Float(xs[k])
            let y = Float(ys[k])
            points.append(
                GlyphPoint(
                    x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty, onCurve: flags[k] & 1 != 0))
        }
        for e in localEnds { ends.append(base + e) }
        return true
    }

    private func appendComposite(
        _ range: (offset: Int, length: Int), depth: Int, transform t: Affine,
        points: inout [GlyphPoint], ends: inout [Int]
    ) -> Bool {
        var p = range.offset + 10
        let limit = range.offset + range.length
        var components = 0
        while true {
            guard components < 64, p + 4 <= limit, let flags = reader.u16(p), let gi = reader.u16(p + 2)
            else {
                return false
            }
            components += 1
            p += 4
            var dx: Float = 0
            var dy: Float = 0
            if flags & 1 != 0 {  // ARG_1_AND_2_ARE_WORDS
                guard p + 4 <= limit, let a = reader.i16(p), let b = reader.i16(p + 2) else { return false }
                p += 4
                if flags & 2 != 0 {
                    dx = Float(a)
                    dy = Float(b)
                }
            } else {
                guard p + 2 <= limit, let a = reader.u8(p), let b = reader.u8(p + 1) else { return false }
                p += 2
                if flags & 2 != 0 {
                    dx = Float(Int8(bitPattern: a))
                    dy = Float(Int8(bitPattern: b))
                }
            }
            func f2dot14(_ o: Int) -> Float? { reader.i16(o).map { Float($0) / 16384 } }
            var m = Affine()
            if flags & 8 != 0 {
                guard p + 2 <= limit, let s = f2dot14(p) else { return false }
                p += 2
                m.a = s
                m.d = s
            } else if flags & 0x40 != 0 {
                guard p + 4 <= limit, let sx = f2dot14(p), let sy = f2dot14(p + 2) else { return false }
                p += 4
                m.a = sx
                m.d = sy
            } else if flags & 0x80 != 0 {
                guard p + 8 <= limit, let a = f2dot14(p), let b = f2dot14(p + 2), let c = f2dot14(p + 4),
                    let d = f2dot14(p + 6)
                else { return false }
                p += 8
                m.a = a
                m.b = b
                m.c = c
                m.d = d
            }
            m.tx = dx
            m.ty = dy
            // child = m * v ; total = t * child
            let total = Affine(
                a: t.a * m.a + t.c * m.b, b: t.b * m.a + t.d * m.b,
                c: t.a * m.c + t.c * m.d, d: t.b * m.c + t.d * m.d,
                tx: t.a * m.tx + t.c * m.ty + t.tx, ty: t.b * m.tx + t.d * m.ty + t.ty)
            guard appendGlyph(Int(gi), depth: depth + 1, transform: total, points: &points, ends: &ends)
            else {
                return false
            }
            if flags & 0x20 == 0 { break }  // sem MORE_COMPONENTS
        }
        return true
    }

    /// Converte pontos TrueType (com pontos de controle implícitos) em segmentos.
    static func buildOutline(points: [GlyphPoint], contourEnds: [Int]) -> CajuOutline {
        var contours: [[CajuOutlineSegment]] = []
        var start = 0
        for end in contourEnds {
            defer { start = end + 1 }
            guard end >= start, end < points.count else { continue }
            var pts = Array(points[start...end])
            if pts.count < 2 { continue }
            // Garante um ponto inicial on-curve (insere o ponto médio se todos forem off-curve).
            if let firstOn = pts.firstIndex(where: { $0.onCurve }) {
                pts = Array(pts[firstOn...] + pts[..<firstOn])
            } else {
                let mid = GlyphPoint(
                    x: (pts[0].x + pts[pts.count - 1].x) / 2, y: (pts[0].y + pts[pts.count - 1].y) / 2,
                    onCurve: true)
                pts.insert(mid, at: 0)
            }
            var segs: [CajuOutlineSegment] = []
            var cur = CajuVec2(pts[0].x, pts[0].y)
            let first = cur
            var pending: CajuVec2?
            func emit(to p: CajuVec2) {
                if let c = pending {
                    segs.append(.quad(cur, c, p))
                    pending = nil
                } else if p != cur {
                    segs.append(.line(cur, p))
                }
                cur = p
            }
            for k in 1..<pts.count {
                let q = CajuVec2(pts[k].x, pts[k].y)
                if pts[k].onCurve {
                    emit(to: q)
                } else if let c = pending {
                    emit(to: CajuVec2((c.x + q.x) / 2, (c.y + q.y) / 2))
                    pending = q
                } else {
                    pending = q
                }
            }
            emit(to: first)
            if !segs.isEmpty { contours.append(segs) }
        }
        return CajuOutline(contours: contours)
    }
}
