import CajuMath

/// Raio paramétrico `origin + t * direction` com intervalo válido `[tMin, tMax]`.
///
/// Todos os campos são validados na construção: valores `NaN`/infinito, direção nula e
/// intervalos inválidos (`tMin < 0` ou `tMin > tMax`) são rejeitados com `CajuSpatialError`.
///
/// ```swift
/// let ray = try CajuRay(origin: SIMD3(0, 0, -5), direction: SIMD3(0, 0, 1))
/// let t = ray.intersect(try CajuAABB(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)))
/// ```
public struct CajuRay: Sendable, Equatable, Hashable {
    /// Origem do raio.
    public let origin: SIMD3<Float>

    /// Direção finita e não nula do raio (não normalizada automaticamente; `t` está em unidades de `direction`).
    public let direction: SIMD3<Float>

    /// Inverso por componente de `direction` (`1 / direction`, podendo ser `±infinity` quando o componente é `0`).
    public let inverseDirection: SIMD3<Float>

    /// Limite inferior do parâmetro `t` (`>= 0`).
    public let tMin: Float

    /// Limite superior do parâmetro `t` (`>= tMin`).
    public let tMax: Float

    /// Cria um raio validado.
    ///
    /// - Throws:
    ///   - `CajuSpatialError.nonFiniteRay` se `origin`, `direction`, `tMin` ou `tMax` não forem finitos.
    ///   - `CajuSpatialError.invalidRayDirection` se `direction` for `(0, 0, 0)`.
    ///   - `CajuSpatialError.invalidRayRange` se `tMin < 0` ou `tMin > tMax`.
    @inlinable
    public init(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        tMin: Float = 0,
        tMax: Float = .greatestFiniteMagnitude
    ) throws(CajuSpatialError) {
        guard allFinite(origin), allFinite(direction), tMin.isFinite, tMax.isFinite else {
            throw .nonFiniteRay
        }
        guard direction.x != 0 || direction.y != 0 || direction.z != 0 else {
            throw .invalidRayDirection
        }
        guard tMin >= 0, tMin <= tMax else {
            throw .invalidRayRange
        }
        self.origin = origin
        self.direction = direction
        self.inverseDirection = SIMD3<Float>(1.0 / direction.x, 1.0 / direction.y, 1.0 / direction.z)
        self.tMin = tMin
        self.tMax = tMax
    }

    /// Cria um raio validado a partir de `CajuVec3`.
    ///
    /// - Throws: Os mesmos erros de `init(origin:direction:tMin:tMax:)` com `SIMD3<Float>`.
    @inlinable
    public init(
        origin: CajuVec3,
        direction: CajuVec3,
        tMin: Float = 0,
        tMax: Float = .greatestFiniteMagnitude
    ) throws(CajuSpatialError) {
        try self.init(origin: origin.storage, direction: direction.storage, tMin: tMin, tMax: tMax)
    }

    /// Avalia o ponto ao longo do raio no parâmetro `t` (`origin + t * direction`).
    @inlinable
    public func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }

    /// Testa interseção com `aabb` pelo método *slab* robusto contra raios paralelos (`0 * inf = NaN`),
    /// caixas de volume zero e origem interna à caixa.
    ///
    /// - Parameter tMaxLimit: Teto opcional para `t` (é limitado por `self.tMax`).
    /// - Returns: O `t` de entrada em `[tMin, min(tMax, tMaxLimit)]`, ou `nil` sem interseção.
    @inlinable
    public func intersect(_ aabb: CajuAABB, tMaxLimit: Float? = nil) -> Float? {
        let limit = tMaxLimit.map { Swift.min($0, tMax) } ?? tMax
        if tMin > limit { return nil }
        return intersectSlabs(aabb, tEnterInit: tMin, tExitInit: limit, exitSlack: 0)
    }

    /// Núcleo *slab* compartilhado; `exitSlack` permite folga de alguns ULPs na travessia interna da BVH de triângulos.
    @inlinable
    internal func intersectSlabs(
        _ aabb: CajuAABB,
        tEnterInit: Float,
        tExitInit: Float,
        exitSlack: Float
    ) -> Float? {
        var tEnter = tEnterInit
        var tExit = tExitInit
        let slack = exitSlack

        // Eixo X: quando inverseDirection é ±inf (componente 0 ou subnormal), evita 0 * inf = NaN
        // verificando diretamente se a origem está contida no intervalo do slab.
        if inverseDirection.x.isFinite {
            let a = (aabb.min.x - origin.x) * inverseDirection.x
            let b = (aabb.max.x - origin.x) * inverseDirection.x
            let near = a < b ? a : b
            let far = a < b ? b : a
            if near > tEnter { tEnter = near }
            if far < tExit { tExit = far }
            if tEnter > tExit + Swift.abs(tExit) * slack + slack { return nil }
        } else if origin.x < aabb.min.x || origin.x > aabb.max.x {
            return nil
        }

        if inverseDirection.y.isFinite {
            let a = (aabb.min.y - origin.y) * inverseDirection.y
            let b = (aabb.max.y - origin.y) * inverseDirection.y
            let near = a < b ? a : b
            let far = a < b ? b : a
            if near > tEnter { tEnter = near }
            if far < tExit { tExit = far }
            if tEnter > tExit + Swift.abs(tExit) * slack + slack { return nil }
        } else if origin.y < aabb.min.y || origin.y > aabb.max.y {
            return nil
        }

        if inverseDirection.z.isFinite {
            let a = (aabb.min.z - origin.z) * inverseDirection.z
            let b = (aabb.max.z - origin.z) * inverseDirection.z
            let near = a < b ? a : b
            let far = a < b ? b : a
            if near > tEnter { tEnter = near }
            if far < tExit { tExit = far }
            if tEnter > tExit + Swift.abs(tExit) * slack + slack { return nil }
        } else if origin.z < aabb.min.z || origin.z > aabb.max.z {
            return nil
        }

        return tEnter
    }
}
