import CajuMath

/// BVH e consultas espaciais (raycast, shapecast, sobreposição).
///
/// Marcador do módulo `CajuPhysicsSpatial` mantido para verificação de linkagem.
public enum CajuPhysicsSpatialModule {}

/// Erros tipados retornados pelas operações de validação e manipulação de estruturas espaciais.
public enum CajuSpatialError: Error, Sendable, Equatable, Hashable {
    /// Limites (`min` ou `max`) contêm `NaN` ou infinito.
    case nonFiniteBounds
    /// Limites inválidos onde `min > max` em pelo menos um eixo.
    case invalidBounds
    /// Origem, direção ou limites `tMin`/`tMax` do raio contêm `NaN` ou infinito.
    case nonFiniteRay
    /// Direção do raio é nula (`(0, 0, 0)`).
    case invalidRayDirection
    /// Intervalo paramétrico inválido no raio (`tMin < 0` ou `tMin > tMax`).
    case invalidRayRange
    /// Handle (`CajuBVHProxy`) inválido, expirado ou já removido.
    case invalidHandle
    /// Capacidade máxima configurada ou suportada por índices `Int32` foi excedida.
    case capacityExceeded
    /// Entrada numérica contém `NaN` ou infinito (posições, deslocamento, centro ou margem).
    case nonFiniteInput
    /// Raio de esfera negativo ou margem negativa inválida.
    case invalidRadius
    /// Buffer de índices ou vértices inválido (quantidade não múltipla de 3 ou índice fora do limite).
    case invalidTriangleIndices
}

@inlinable
internal func allFinite(_ v: SIMD3<Float>) -> Bool {
    v.x.isFinite && v.y.isFinite && v.z.isFinite
}

@inlinable
internal func simdDot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    (a * b).sum()
}

@inlinable
internal func simdCross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
}

@inlinable
internal func simdLengthSquared(_ v: SIMD3<Float>) -> Float {
    (v * v).sum()
}

@inlinable
internal func clampToFinite(_ v: Float) -> Float {
    if v.isFinite { return v }
    return v < 0 ? -Float.greatestFiniteMagnitude : Float.greatestFiniteMagnitude
}

@inlinable
internal func clampToFinite(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(clampToFinite(v.x), clampToFinite(v.y), clampToFinite(v.z))
}

@inlinable
internal func validateAABB(_ box: CajuAABB) throws(CajuSpatialError) {
    guard box.isFinite else {
        throw .nonFiniteBounds
    }
    guard box.min.x <= box.max.x,
        box.min.y <= box.max.y,
        box.min.z <= box.max.z
    else {
        throw .invalidBounds
    }
}

@inlinable
internal func isValidAABB(_ box: CajuAABB) -> Bool {
    box.isFinite
        && box.min.x <= box.max.x
        && box.min.y <= box.max.y
        && box.min.z <= box.max.z
}

@inlinable
internal func validateSphere(_ sphere: CajuSphere) throws(CajuSpatialError) {
    guard sphere.isFinite else {
        throw .nonFiniteInput
    }
    guard sphere.radius >= 0 else {
        throw .invalidRadius
    }
}

@inlinable
internal func aabbCenter(_ box: CajuAABB) -> SIMD3<Float> {
    box.min.storage * 0.5 + box.max.storage * 0.5
}

@inlinable
internal func aabbHalfExtents(_ box: CajuAABB) -> SIMD3<Float> {
    box.max.storage * 0.5 - box.min.storage * 0.5
}

@inlinable
internal func aabbSurfaceArea(_ box: CajuAABB) -> Float {
    let d = box.max.storage - box.min.storage
    return 2.0 * (d.x * d.y + d.y * d.z + d.z * d.x)
}

@inlinable
internal func aabbContains(_ outer: CajuAABB, _ inner: CajuAABB) -> Bool {
    outer.min.x <= inner.min.x && outer.max.x >= inner.max.x
        && outer.min.y <= inner.min.y && outer.max.y >= inner.max.y
        && outer.min.z <= inner.min.z && outer.max.z >= inner.max.z
}

@inlinable
internal func aabbEnlargedClamped(
    _ box: CajuAABB,
    margin: Float,
    displacement: SIMD3<Float> = .zero
) -> CajuAABB {
    let m = SIMD3<Float>(repeating: margin)
    var newMin = box.min.storage - m
    var newMax = box.max.storage + m
    if displacement.x < 0 { newMin.x += displacement.x } else { newMax.x += displacement.x }
    if displacement.y < 0 { newMin.y += displacement.y } else { newMax.y += displacement.y }
    if displacement.z < 0 { newMin.z += displacement.z } else { newMax.z += displacement.z }
    // Garante que a caixa gorda sempre contenha a caixa original mesmo sob saturação.
    newMin = SIMD3<Float>(
        Swift.min(box.min.x, clampToFinite(newMin.x)),
        Swift.min(box.min.y, clampToFinite(newMin.y)),
        Swift.min(box.min.z, clampToFinite(newMin.z))
    )
    newMax = SIMD3<Float>(
        Swift.max(box.max.x, clampToFinite(newMax.x)),
        Swift.max(box.max.y, clampToFinite(newMax.y)),
        Swift.max(box.max.z, clampToFinite(newMax.z))
    )
    return CajuAABB(min: CajuVec3(storage: newMin), max: CajuVec3(storage: newMax))
}

@inlinable
internal func aabbOverlapsSphere(
    _ box: CajuAABB,
    center: SIMD3<Float>,
    radius: Float
) -> Bool {
    let cx = Swift.max(box.min.x, Swift.min(center.x, box.max.x))
    let cy = Swift.max(box.min.y, Swift.min(center.y, box.max.y))
    let cz = Swift.max(box.min.z, Swift.min(center.z, box.max.z))
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
