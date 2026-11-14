/// Fonte bitmap 5x7 mínima da demo (só as letras de "GIRAR CUBO" e dígitos). O texto de verdade
/// (shaping, MSDF) é da trilha CajuText (P-5); aqui basta o suficiente para o botão do M2.
enum CajuDemoFont {
    /// Cada glifo: 7 linhas de 5 bits (bit 4 = coluna da esquerda).
    static let glyphs: [Character: [UInt8]] = [
        "G": [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110],
        "I": [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        "R": [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
        "A": [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        "C": [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
        "U": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        "B": [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
        "O": [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        "P": [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
        "E": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
        "S": [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
        "T": [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
        "N": [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
        "D": [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
        "0": [0b01110, 0b10011, 0b10101, 0b10101, 0b10101, 0b11001, 0b01110],
        "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        "2": [0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111],
        "3": [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110],
        "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
        "5": [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
        "6": [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
        "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
        "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
        "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
    ]

    static let cellSize = 8
    static let columns = 32
    static let atlasWidth = columns * cellSize
    static let atlasHeight = 16
    /// Célula totalmente branca (retângulos sólidos).
    static let solidCell = columns - 1

    /// Ordem dos glifos no atlas (índice da célula = posição + 0).
    static let order: [Character] = Array(glyphs.keys.sorted())

    /// Atlas R8: cobertura (0 ou 255) por texel.
    static func makeAtlas() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        for (i, ch) in order.enumerated() {
            guard let rows = glyphs[ch] else { continue }
            let cx = (i % columns) * cellSize
            let cy = (i / columns) * cellSize
            for (y, row) in rows.enumerated() {
                for x in 0..<5 where (row >> (4 - x)) & 1 == 1 {
                    pixels[(cy + y) * atlasWidth + cx + x] = 255
                }
            }
        }
        let sx = solidCell * cellSize
        for y in 0..<cellSize { for x in 0..<cellSize { pixels[y * atlasWidth + sx + x] = 255 } }
        return pixels
    }

    /// Retângulo UV (u0, v0, u1, v1) do glifo, ou `nil` se não existe.
    static func uv(of ch: Character) -> (Float, Float, Float, Float)? {
        guard let i = order.firstIndex(of: ch) else { return nil }
        let cx = Float((i % columns) * cellSize)
        let cy = Float((i / columns) * cellSize)
        return (cx / Float(atlasWidth), cy / Float(atlasHeight), (cx + 5) / Float(atlasWidth), (cy + 7) / Float(atlasHeight))
    }

    /// UV de um ponto no centro da célula branca.
    static var solidUV: (Float, Float) {
        (Float(solidCell * cellSize + 4) / Float(atlasWidth), 4 / Float(atlasHeight))
    }
}
