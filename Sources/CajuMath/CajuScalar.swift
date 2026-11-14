/// Operações escalares utilitárias para `Float` (interpolação, limites, ângulos e comparação).
///
/// ```swift
/// let t = CajuScalar.smoothstep(edge0: 0, edge1: 10, x: 5)  // 0.5
/// let rad = CajuScalar.radians(fromDegrees: 180)            // .pi
/// ```
public enum CajuScalar: Sendable {
    /// Interpola linearmente entre `a` e `b` pelo fator `t` (sem limitar `t`).
    @inlinable public static func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }

    /// Limita `value` ao intervalo fechado `[minValue, maxValue]`.
    ///
    /// Se `minValue > maxValue`, os limites são invertidos automaticamente para evitar falha.
    @inlinable public static func clamp(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
        let low = Swift.min(minValue, maxValue)
        let high = Swift.max(minValue, maxValue)
        return Swift.min(Swift.max(value, low), high)
    }

    /// Limita `value` ao intervalo `[0, 1]`.
    @inlinable public static func saturate(_ value: Float) -> Float {
        Swift.min(Swift.max(value, 0), 1)
    }

    /// Interpolação de Hermite cúbica suave entre `0` e `1` para `x` no intervalo `[edge0, edge1]`.
    @inlinable public static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let span = edge1 - edge0
        guard span != 0, span.isFinite else {
            return (x.isFinite && edge0.isFinite && x >= edge0) ? 1 : 0
        }
        let t = saturate((x - edge0) / span)
        return t * t * (3 - 2 * t)
    }

    /// Retorna o fator `t` tal que `lerp(a, b, t: t) == value`, ou `nil` se `a == b` ou não finito.
    @inlinable public static func inverseLerp(_ a: Float, _ b: Float, value: Float) -> Float? {
        let span = b - a
        guard span != 0, span.isFinite, a.isFinite, b.isFinite, value.isFinite else { return nil }
        return (value - a) / span
    }

    /// Remapeia `value` do intervalo `[fromMin, fromMax]` para `[toMin, toMax]`, ou `nil` se inválido.
    @inlinable public static func remap(
        _ value: Float,
        fromMin: Float,
        fromMax: Float,
        toMin: Float,
        toMax: Float
    ) -> Float? {
        guard toMin.isFinite, toMax.isFinite,
            let t = inverseLerp(fromMin, fromMax, value: value)
        else { return nil }
        return lerp(toMin, toMax, t: t)
    }

    /// Converte graus para radianos.
    @inlinable public static func radians(fromDegrees degrees: Float) -> Float {
        degrees * (.pi / 180)
    }

    /// Converte radianos para graus.
    @inlinable public static func degrees(fromRadians radians: Float) -> Float {
        radians * (180 / .pi)
    }

    /// Compara `a` e `b` com tolerância relativa `tolerance * max(1, |a|, |b|)`.
    @inlinable public static func approximatelyEqual(
        _ a: Float,
        _ b: Float,
        tolerance: Float = 1e-5
    ) -> Bool {
        guard a.isFinite, b.isFinite, tolerance.isFinite, tolerance >= 0 else { return false }
        return abs(a - b) <= tolerance * max(1, max(abs(a), abs(b)))
    }
}
