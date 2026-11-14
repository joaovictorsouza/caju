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
