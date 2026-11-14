import CajuMath

/// Segmento de contorno: reta ou curva quadrática (TrueType).
public enum CajuOutlineSegment: Sendable, Equatable {
    case line(CajuVec2, CajuVec2)
    case quad(CajuVec2, CajuVec2, CajuVec2)

    @inlinable public var start: CajuVec2 {
        switch self {
        case .line(let a, _): a
        case .quad(let a, _, _): a
        }
    }

    @inlinable public var end: CajuVec2 {
        switch self {
        case .line(_, let b): b
        case .quad(_, _, let c): c
        }
    }
}

/// Contornos fechados de um glifo, em unidades da fonte (eixo y para cima).
///
/// Convenção TrueType: contornos externos em sentido horário, buracos em anti-horário.
public struct CajuOutline: Sendable, Equatable {
    public var contours: [[CajuOutlineSegment]]

    public init(contours: [[CajuOutlineSegment]] = []) { self.contours = contours }

    public var isEmpty: Bool { contours.allSatisfy { $0.isEmpty } }

    /// Caixa envolvente (inclui pontos de controle, logo é conservadora). `nil` se vazio.
    public var bounds: (min: CajuVec2, max: CajuVec2)? {
        var lo = CajuVec2(.infinity, .infinity)
        var hi = CajuVec2(-.infinity, -.infinity)
        var any = false
        for contour in contours {
            for seg in contour {
                let pts: [CajuVec2]
                switch seg {
                case .line(let a, let b): pts = [a, b]
                case .quad(let a, let c, let b): pts = [a, c, b]
                }
                for p in pts {
                    lo = CajuVec2(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y))
                    hi = CajuVec2(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y))
                    any = true
                }
            }
        }
        return any ? (lo, hi) : nil
    }

    /// Área assinada (positiva = anti-horário). Curvas contribuem pelo polígono de controle.
    var signedArea: Float {
        var area: Float = 0
        for contour in contours {
            for seg in contour {
                switch seg {
                case .line(let a, let b):
                    area += a.x * b.y - b.x * a.y
                case .quad(let a, let c, let b):
                    area += a.x * c.y - c.x * a.y
                    area += c.x * b.y - b.x * c.y
                }
            }
        }
        return area / 2
    }
}
