/// Curvas de *easing* para animações, com entrada `t` limitada a `[0, 1]` e extremidades exatas.
///
/// ```swift
/// let y = CajuEasing.cubicInOut(0.5)
/// let b = CajuEasing.cubicBezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1, t: 0.5)
/// ```
public enum CajuEasing: Sendable, Equatable, Hashable, CaseIterable {
    case linear
    case quadIn
    case quadOut
    case quadInOut
    case cubicIn
    case cubicOut
    case cubicInOut
    case quartIn
    case quartOut
    case quartInOut
    case quintIn
    case quintOut
    case quintInOut
    case sineIn
    case sineOut
    case sineInOut
    case expoIn
    case expoOut
    case expoInOut
    case circIn
    case circOut
    case circInOut
    case backIn
    case backOut
    case backInOut
    case elasticIn
    case elasticOut
    case elasticInOut
    case bounceIn
    case bounceOut
    case bounceInOut

    /// Avalia a curva em `t` (limitado a `[0, 1]`), garantindo `f(0) == 0` e `f(1) == 1` exatos.
    @inlinable public func callAsFunction(_ t: Float) -> Float {
        if !(t > 0) { return 0 }
        if t >= 1 { return 1 }

        switch self {
        case .linear:
            return t

        case .quadIn:
            return t * t
        case .quadOut:
            let u = 1 - t
            return 1 - u * u
        case .quadInOut:
            if t < 0.5 { return 2 * t * t }
            let u = -2 * t + 2
            return 1 - u * u * 0.5

        case .cubicIn:
            return t * t * t
        case .cubicOut:
            let u = 1 - t
            return 1 - u * u * u
        case .cubicInOut:
            if t < 0.5 { return 4 * t * t * t }
            let u = -2 * t + 2
            return 1 - u * u * u * 0.5

        case .quartIn:
            let t2 = t * t
            return t2 * t2
        case .quartOut:
            let u = 1 - t
            let u2 = u * u
            return 1 - u2 * u2
        case .quartInOut:
            if t < 0.5 {
                let t2 = t * t
                return 8 * t2 * t2
            }
            let u = -2 * t + 2
            let u2 = u * u
            return 1 - u2 * u2 * 0.5

        case .quintIn:
            let t2 = t * t
            return t2 * t2 * t
        case .quintOut:
            let u = 1 - t
            let u2 = u * u
            return 1 - u2 * u2 * u
        case .quintInOut:
            if t < 0.5 {
                let t2 = t * t
                return 16 * t2 * t2 * t
            }
            let u = -2 * t + 2
            let u2 = u * u
            return 1 - u2 * u2 * u * 0.5

        case .sineIn:
            return 1 - CajuLibm.cosf((t * .pi) * 0.5)
        case .sineOut:
            return CajuLibm.sinf((t * .pi) * 0.5)
        case .sineInOut:
            return -(CajuLibm.cosf(.pi * t) - 1) * 0.5

        case .expoIn:
            return CajuLibm.powf(2, 10 * t - 10)
        case .expoOut:
            return 1 - CajuLibm.powf(2, -10 * t)
        case .expoInOut:
            if t < 0.5 {
                return CajuLibm.powf(2, 20 * t - 10) * 0.5
            }
            return (2 - CajuLibm.powf(2, -20 * t + 10)) * 0.5

        case .circIn:
            return 1 - (1 - t * t).squareRoot()
        case .circOut:
            let u = t - 1
            return (1 - u * u).squareRoot()
        case .circInOut:
            if t < 0.5 {
                let u = 2 * t
                return (1 - (1 - u * u).squareRoot()) * 0.5
            }
            let u = -2 * t + 2
            return ((1 - u * u).squareRoot() + 1) * 0.5

        case .backIn:
            let c1: Float = 1.70158
            let c3 = c1 + 1
            return c3 * t * t * t - c1 * t * t
        case .backOut:
            let c1: Float = 1.70158
            let c3 = c1 + 1
            let u = t - 1
            return 1 + c3 * u * u * u + c1 * u * u
        case .backInOut:
            let c1: Float = 1.70158
            let c2 = c1 * 1.525
            if t < 0.5 {
                let u = 2 * t
                return (u * u * ((c2 + 1) * u - c2)) * 0.5
            }
            let u = 2 * t - 2
            return (u * u * ((c2 + 1) * u + c2) + 2) * 0.5

        case .elasticIn:
            let c4 = (2 * Float.pi) / 3
            return -CajuLibm.powf(2, 10 * t - 10) * CajuLibm.sinf((t * 10 - 10.75) * c4)
        case .elasticOut:
            let c4 = (2 * Float.pi) / 3
            return CajuLibm.powf(2, -10 * t) * CajuLibm.sinf((t * 10 - 0.75) * c4) + 1
        case .elasticInOut:
            let c5 = (2 * Float.pi) / 4.5
            if t < 0.5 {
                return -(CajuLibm.powf(2, 20 * t - 10) * CajuLibm.sinf((20 * t - 11.125) * c5)) * 0.5
            }
            return (CajuLibm.powf(2, -20 * t + 10) * CajuLibm.sinf((20 * t - 11.125) * c5)) * 0.5 + 1

        case .bounceIn:
            return 1 - Self.evalBounceOut(1 - t)
        case .bounceOut:
            return Self.evalBounceOut(t)
        case .bounceInOut:
            if t < 0.5 {
                return (1 - Self.evalBounceOut(1 - 2 * t)) * 0.5
            }
            return (1 + Self.evalBounceOut(2 * t - 1)) * 0.5
        }
    }

    @inlinable static func evalBounceOut(_ t: Float) -> Float {
        let n1: Float = 7.5625
        let d1: Float = 2.75
        if t < 1 / d1 {
            return n1 * t * t
        } else if t < 2 / d1 {
            let u = t - 1.5 / d1
            return n1 * u * u + 0.75
        } else if t < 2.5 / d1 {
            let u = t - 2.25 / d1
            return n1 * u * u + 0.9375
        } else {
            let u = t - 2.625 / d1
            return n1 * u * u + 0.984375
        }
    }

    /// Avalia uma curva de Bézier cúbica com pontos `(0, 0)`, `(x1, y1)`, `(x2, y2)` e `(1, 1)`.
    ///
    /// Resolve `x(s) = t` usando Newton–Raphson com fallback por bisseção em `[0, 1]`, sem alocação.
    @inlinable public static func cubicBezier(
        x1: Float,
        y1: Float,
        x2: Float,
        y2: Float,
        t: Float
    ) -> Float {
        if !(t > 0) { return 0 }
        if t >= 1 { return 1 }
        guard x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite else { return t }

        let cx1 = CajuScalar.saturate(x1)
        let cx2 = CajuScalar.saturate(x2)
        if cx1 == y1 && cx2 == y2 { return t }

        let cx = 3 * cx1
        let bx = 3 * (cx2 - cx1) - cx
        let ax = 1 - cx - bx

        let cy = 3 * y1
        let by = 3 * (y2 - y1) - cy
        let ay = 1 - cy - by

        var lo: Float = 0
        var hi: Float = 1
        var s = t
        for _ in 0..<24 {
            let xErr = ((ax * s + bx) * s + cx) * s - t
            if abs(xErr) <= 1e-6 {
                return ((ay * s + by) * s + cy) * s
            }
            if xErr < 0 {
                lo = s
            } else {
                hi = s
            }
            let dx = (3 * ax * s + 2 * bx) * s + cx
            let next = abs(dx) > 1e-6 ? (s - xErr / dx) : 0.5 * (lo + hi)
            if next > lo && next < hi {
                s = next
            } else {
                s = 0.5 * (lo + hi)
            }
        }
        return ((ay * s + by) * s + cy) * s
    }
}
