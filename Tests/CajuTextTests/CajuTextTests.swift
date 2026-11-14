import CajuMath
import CajuTesting
import CajuText
import Testing

private func loadFont() throws -> CajuFont { try CajuFont(data: TestFont.make()) }

@Suite("CajuFont")
struct CajuFontTests {
    @Test func metricsAndCmap() throws {
        let f = try loadFont()
        #expect(f.unitsPerEm == 1000)
        #expect(f.ascender == 800 && f.descender == -200 && f.lineGap == 100)
        #expect(f.glyphID(for: "A") == 2)
        #expect(f.glyphID(for: "x") == 2 && f.glyphID(for: "z") == 4)
        #expect(f.glyphID(for: "Q") == 0)
        #expect(f.glyphID(for: "😀") == 0)
        #expect(f.advance(of: 2) == 800)
        #expect(f.advance(of: 1) == 300)
        #expect(f.advance(of: 9999) == 0)
    }

    @Test func outlines() throws {
        let f = try loadFont()
        #expect(f.outline(of: 1).isEmpty)
        let a = f.outline(of: 2)
        #expect(a.contours.count == 1 && a.contours[0].count == 4)
        #expect(a.bounds?.min == CajuVec2(100, 0) && a.bounds?.max == CajuVec2(700, 700))
        #expect(f.outline(of: 4).contours.count == 2)
        // Curva quadrática: ponto off-curve vira segmento .quad.
        let c = f.outline(of: 5).contours[0]
        #expect(c.contains { if case .quad = $0 { true } else { false } })
        // Composto: A deslocado 50 em x.
        #expect(f.outline(of: 7).bounds?.min == CajuVec2(150, 0))
    }

    @Test func rejectsGarbage() {
        #expect(throws: CajuFontError.self) { try CajuFont(data: []) }
        #expect(throws: CajuFontError.self) { try CajuFont(data: [0, 1, 0, 0, 0, 5]) }
        #expect(throws: CajuFontError.self) {
            try CajuFont(data: Array("OTTO".utf8) + [UInt8](repeating: 0, count: 20))
        }
    }

    /// Fuzz: mutações de bytes e truncamentos nunca travam nem leem fora do limite.
    @Test func fuzzNeverCrashes() {
        let base = TestFont.make()
        CajuFuzz.run(iterations: 3_000) { rng, _ in
            var data = base
            switch rng.next() % 3 {
            case 0:
                for _ in 0..<(1 + Int(rng.next() % 8)) {
                    data[Int(rng.next() % UInt64(data.count))] = UInt8(truncatingIfNeeded: rng.next())
                }
            case 1: data = Array(data.prefix(Int(rng.next() % UInt64(data.count))))
            default:
                data = (0..<Int(rng.next() % 600)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            }
            guard let f = try? CajuFont(data: data) else { return }
            for g in 0..<min(f.glyphCount, 64) {
                _ = f.outline(of: UInt32(g))
                _ = f.advance(of: UInt32(g))
            }
            for s in ["A", " ", "z", "\u{10FFFF}", "\u{FFFF}"] { _ = f.glyphID(for: s.unicodeScalars.first!) }
        }
    }
}

@Suite("CajuMSDF")
struct CajuMSDFTests {
    private func sample(_ px: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> Float {
        let i = (y * w + x) * 4
        return CajuMSDF.median(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) / 255
    }

    @Test func squareInsideOutside() throws {
        let f = try loadFont()
        let outline = f.outline(of: 2)  // 100..700
        let scale: Float = 0.04  // 40 px por 1000 unidades
        let pad: Float = 4
        let origin = CajuVec2(100 - pad / scale, 0 - pad / scale)
        let w = Int((600 * scale + 2 * pad).rounded(.up))
        let h = Int((700 * scale + 2 * pad).rounded(.up))
        let px = CajuMSDF.render(
            outline: outline, width: w, height: h, scale: scale, origin: origin, pixelRange: pad)
        #expect(px.count == w * h * 4)
        #expect(sample(px, w, w / 2, h / 2) > 0.6)  // dentro
        #expect(sample(px, w, 0, 0) < 0.4)  // fora (canto)
        #expect(sample(px, w, w / 2, 0) < 0.4)
        // Canto preservado: pixel logo fora do canto superior direito continua fora.
        #expect(sample(px, w, w - 3, 3) < 0.5)
        // Canal alfa opaco.
        #expect(px[3] == 255)
    }

    @Test func holeIsOutside() throws {
        let f = try loadFont()
        let outline = f.outline(of: 4)
        let scale: Float = 0.04
        let pad: Float = 4
        let origin = CajuVec2(100 - pad / scale, -pad / scale)
        let w = Int((600 * scale + 2 * pad).rounded(.up))
        let h = Int((700 * scale + 2 * pad).rounded(.up))
        let px = CajuMSDF.render(
            outline: outline, width: w, height: h, scale: scale, origin: origin, pixelRange: pad)
        // Centro (400, 350) fica no buraco; ponto (150, 100) no anel.
        func at(_ ux: Float, _ uy: Float) -> Float {
            sample(px, w, Int((ux - origin.x) * scale), h - 1 - Int((uy - origin.y) * scale))
        }
        #expect(at(400, 350) < 0.4)
        #expect(at(150, 100) > 0.6)
    }

    @Test func curveShapeStaysConsistent() throws {
        let f = try loadFont()
        let outline = f.outline(of: 5)
        let scale: Float = 0.04
        let origin = CajuVec2(-60, -100)
        let px = CajuMSDF.render(
            outline: outline, width: 40, height: 40, scale: scale, origin: origin, pixelRange: 4)
        #expect(sample(px, 40, 8, 30) > 0.5)  // (≈ 140, 100 unidades) dentro
        #expect(sample(px, 40, 39, 0) < 0.5)  // longe, fora
    }

    @Test func emptyAndDegenerateInputs() {
        #expect(
            CajuMSDF.render(
                outline: CajuOutline(), width: 0, height: 5, scale: 1, origin: .zero, pixelRange: 4
            ).isEmpty)
        let px = CajuMSDF.render(
            outline: CajuOutline(), width: 4, height: 4, scale: 1, origin: .zero, pixelRange: 4)
        #expect(px.count == 64)
        #expect(
            CajuMSDF.render(
                outline: CajuOutline(), width: 4, height: 4, scale: -1, origin: .zero, pixelRange: 0
            ).count == 64)
    }
}

@Suite("CajuGlyphAtlas")
struct CajuGlyphAtlasTests {
    @Test func packsAndCaches() throws {
        let f = try loadFont()
        var atlas = try CajuGlyphAtlas(font: f)
        let a = try atlas.glyph(2)
        let b = try atlas.glyph(3)
        #expect(a.width > 0 && a.height > 0)
        #expect(a.advance == 0.8)
        #expect(b.x >= a.x + a.width || b.y > a.y)  // sem sobreposição
        #expect(try atlas.glyph(2) == a)
        #expect(atlas.glyphCount == 2)
        #expect(atlas.dirtyRect != nil)
        atlas.clearDirty()
        #expect(atlas.dirtyRect == nil)
        let space = try atlas.glyph(1)
        #expect(space.width == 0 && space.advance == 0.3)
        // O interior do glifo no bitmap está acima de 0.5.
        let cx = a.x + a.width / 2
        let cy = a.y + a.height / 2
        let i = (cy * atlas.configuration.pageSize + cx) * 4
        #expect(atlas.pixels[i] > 128)
    }

    @Test func reportsFullAndInvalidConfig() throws {
        let f = try loadFont()
        var cfg = CajuGlyphAtlas.Configuration()
        cfg.pageSize = 64
        cfg.emPixels = 64
        var atlas = try CajuGlyphAtlas(font: f, configuration: cfg)
        _ = try atlas.glyph(2)
        #expect(throws: CajuAtlasError.full) { try atlas.glyph(3) }
        cfg.pageSize = 10
        #expect(throws: CajuAtlasError.invalidConfiguration) {
            try CajuGlyphAtlas(font: f, configuration: cfg)
        }
    }
}

@Suite("CajuTextLayout")
struct CajuTextLayoutTests {
    // Avanços: A/B/O/C/x = 0.8 em, espaço = 0.3, '-' = 0.5; fontSize 10 ⇒ 8, 3, 5.
    private func layout(_ text: String, maxWidth: Float? = nil, alignment: CajuTextAlignment = .leading)
        throws
        -> CajuTextLayout
    {
        let shaper = CajuBasicShaper(font: try loadFont())
        return CajuTextLayout(
            text: text, shaper: shaper,
            style: CajuTextStyle(fontSize: 10, maxWidth: maxWidth, alignment: alignment))
    }

    @Test func measuresSingleLine() throws {
        let l = try layout("AB A")
        #expect(l.lines.count == 1)
        #expect(l.size.x == 8 + 8 + 3 + 8)
        #expect(l.size.y == 10 * (0.8 + 0.2 + 0.1))  // 11
        #expect(l.glyphs.map(\.x) == [0, 8, 16, 19])
        #expect(l.lines[0].baseline == 8)
    }

    @Test func wrapsAtSpacesAndDropsTrailingSpaceFromWidth() throws {
        let l = try layout("AB AB AB", maxWidth: 20)
        #expect(l.lines.count == 3)
        #expect(l.lines.map(\.scalarRange) == [0..<3, 3..<6, 6..<8])
        #expect(l.lines.map(\.width) == [16, 16, 16])
        #expect(l.size.y == 33)
    }

    @Test func hardBreaksAndTrailingNewline() throws {
        let l = try layout("A\nB\n")
        #expect(l.lines.count == 3)
        #expect(l.lines[0].scalarRange == 0..<1)
        #expect(l.lines[1].scalarRange == 2..<3)
        #expect(l.lines[2].glyphRange.isEmpty)
        #expect(try layout("").lines.count == 1)
    }

    @Test func breaksLongWordByCharacterAndAlwaysProgresses() throws {
        let l = try layout("AAAAA", maxWidth: 17)
        #expect(l.lines.map(\.glyphRange.count) == [2, 2, 1])
        let tiny = try layout("AAA", maxWidth: 1)
        #expect(tiny.lines.count == 3)
    }

    @Test func breaksAfterHyphen() throws {
        let l = try layout("A-B", maxWidth: 14)
        #expect(l.lines.map(\.scalarRange) == [0..<2, 2..<3])
    }

    @Test func alignment() throws {
        let c = try layout("A\nAB", maxWidth: nil, alignment: .trailing)
        #expect(c.glyphs[0].x == 8)  // 16 - 8
        let m = try layout("A\nAB", alignment: .center)
        #expect(m.glyphs[0].x == 4)
    }

    @Test func caretAndHitTest() throws {
        let l = try layout("AB AB", maxWidth: 20)  // linhas: "AB " e "AB"
        let c0 = l.caretPosition(scalarOffset: 0)
        #expect(c0.line == 0 && c0.x == 0)
        let c1 = l.caretPosition(scalarOffset: 1)
        #expect(c1.x == 8)
        let c3 = l.caretPosition(scalarOffset: 3)  // fronteira de quebra: início da 2ª linha
        #expect(c3.line == 1 && c3.x == 0 && c3.top == 11)
        #expect(l.caretPosition(scalarOffset: 99).line == 1)
        #expect(l.scalarOffset(at: CajuVec2(5, 1)) == 1)
        #expect(l.scalarOffset(at: CajuVec2(1, 1)) == 0)
        #expect(l.scalarOffset(at: CajuVec2(100, 12)) == 5)
    }

    @Test func fuzzTextNeverCrashes() throws {
        let shaper = CajuBasicShaper(font: try loadFont())
        let alphabet: [Unicode.Scalar] = ["A", "B", " ", "-", "\n", "x", "\u{200B}", "é", "😀", "\t"]
        CajuFuzz.run(iterations: 2_000) { rng, _ in
            let n = Int(rng.next() % 40)
            let scalars = (0..<n).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }
            let mw: Float? = rng.next() % 3 == 0 ? nil : Float(rng.next() % 60)
            let l = CajuTextLayout(
                scalars: scalars, shaper: shaper, style: CajuTextStyle(fontSize: 10, maxWidth: mw))
            #expect(!l.lines.isEmpty)
            // Todo glifo pertence a exatamente uma linha; larguras respeitam o limite (exceto 1 glifo).
            #expect(l.lines.reduce(0) { $0 + $1.glyphRange.count } == l.glyphs.count)
            if let mw {
                for line in l.lines {
                    let visible = l.glyphs[line.glyphRange].filter {
                        scalars[$0.cluster] != " " && scalars[$0.cluster] != "\t"
                    }
                    if visible.count > 1 { #expect(line.width <= mw + 1e-3) }
                }
            }
            _ = l.caretPosition(scalarOffset: Int(rng.next() % 50))
            _ = l.scalarOffset(at: CajuVec2(Float(rng.next() % 100), Float(rng.next() % 100)))
        }
    }
}

@Suite("CajuTextEditorModel")
struct CajuTextEditorModelTests {
    @Test func insertDeleteAndSelection() {
        var e = CajuTextEditorModel(text: "olá")
        e.insert(" mundo")
        #expect(e.text == "olá mundo" && e.caret == 9)
        e.deleteBackward()
        #expect(e.text == "olá mund")
        e.moveToStart()
        e.deleteForward()
        #expect(e.text == "lá mund")
        e.selectAll()
        #expect(e.selectedText == "lá mund")
        e.insert("x")
        #expect(e.text == "x" && !e.hasSelection)
    }

    @Test func movementAndWords() {
        var e = CajuTextEditorModel(text: "ab cd  ef")
        e.moveToStart()
        e.moveWord(forward: true)
        #expect(e.caret == 2)
        e.moveWord(forward: true, extending: true)
        #expect(e.selection == 2..<5)
        e.moveCaret(by: -1)  // colapsa para a borda esquerda
        #expect(e.caret == 2 && !e.hasSelection)
        e.moveToEnd()
        e.moveWord(forward: false)
        #expect(e.caret == 7)
        e.moveCaret(by: -100)
        #expect(e.caret == 0)
    }

    @Test func graphemesAreAtomic() {
        var e = CajuTextEditorModel(text: "e\u{301}👨‍👩‍👧")  // é combinado + família
        #expect(e.length == 2)
        #expect(e.scalarOffset(forCharacterOffset: 1) == 2)
        #expect(e.characterOffset(forScalarOffset: 3) == 1)
        e.deleteBackward()
        #expect(e.text == "e\u{301}")
    }

    @Test func maxLengthAndComposition() {
        var e = CajuTextEditorModel(text: "abc", maxLength: 5)
        e.insert("defg")
        #expect(e.text == "abcde")
        e = CajuTextEditorModel()
        e.setMarkedText("k")
        e.setMarkedText("ka")
        #expect(e.text == "ka" && e.markedRange == 0..<2)
        e.setMarkedText("か")
        #expect(e.text == "か")
        e.commitMarkedText()
        #expect(e.markedRange == nil)
        e.setSelection(anchor: -5, caret: 99)
        #expect(e.selection == 0..<1)
    }
}
