import CajuMath

/// Caixa envolvente alinhada aos eixos (*Axis-Aligned Bounding Box*).
///
/// Caixas de volume zero (pontos, segmentos ou planos com `min == max` em um ou mais eixos)
/// são válidas. Todos os componentes são garantidamente finitos e satisfazem `min <= max`.
///
/// ```swift
/// let box = try CajuAABB(min: SIMD3(0, 0, 0), max: SIMD3(1, 2, 3))
/// let bigger = try box.enlarged(margin: 0.5)
/// ```
public struct CajuAABB: Sendable, Equatable, Hashable {
    /// Canto mínimo da caixa (`min <= max` em todos os eixos).
    public let min: SIMD3<Float>

    /// Canto máximo da caixa (`min <= max` em todos os eixos).
    public let max: SIMD3<Float>

    @inlinable
    internal init(uncheckedMin min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    /// Cria uma AABB validando finitude e ordenação (`min <= max`).
    ///
    /// - Throws: `CajuSpatialError.nonFiniteBounds` se algum componente for `NaN` ou infinito;
    ///   `CajuSpatialError.invalidBounds` se `min > max` em algum eixo.
    @inlinable
    public init(min: SIMD3<Float>, max: SIMD3<Float>) throws(CajuSpatialError) {
        guard allFinite(min), allFinite(max) else {
            throw .nonFiniteBounds
        }
        guard min.x <= max.x, min.y <= max.y, min.z <= max.z else {
            throw .invalidBounds
        }
        self.min = min
        self.max = max
    }

    /// Cria uma AABB a partir de `CajuVec3`, validando finitude e ordenação (`min <= max`).
    ///
    /// - Throws: `CajuSpatialError.nonFiniteBounds` ou `CajuSpatialError.invalidBounds`.
    @inlinable
    public init(min: CajuVec3, max: CajuVec3) throws(CajuSpatialError) {
        try self.init(min: min.storage, max: max.storage)
    }

    /// Centro geométrico da caixa.
    @inlinable
    public var center: SIMD3<Float> {
        min * 0.5 + max * 0.5
    }

    /// Dimensões da caixa (`max - min`).
    @inlinable
    public var extents: SIMD3<Float> {
        max - min
    }

    /// Área superficial total da caixa (`2 * (dx*dy + dy*dz + dz*dx)`).
    @inlinable
    public var surfaceArea: Float {
        let d = max - min
        return 2.0 * (d.x * d.y + d.y * d.z + d.z * d.x)
    }

    /// Retorna a menor AABB que engloba `self` e `other`.
    @inlinable
    public func union(_ other: CajuAABB) -> CajuAABB {
        CajuAABB(
            uncheckedMin: SIMD3<Float>(
                Swift.min(min.x, other.min.x),
                Swift.min(min.y, other.min.y),
                Swift.min(min.z, other.min.z)
            ),
            max: SIMD3<Float>(
                Swift.max(max.x, other.max.x),
                Swift.max(max.y, other.max.y),
                Swift.max(max.z, other.max.z)
            )
        )
    }

    /// Retorna `true` se `self` e `other` se sobrepõem (incluindo toque em face, aresta ou vértice).
    @inlinable
    public func overlaps(_ other: CajuAABB) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x
            && min.y <= other.max.y && max.y >= other.min.y
            && min.z <= other.max.z && max.z >= other.min.z
    }

    /// Retorna `true` se `self` contém integralmente `other` (inclusive fronteiras).
    @inlinable
    public func contains(_ other: CajuAABB) -> Bool {
        min.x <= other.min.x && max.x >= other.max.x
            && min.y <= other.min.y && max.y >= other.max.y
            && min.z <= other.min.z && max.z >= other.max.z
    }

    /// Retorna `true` se o ponto está dentro ou sobre a fronteira da caixa.
    @inlinable
    public func contains(_ point: SIMD3<Float>) -> Bool {
        point.x >= min.x && point.x <= max.x
            && point.y >= min.y && point.y <= max.y
            && point.z >= min.z && point.z <= max.z
    }

    /// Retorna uma nova AABB expandida por `margin` em todas as direções (`min - margin`, `max + margin`).
    ///
    /// - Throws: `CajuSpatialError.nonFiniteBounds` se `margin` ou o resultado não for finito;
    ///   `CajuSpatialError.invalidBounds` se `margin` negativa inverter `min > max`.
    @inlinable
    public func enlarged(margin: Float) throws(CajuSpatialError) -> CajuAABB {
        guard margin.isFinite else {
            throw .nonFiniteBounds
        }
        let m = SIMD3<Float>(repeating: margin)
        return try CajuAABB(min: min - m, max: max + m)
    }

    /// Versão interna que expande e satura aos limites finitos de `Float` para AABB gorda da BVH.
    @inlinable
    internal func enlargedClamped(margin: Float, displacement: SIMD3<Float> = .zero) -> CajuAABB {
        let m = SIMD3<Float>(repeating: margin)
        var newMin = min - m
        var newMax = max + m
        if displacement.x < 0 { newMin.x += displacement.x } else { newMax.x += displacement.x }
        if displacement.y < 0 { newMin.y += displacement.y } else { newMax.y += displacement.y }
        if displacement.z < 0 { newMin.z += displacement.z } else { newMax.z += displacement.z }
        // Garante que a caixa gorda sempre contenha a caixa original mesmo sob saturação.
        newMin = SIMD3<Float>(
            Swift.min(min.x, clampToFinite(newMin.x)),
            Swift.min(min.y, clampToFinite(newMin.y)),
            Swift.min(min.z, clampToFinite(newMin.z))
        )
        newMax = SIMD3<Float>(
            Swift.max(max.x, clampToFinite(newMax.x)),
            Swift.max(max.y, clampToFinite(newMax.y)),
            Swift.max(max.z, clampToFinite(newMax.z))
        )
        return CajuAABB(uncheckedMin: newMin, max: newMax)
    }

    /// Verifica sobreposição exata entre esta AABB e uma esfera `(center, radius)`.
    @inlinable
    internal func overlapsSphere(center: SIMD3<Float>, radius: Float) -> Bool {
        let cx = Swift.max(min.x, Swift.min(center.x, max.x))
        let cy = Swift.max(min.y, Swift.min(center.y, max.y))
        let cz = Swift.max(min.z, Swift.min(center.z, max.z))
        let dx = center.x - cx
        let dy = center.y - cy
        let dz = center.z - cz
        let distSq = dx * dx + dy * dy + dz * dz
        let rSq = radius * radius
        if distSq.isFinite && rSq.isFinite {
            return distSq <= rSq
        }
        let maxScale = Swift.max(Swift.abs(dx), Swift.max(Swift.abs(dy), Swift.abs(dz)))
        let scale = Swift.max(maxScale, radius)
        if scale <= 0 {
            return true
        }
        let invScale = 1.0 / scale
        let sx = dx * invScale
        let sy = dy * invScale
        let sz = dz * invScale
        let sr = radius * invScale
        return sx * sx + sy * sy + sz * sz <= sr * sr
    }

    /// Testa interseção de um raio com esta AABB pelo método *slab* robusto.
    ///
    /// - Returns: O parâmetro `t` de entrada (`>= ray.tMin`, `<= tMaxLimit ?? ray.tMax`),
    ///   ou `nil` se não houver interseção. Se a origem estiver dentro da caixa e `tMin == 0`,
    ///   retorna `0`.
    @inlinable
    public func intersect(ray: CajuRay, tMaxLimit: Float? = nil) -> Float? {
        ray.intersect(self, tMaxLimit: tMaxLimit)
    }
}
