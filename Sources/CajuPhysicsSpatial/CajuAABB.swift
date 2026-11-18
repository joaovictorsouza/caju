import CajuMath

/// Caixa delimitadora alinhada aos eixos (AABB) com limites validados.
///
/// AABBs de volume zero (ponto, segmento ou plano) são válidas desde que `min <= max`
/// em todos os eixos e todas as coordenadas sejam finitas.
///
/// ```swift
/// let box = try CajuAABB(min: SIMD3(0, 0, 0), max: SIMD3(1, 2, 3))
/// let area = box.surfaceArea
/// ```
public struct CajuAABB: Sendable, Equatable, Hashable {
    /// Canto mínimo da caixa (`min <= max` em todos os eixos).
    public let min: SIMD3<Float>
    /// Canto máximo da caixa (`min <= max` em todos os eixos).
    public let max: SIMD3<Float>

    @usableFromInline
    internal init(uncheckedMin min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    /// Cria uma AABB validando finitude e ordenação (`min <= max`).
    public init(min: SIMD3<Float>, max: SIMD3<Float>) throws(CajuSpatialError) {
        guard Self.isFinite(min), Self.isFinite(max) else {
            throw .nonFiniteBounds
        }
        guard min.x <= max.x, min.y <= max.y, min.z <= max.z else {
            throw .invalidBounds
        }
        self.min = min
        self.max = max
    }

    /// Cria uma AABB a partir de vetores `CajuVec3`, validando finitude e ordenação.
    public init(min: CajuVec3, max: CajuVec3) throws(CajuSpatialError) {
        try self.init(min: min.storage, max: max.storage)
    }

    /// Centro geométrico da caixa.
    @inlinable
    public var center: SIMD3<Float> {
        min * 0.5 + max * 0.5
    }

    /// Área superficial total das seis faces da caixa.
    @inlinable
    public var surfaceArea: Float {
        let d = max - min
        return 2 * (d.x * d.y + d.y * d.z + d.z * d.x)
    }

    /// União mínima que contém `self` e `other`.
    @inlinable
    public func union(_ other: CajuAABB) -> CajuAABB {
        CajuAABB(
            uncheckedMin: SIMD3(
                Swift.min(min.x, other.min.x),
                Swift.min(min.y, other.min.y),
                Swift.min(min.z, other.min.z)
            ),
            max: SIMD3(
                Swift.max(max.x, other.max.x),
                Swift.max(max.y, other.max.y),
                Swift.max(max.z, other.max.z)
            )
        )
    }

    /// Retorna `true` se `self` e `other` se sobrepõem (inclusive tocando faces/arestas).
    @inlinable
    public func overlaps(_ other: CajuAABB) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x
            && min.y <= other.max.y && max.y >= other.min.y
            && min.z <= other.max.z && max.z >= other.min.z
    }

    /// Retorna `true` se `other` estiver inteiramente contida em `self`.
    @inlinable
    public func contains(_ other: CajuAABB) -> Bool {
        min.x <= other.min.x && max.x >= other.max.x
            && min.y <= other.min.y && max.y >= other.max.y
            && min.z <= other.min.z && max.z >= other.max.z
    }

    /// Retorna `true` se o ponto estiver contido em `self`.
    @inlinable
    public func contains(_ point: SIMD3<Float>) -> Bool {
        point.x >= min.x && point.x <= max.x
            && point.y >= min.y && point.y <= max.y
            && point.z >= min.z && point.z <= max.z
    }

    /// Retorna a caixa expandida em `margin` para todos os lados.
    ///
    /// Se `margin` for negativo além da metade da extensão, os limites são comprimidos no centro
    /// para manter `min <= max`. Se `margin` não for finito, retorna `self`.
    @inlinable
    public func enlarged(margin: Float) -> CajuAABB {
        guard margin.isFinite else { return self }
        let m = SIMD3<Float>(repeating: margin)
        let nMin = min - m
        let nMax = max + m
        if !Self.isFinite(nMin) || !Self.isFinite(nMax) {
            return self
        }
        if margin < 0 {
            let c = center
            return CajuAABB(
                uncheckedMin: SIMD3(
                    Swift.min(nMin.x, c.x),
                    Swift.min(nMin.y, c.y),
                    Swift.min(nMin.z, c.z)
                ),
                max: SIMD3(
                    Swift.max(nMax.x, c.x),
                    Swift.max(nMax.y, c.y),
                    Swift.max(nMax.z, c.z)
                )
            )
        }
        return CajuAABB(uncheckedMin: nMin, max: nMax)
    }

    /// Testa interseção entre `ray` e esta AABB pelo método slab robusto.
    ///
    /// Trata corretamente raios paralelos aos planos (`0 * inf = NaN`), origem dentro da caixa
    /// (`tEnter = ray.tMin`, tipicamente `0`) e caixas de volume zero.
    @inlinable
    public func intersect(ray: CajuRay) -> (tEnter: Float, tExit: Float)? {
        intersectRange(ray: ray, maxT: ray.tMax)
    }

    /// Testa sobreposição exata entre a AABB e uma esfera.
    @inlinable
    public func intersects(sphereCenter center: SIMD3<Float>, radius: Float) -> Bool {
        let clamped = SIMD3(
            Swift.min(Swift.max(center.x, min.x), max.x),
            Swift.min(Swift.max(center.y, min.y), max.y),
            Swift.min(Swift.max(center.z, min.z), max.z)
        )
        let delta = center - clamped
        let distSq = (delta * delta).sum()
        let radiusSq = radius * radius
        if distSq.isFinite, radiusSq.isFinite {
            return distSq <= radiusSq
        }
        return (delta * delta).sum().squareRoot() <= radius
    }

    @usableFromInline
    internal func intersectRange(ray: CajuRay, maxT: Float) -> (tEnter: Float, tExit: Float)? {
        var tMin = ray.tMin
        var tMax = maxT
        if tMin > tMax { return nil }

        guard
            Self.clipSlab(
                origin: ray.origin.x,
                direction: ray.direction.x,
                inverseDirection: ray.inverseDirection.x,
                minBound: min.x,
                maxBound: max.x,
                tMin: &tMin,
                tMax: &tMax
            ),
            Self.clipSlab(
                origin: ray.origin.y,
                direction: ray.direction.y,
                inverseDirection: ray.inverseDirection.y,
                minBound: min.y,
                maxBound: max.y,
                tMin: &tMin,
                tMax: &tMax
            ),
            Self.clipSlab(
                origin: ray.origin.z,
                direction: ray.direction.z,
                inverseDirection: ray.inverseDirection.z,
                minBound: min.z,
                maxBound: max.z,
                tMin: &tMin,
                tMax: &tMax
            )
        else {
            return nil
        }

        return (tMin, tMax)
    }

    @inline(__always)
    @usableFromInline
    internal static func clipSlab(
        origin: Float,
        direction: Float,
        inverseDirection: Float,
        minBound: Float,
        maxBound: Float,
        tMin: inout Float,
        tMax: inout Float
    ) -> Bool {
        if direction == 0 {
            return origin >= minBound && origin <= maxBound
        }
        var t0 = (minBound - origin) * inverseDirection
        var t1 = (maxBound - origin) * inverseDirection
        if inverseDirection < 0 {
            swap(&t0, &t1)
        }
        if t0.isNaN { t0 = 0 }
        if t1.isNaN { t1 = 0 }
        if t0 > tMin { tMin = t0 }
        if t1 < tMax { tMax = t1 }
        return tMin <= tMax
    }

    @inlinable
    internal static func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}
