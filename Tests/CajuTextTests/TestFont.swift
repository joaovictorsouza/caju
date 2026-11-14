/// Constrói em memória uma fonte TrueType mínima e determinística para os testes.
///
/// Glifos (unitsPerEm = 1000): 0 `.notdef` (vazio), 1 espaço (vazio, avanço 300),
/// 2 `A` (quadrado 100..700), 3 `B` (triângulo), 4 `O` (quadrado externo + buraco),
/// 5 `C` (contorno com curva quadrática), 6 `-` (barra), 7 composto de `A` deslocado.
/// cmap formato 4: ' ' → 1, 'A' → 2, 'B' → 3, 'O' → 4, 'C' → 5, '-' → 6, 'D' → 7, 'x'..'z' → 2.
enum TestFont {
    struct W {
        var b: [UInt8] = []
        mutating func u8(_ v: Int) { b.append(UInt8(truncatingIfNeeded: v)) }
        mutating func u16(_ v: Int) {
            u8(v >> 8)
            u8(v)
        }
        mutating func i16(_ v: Int) { u16(v & 0xFFFF) }
        mutating func u32(_ v: Int) {
            u16(v >> 16)
            u16(v & 0xFFFF)
        }
        mutating func pad4() { while b.count % 4 != 0 { b.append(0) } }
    }

    /// Glifo simples: contornos como listas de (x, y, onCurve), coordenadas como Int16 completos.
    static func simple(_ contours: [[(Int, Int, Bool)]]) -> [UInt8] {
        var w = W()
        let all = contours.flatMap { $0 }
        w.i16(contours.count)
        w.i16(all.map { $0.0 }.min() ?? 0)
        w.i16(all.map { $0.1 }.min() ?? 0)
        w.i16(all.map { $0.0 }.max() ?? 0)
        w.i16(all.map { $0.1 }.max() ?? 0)
        var end = -1
        for c in contours {
            end += c.count
            w.u16(end)
        }
        w.u16(0)  // instruções
        for p in all { w.u8(p.2 ? 1 : 0) }  // flags: coordenadas como int16
        var px = 0
        for p in all {
            w.i16(p.0 - px)
            px = p.0
        }
        var py = 0
        for p in all {
            w.i16(p.1 - py)
            py = p.1
        }
        w.pad4()
        return w.b
    }

    static func composite(glyph: Int, dx: Int, dy: Int) -> [UInt8] {
        var w = W()
        w.i16(-1)
        w.i16(0)
        w.i16(0)
        w.i16(0)
        w.i16(0)
        w.u16(0x0001 | 0x0002)  // words + xy values
        w.u16(glyph)
        w.i16(dx)
        w.i16(dy)
        w.pad4()
        return w.b
    }

    static func make() -> [UInt8] {
        let square = [[(100, 0, true), (100, 700, true), (700, 700, true), (700, 0, true)]]  // horário
        let hole = [(300, 200, true), (500, 200, true), (500, 500, true), (300, 500, true)]  // anti-horário
        let glyphs: [[UInt8]] = [
            [], [],
            simple(square),
            simple([[(100, 0, true), (400, 700, true), (700, 0, true)]]),
            simple(square + [hole]),
            simple([[(100, 0, true), (100, 700, true), (700, 700, false), (700, 0, true)]]),
            simple([[(100, 250, true), (100, 350, true), (500, 350, true), (500, 250, true)]]),
            composite(glyph: 2, dx: 50, dy: 0),
        ]
        var glyf: [UInt8] = []
        var loca = W()
        for g in glyphs {
            loca.u32(glyf.count)
            glyf += g
        }
        loca.u32(glyf.count)

        var head = W()
        head.u32(0x0001_0000)
        head.u32(0)
        head.u32(0)
        head.u32(0x5F0F_3CF5)
        head.u16(0)
        head.u16(1000)
        for _ in 0..<16 { head.u8(0) }  // created/modified
        head.i16(0)
        head.i16(0)
        head.i16(1000)
        head.i16(1000)
        head.u16(0)
        head.u16(8)
        head.i16(2)
        head.i16(1)  // indexToLocFormat = long
        head.i16(0)
        var maxp = W()
        maxp.u32(0x0001_0000)
        maxp.u16(glyphs.count)
        var hhea = W()
        hhea.u32(0x0001_0000)
        hhea.i16(800)
        hhea.i16(-200)
        hhea.i16(100)
        for _ in 0..<24 { hhea.u8(0) }  // extents, caret, reservados e metricDataFormat
        hhea.u16(glyphs.count)
        var hmtx = W()
        let advances = [500, 300, 800, 800, 800, 800, 500, 800]
        for a in advances {
            hmtx.u16(a)
            hmtx.i16(0)
        }

        // cmap formato 4: segmentos [32..32], [43..45 só '-'=45], 'A','B','C','D','O', 'x'..'z', 0xFFFF.
        let segs: [(Int, Int, Int)] = [  // (start, end, glyph inicial)
            (32, 32, 1), (45, 45, 6), (65, 65, 2), (66, 66, 3), (67, 67, 5), (68, 68, 7), (79, 79, 4),
            (120, 122, 2),
        ]
        var c4 = W()
        let n = segs.count + 1
        c4.u16(4)
        c4.u16(16 + n * 8)
        c4.u16(0)
        c4.u16(n * 2)
        c4.u16(0)
        c4.u16(0)
        c4.u16(0)
        for s in segs { c4.u16(s.1) }
        c4.u16(0xFFFF)
        c4.u16(0)
        for s in segs { c4.u16(s.0) }
        c4.u16(0xFFFF)
        for s in segs { c4.u16((s.2 - s.0) & 0xFFFF) }
        c4.u16(1)
        for _ in 0..<n { c4.u16(0) }
        var cmap = W()
        cmap.u16(0)
        cmap.u16(1)
        cmap.u16(3)
        cmap.u16(1)
        cmap.u32(12)
        cmap.b += c4.b

        let tables: [(String, [UInt8])] = [
            ("cmap", cmap.b), ("glyf", glyf), ("head", head.b), ("hhea", hhea.b), ("hmtx", hmtx.b),
            ("loca", loca.b), ("maxp", maxp.b),
        ]
        var out = W()
        out.u32(0x0001_0000)
        out.u16(tables.count)
        out.u16(0)
        out.u16(0)
        out.u16(0)
        var offset = 12 + tables.count * 16
        var body: [UInt8] = []
        for (tag, data) in tables {
            for ch in tag.utf8 { out.u8(Int(ch)) }
            out.u32(0)
            out.u32(offset)
            out.u32(data.count)
            var padded = data
            while padded.count % 4 != 0 { padded.append(0) }
            body += padded
            offset += padded.count
        }
        return out.b + body
    }
}
