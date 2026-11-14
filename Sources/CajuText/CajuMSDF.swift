import CajuMath

/// Gerador de campo de distância multicanal (MSDF) em bitmap de CPU.
///
/// Cada canal (R, G, B) guarda a distância assinada ao contorno considerando só um subconjunto de
/// arestas; a mediana dos três reconstrói a forma com cantos nítidos. Valor `0.5` (128) é o contorno;
/// acima é dentro. Use `median(_:_:_:)` no shader (ou aqui, nos testes) para decodificar.
///
/// O gerador roda no carregamento/atlas, não por quadro; aloca o bitmap de saída.
public enum CajuMSDF {
    /// Bitmap RGBA8 (linha 0 = topo) de `width × height`.
    ///
    /// - Parameters:
    ///   - outline: contorno em unidades da fonte (y para cima).
    ///   - scale: pixels por unidade da fonte.
    ///   - origin: coordenada de forma que corresponde ao canto inferior esquerdo do bitmap.
    ///   - pixelRange: distância (em pixels) mapeada para o intervalo `[0, 1]` do canal; ≥ 1.
    public static func render(
        outline: CajuOutline, width: Int, height: Int, scale: Float, origin: CajuVec2, pixelRange: Float
    ) -> [UInt8] {
        let w = max(0, min(width, 4096))
        let h = max(0, min(height, 4096))
        var out = [UInt8](repeating: 255, count: w * h * 4)
        guard w > 0, h > 0, scale > 0, pixelRange >= 1 else { return out }
        let pieces = makePieces(outline, tolerance: 0.02 / scale)
        let flip: Float = outline.signedArea >= 0 ? 1 : -1
        let invScale = 1 / scale
        for py in 0..<h {
            let y = origin.y + (Float(h - py) - 0.5) * invScale
            for px in 0..<w {
                let x = origin.x + (Float(px) + 0.5) * invScale
                let d = channelDistances(at: CajuVec2(x, y), pieces: pieces)
                let i = (py * w + px) * 4
                for c in 0..<3 {
                    let v = 0.5 + flip * d[c] * scale / (2 * pixelRange)
                    out[i + c] = UInt8(max(0, min(255, (v * 255).rounded())))
                }
            }
        }
        return out
    }

    /// Mediana de três valores; reconstrói a distância assinada a partir de um texel MSDF.
    @inlinable public static func median(_ a: Float, _ b: Float, _ c: Float) -> Float {
        max(min(a, b), min(max(a, b), c))
    }

    // MARK: Cores de aresta (R = 1, G = 2, B = 4)

    static let cyan: UInt8 = 6  // G + B
    static let magenta: UInt8 = 5  // R + B
    static let yellow: UInt8 = 3  // R + G
    static let white: UInt8 = 7

    struct Piece {
        var a: CajuVec2
        var b: CajuVec2
        var mask: UInt8
        var isEdgeStart: Bool
        var isEdgeEnd: Bool
    }

    private static func cross(_ u: CajuVec2, _ v: CajuVec2) -> Float { u.x * v.y - u.y * v.x }

    private static func direction(_ s: CajuOutlineSegment, atStart: Bool) -> CajuVec2 {
        switch s {
        case .line(let a, let b): return b - a
        case .quad(let a, let c, let b):
            if atStart { return c != a ? c - a : b - a }
            return b != c ? b - c : b - a
        }
    }

    private static func isCorner(_ u: CajuVec2, _ v: CajuVec2) -> Bool {
        let lu = u.length
        let lv = v.length
        guard lu > 0, lv > 0 else { return false }
        let d = u.dot(v) / (lu * lv)
        let c = cross(u, v) / (lu * lv)
        return d <= 0 || abs(c) > 0.14112  // sin(3.0 rad), como no msdfgen
    }

    private static func split(_ s: CajuOutlineSegment, at t: Float) -> (
        CajuOutlineSegment, CajuOutlineSegment
    ) {
        switch s {
        case .line(let a, let b):
            let m = a + (b - a) * t
            return (.line(a, m), .line(m, b))
        case .quad(let a, let c, let b):
            let ac = a + (c - a) * t
            let cb = c + (b - c) * t
            let m = ac + (cb - ac) * t
            return (.quad(a, ac, m), .quad(m, cb, b))
        }
    }

    private static func splitInThirds(_ s: CajuOutlineSegment) -> [CajuOutlineSegment] {
        let (first, rest) = split(s, at: 1.0 / 3.0)
        let (second, third) = split(rest, at: 0.5)
        return [first, second, third]
    }

    /// Atribui cores às arestas e achata curvas em retas curtas (mantendo a máscara e as pontas).
    static func makePieces(_ outline: CajuOutline, tolerance: Float) -> [Piece] {
        var pieces: [Piece] = []
        for raw in outline.contours where !raw.isEmpty {
            var edges = raw
            let n = edges.count
            var corners: [Int] = []  // índice da aresta que começa num canto
            for i in 0..<n {
                let prev = edges[(i + n - 1) % n]
                if isCorner(direction(prev, atStart: false), direction(edges[i], atStart: true)) {
                    corners.append(i)
                }
            }
            var colors = [UInt8](repeating: white, count: n)
            if corners.count == 1 {
                edges = edges.flatMap { splitInThirds($0) }
                // Reposiciona o canto: cada aresta virou 3, o canto está na aresta 3*corner.
                let start = corners[0] * 3
                let m = edges.count
                colors = [UInt8](repeating: white, count: m)
                for k in 0..<m {
                    let rel = (k + m - start) % m
                    let slot = (rel * 3) / m
                    colors[k] = [magenta, white, cyan][slot]
                }
            } else if corners.count >= 2 {
                let cycle = [cyan, magenta, yellow]
                var segmentOfEdge = [Int](repeating: 0, count: n)
                var seg = -1
                let startEdge = corners[0]
                var cornerSet = Set(corners)
                cornerSet.remove(startEdge)
                for k in 0..<n {
                    let i = (startEdge + k) % n
                    if k == 0 || cornerSet.contains(i) { seg += 1 }
                    segmentOfEdge[i] = seg
                }
                let last = seg
                var segColors = (0...last).map { cycle[$0 % 3] }
                if last >= 2, segColors[last] == segColors[0] {
                    let prev = segColors[last - 1]
                    segColors[last] = cycle.first { $0 != prev && $0 != segColors[0] } ?? cyan
                }
                for i in 0..<n { colors[i] = segColors[segmentOfEdge[i]] }
            }
            for (i, e) in edges.enumerated() {
                switch e {
                case .line(let a, let b):
                    if a != b {
                        pieces.append(Piece(a: a, b: b, mask: colors[i], isEdgeStart: true, isEdgeEnd: true))
                    }
                case .quad(let a, let c, let b):
                    let dev = (a - c * 2 + b).length / 4
                    let steps = max(1, min(16, Int((dev / max(tolerance, 1e-6)).squareRoot().rounded(.up))))
                    var prev = a
                    for s in 1...steps {
                        let t = Float(s) / Float(steps)
                        let u = 1 - t
                        let p = a * (u * u) + c * (2 * u * t) + b * (t * t)
                        let q = s == steps ? b : p
                        if q != prev {
                            pieces.append(
                                Piece(
                                    a: prev, b: q, mask: colors[i], isEdgeStart: s == 1, isEdgeEnd: s == steps
                                ))
                        }
                        prev = q
                    }
                }
            }
        }
        return pieces
    }

    /// Distância assinada (positiva à esquerda do sentido do contorno) por canal, com pseudo-distância.
    static func channelDistances(at p: CajuVec2, pieces: [Piece]) -> [Float] {
        var best = [Float](repeating: .infinity, count: 3)
        var bestOrtho = [Float](repeating: .infinity, count: 3)
        var bestSigned = [Float](repeating: -.infinity, count: 3)
        var bestPiece = [Int](repeating: -1, count: 3)
        var bestT = [Float](repeating: 0, count: 3)
        for (idx, pc) in pieces.enumerated() {
            let ab = pc.b - pc.a
            let len2 = ab.lengthSquared
            let ap = p - pc.a
            let t = ap.dot(ab) / len2
            let tc = max(0, min(1, t))
            let q = pc.a + ab * tc
            let diff = p - q
            let dist = diff.length
            let dir = ab * (1 / len2.squareRoot())
            let s: Float = cross(dir, diff) >= 0 ? 1 : -1
            let ortho: Float = dist > 0 ? abs(dir.dot(diff)) / dist : 0
            for c in 0..<3 where pc.mask & (1 << UInt8(c)) != 0 {
                let better = dist < best[c] - 1e-7 || (abs(dist - best[c]) <= 1e-7 && ortho < bestOrtho[c])
                if better {
                    best[c] = dist
                    bestOrtho[c] = ortho
                    bestSigned[c] = s * dist
                    bestPiece[c] = idx
                    bestT[c] = t
                }
            }
        }
        var result = [Float](repeating: -1e6, count: 3)
        for c in 0..<3 where bestPiece[c] >= 0 {
            let pc = pieces[bestPiece[c]]
            var d = bestSigned[c]
            let t = bestT[c]
            if (t < 0 && pc.isEdgeStart) || (t > 1 && pc.isEdgeEnd) {
                let ab = pc.b - pc.a
                let dir = ab * (1 / ab.length)
                let pd = cross(dir, p - (t < 0 ? pc.a : pc.b))
                if abs(pd) < abs(d) { d = pd }
            }
            result[c] = d
        }
        return result
    }
}
