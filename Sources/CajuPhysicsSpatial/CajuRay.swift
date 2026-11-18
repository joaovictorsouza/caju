import CajuMath

/// Raio paramétrico `P(t) = origin + direction * t` com `t` em `[tMin, tMax]`.
///
/// Todos os campos são validados como finitos, com direção não nula e `0 <= tMin <= tMax`.
/// A direção não precisa ser unitária; `t` é medido em múltiplos de `direction`.
///
/// ```swift
/// let ray = try CajuRay(origin: SIMD3(0, 0, -5), direction: SIMD3(0, 0, 1))
/// let p = ray.point(at: 5)
/// ```
public struct CajuRay: Sendable, Equatable {
    /// Origem do raio.
    public let origin: SIMD3<Float>
    /// Vetor de direção finito e não nulo.
    public let direction: SIMD3<Float>
    /// Inverso por componente (`1 / direction`), pré-calculado para testes slab.
    public let inverseDirection: SIMD3<Float>
    /// Parâmetro mínimo permitido (`>= 0`).
    public let tMin: Float
    /// Parâmetro máximo permitido (`>= tMin`).
    public let tMax: Float

    /// Cria um raio validando finitude, direção não nula e intervalo `[tMin, tMax]`.
    public init(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        tMin: Float = 0,
        tMax: Float = .greatestFiniteMagnitude
    ) throws(CajuSpatialError) {
        guard
            CajuAABB.isFinite(origin),
            CajuAABB.isFinite(direction),
            tMin.isFinite,
            tMax.isFinite
        else {
            throw .nonFiniteRay
        }
        guard direction.x != 0 || direction.y != 0 || direction.z != 0 else {
            throw .zeroDirectionRay
        }
        guard tMin >= 0, tMin <= tMax else {
            throw .invalidRayRange
        }
        self.origin = origin
        self.direction = direction
        self.inverseDirection = SIMD3(1 / direction.x, 1 / direction.y, 1 / direction.z)
        self.tMin = tMin
        self.tMax = tMax
    }

    /// Cria um raio a partir de vetores `CajuVec3`.
    public init(
        origin: CajuVec3,
        direction: CajuVec3,
        tMin: Float = 0,
        tMax: Float = .greatestFiniteMagnitude
    ) throws(CajuSpatialError) {
        try self.init(origin: origin.storage, direction: direction.storage, tMin: tMin, tMax: tMax)
    }

    @usableFromInline
    internal init(
        uncheckedOrigin origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        tMin: Float,
        tMax: Float
    ) {
        self.origin = origin
        self.direction = direction
        self.inverseDirection = SIMD3(1 / direction.x, 1 / direction.y, 1 / direction.z)
        self.tMin = tMin
        self.tMax = tMax
    }

    /// Ponto ao longo do raio em `t` (`origin + direction * t`).
    @inlinable
    public func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }
}
