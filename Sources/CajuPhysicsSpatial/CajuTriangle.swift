import CajuMath

/// Resultado da interseção raio-triângulo (algoritmo de Möller–Trumbore).
///
/// As coordenadas baricêntricas correspondentes aos vértices `(v0, v1, v2)` são
/// `(1 - u - v, u, v)`, com `u >= 0`, `v >= 0` e `u + v <= 1`.
public struct CajuTriangleHit: Sendable, Equatable {
    /// Parâmetro `t` ao longo do raio no ponto de interseção (`ray.origin + t * ray.direction`).
    public let t: Float
    /// Coordenada baricêntrica associada a `v1 - v0`.
    public let u: Float
    /// Coordenada baricêntrica associada a `v2 - v0`.
    public let v: Float

    /// Cria um resultado de interseção raio-triângulo.
    @inlinable
    public init(t: Float, u: Float, v: Float) {
        self.t = t
        self.u = u
        self.v = v
    }
}

/// Triângulo no espaço 3D definido por três vértices (`v0`, `v1`, `v2`).
///
/// Triângulos degenerados (área zero) nunca geram hit em `intersect(ray:)`.
///
/// ```swift
/// let tri = CajuTriangle(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
/// let ray = try CajuRay(origin: SIMD3(0.2, 0.2, -1), direction: SIMD3(0, 0, 1))
/// let hit = tri.intersect(ray: ray)
/// ```
public struct CajuTriangle: Sendable, Equatable, Hashable {
    /// Primeiro vértice do triângulo.
    public var v0: SIMD3<Float>
    /// Segundo vértice do triângulo.
    public var v1: SIMD3<Float>
    /// Terceiro vértice do triângulo.
    public var v2: SIMD3<Float>

    /// Cria um triângulo a partir de três vértices `SIMD3<Float>`.
    @inlinable
    public init(_ v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>) {
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
    }

    /// Cria um triângulo a partir de três vértices `CajuVec3`.
    @inlinable
    public init(_ v0: CajuVec3, _ v1: CajuVec3, _ v2: CajuVec3) {
        self.v0 = v0.storage
        self.v1 = v1.storage
        self.v2 = v2.storage
    }

    /// AABB justa envolvendo os três vértices, ou `nil` se algum vértice não for finito.
    @inlinable
    public var bounds: CajuAABB? {
        guard allFinite(v0), allFinite(v1), allFinite(v2) else {
            return nil
        }
        return uncheckedBounds
    }

    @inlinable
    internal var uncheckedBounds: CajuAABB {
        let minP = SIMD3<Float>(
            Swift.min(v0.x, Swift.min(v1.x, v2.x)),
            Swift.min(v0.y, Swift.min(v1.y, v2.y)),
            Swift.min(v0.z, Swift.min(v1.z, v2.z))
        )
        let maxP = SIMD3<Float>(
            Swift.max(v0.x, Swift.max(v1.x, v2.x)),
            Swift.max(v0.y, Swift.max(v1.y, v2.y)),
            Swift.max(v0.z, Swift.max(v1.z, v2.z))
        )
        return CajuAABB(uncheckedMin: minP, max: maxP)
    }

    /// Interseção raio-triângulo pelo método de Möller–Trumbore.
    ///
    /// Triângulos degenerados (área zero ou vértices colineares/não finitos) retornam `nil`.
    ///
    /// - Parameters:
    ///   - ray: Raio validado.
    ///   - twoSided: Quando `true` (padrão), aceita interseção pelos dois lados do triângulo;
    ///     quando `false`, descarta faces voltadas para fora do raio (*backface culling*).
    ///   - tMaxLimit: Teto opcional para `t` (limitado por `ray.tMax`).
    /// - Returns: `CajuTriangleHit(t:u:v:)` ou `nil` se não houver interseção.
    @inlinable
    public func intersect(
        ray: CajuRay,
        twoSided: Bool = true,
        tMaxLimit: Float? = nil
    ) -> CajuTriangleHit? {
        guard allFinite(v0), allFinite(v1), allFinite(v2) else {
            return nil
        }
        let limit = tMaxLimit.map { Swift.min($0, ray.tMax) } ?? ray.tMax
        if ray.tMin > limit { return nil }

        let edge1 = v1 - v0
        let edge2 = v2 - v0

        // Rejeita triângulos degenerados (área zero ou colineares até a precisão de Float32)
        // de forma invariante à escala.
        let e1Sq = simdLengthSquared(edge1)
        let e2Sq = simdLengthSquared(edge2)
        let maxEdgeSq = Swift.max(e1Sq, e2Sq)
        let minEdgeSq = Swift.min(e1Sq, e2Sq)
        guard maxEdgeSq > 0, minEdgeSq > 0 else { return nil }

        let triNormal = simdCross(edge1, edge2)
        let areaSq4 = simdLengthSquared(triNormal)
        guard areaSq4.isFinite, (areaSq4 / maxEdgeSq) > 1e-12 * minEdgeSq else {
            return nil
        }

        let pvec = simdCross(ray.direction, edge2)
        let det = simdDot(edge1, pvec)

        if twoSided {
            guard det.isFinite, det != 0 else { return nil }
        } else {
            guard det.isFinite, det > 0 else { return nil }
        }

        let invDet = 1.0 / det
        guard invDet.isFinite else { return nil }

        let tvec = ray.origin - v0
        let u = simdDot(tvec, pvec) * invDet
        guard u >= 0, u <= 1 else { return nil }

        let qvec = simdCross(tvec, edge1)
        let v = simdDot(ray.direction, qvec) * invDet
        guard v >= 0, u + v <= 1 else { return nil }

        let t = simdDot(edge2, qvec) * invDet
        guard t >= ray.tMin, t <= limit else { return nil }

        return CajuTriangleHit(t: t, u: u, v: v)
    }

    /// Testa sobreposição exata entre este triângulo e `aabb` (Teorema do Eixo Separador / 13 eixos).
    @inlinable
    public func overlaps(_ aabb: CajuAABB) -> Bool {
        guard allFinite(v0), allFinite(v1), allFinite(v2) else {
            return false
        }
        // 3 eixos normais às faces da AABB (teste direto sem erro de translação).
        let triMinX = Swift.min(v0.x, Swift.min(v1.x, v2.x))
        let triMaxX = Swift.max(v0.x, Swift.max(v1.x, v2.x))
        if triMinX > aabb.max.x || triMaxX < aabb.min.x { return false }

        let triMinY = Swift.min(v0.y, Swift.min(v1.y, v2.y))
        let triMaxY = Swift.max(v0.y, Swift.max(v1.y, v2.y))
        if triMinY > aabb.max.y || triMaxY < aabb.min.y { return false }

        let triMinZ = Swift.min(v0.z, Swift.min(v1.z, v2.z))
        let triMaxZ = Swift.max(v0.z, Swift.max(v1.z, v2.z))
        if triMinZ > aabb.max.z || triMaxZ < aabb.min.z { return false }

        let c = aabb.center
        let e = aabb.extents * 0.5
        let a = v0 - c
        let b = v1 - c
        let d = v2 - c

        let f0 = b - a
        let f1 = d - b
        let f2 = a - d

        // 9 eixos de produto vetorial entre arestas do triângulo e eixos da AABB.
        if !testCrossAxes(edge: f0, a: a, b: b, c: d, extents: e) { return false }
        if !testCrossAxes(edge: f1, a: a, b: b, c: d, extents: e) { return false }
        if !testCrossAxes(edge: f2, a: a, b: b, c: d, extents: e) { return false }

        // Eixo normal ao plano do triângulo.
        let normal = simdCross(f0, f1)
        let planeDist = simdDot(normal, a)
        let radius = e.x * Swift.abs(normal.x) + e.y * Swift.abs(normal.y) + e.z * Swift.abs(normal.z)
        if Swift.abs(planeDist) > radius { return false }

        return true
    }

    @inlinable
    internal func testCrossAxes(
        edge: SIMD3<Float>,
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>,
        extents e: SIMD3<Float>
    ) -> Bool {
        // Eixo (0, -edge.z, edge.y)
        do {
            let p0 = a.z * edge.y - a.y * edge.z
            let p1 = b.z * edge.y - b.y * edge.z
            let p2 = c.z * edge.y - c.y * edge.z
            let minP = Swift.min(p0, Swift.min(p1, p2))
            let maxP = Swift.max(p0, Swift.max(p1, p2))
            let r = e.y * Swift.abs(edge.z) + e.z * Swift.abs(edge.y)
            if minP > r || maxP < -r { return false }
        }
        // Eixo (edge.z, 0, -edge.x)
        do {
            let p0 = a.x * edge.z - a.z * edge.x
            let p1 = b.x * edge.z - b.z * edge.x
            let p2 = c.x * edge.z - c.z * edge.x
            let minP = Swift.min(p0, Swift.min(p1, p2))
            let maxP = Swift.max(p0, Swift.max(p1, p2))
            let r = e.x * Swift.abs(edge.z) + e.z * Swift.abs(edge.x)
            if minP > r || maxP < -r { return false }
        }
        // Eixo (-edge.y, edge.x, 0)
        do {
            let p0 = a.y * edge.x - a.x * edge.y
            let p1 = b.y * edge.x - b.x * edge.y
            let p2 = c.y * edge.x - c.x * edge.y
            let minP = Swift.min(p0, Swift.min(p1, p2))
            let maxP = Swift.max(p0, Swift.max(p1, p2))
            let r = e.x * Swift.abs(edge.y) + e.y * Swift.abs(edge.x)
            if minP > r || maxP < -r { return false }
        }
        return true
    }

    /// Retorna o ponto sobre o triângulo mais próximo de `point`.
    @inlinable
    public func closestPoint(to point: SIMD3<Float>) -> SIMD3<Float> {
        let ab = v1 - v0
        let ac = v2 - v0
        let ap = point - v0

        let d1 = simdDot(ab, ap)
        let d2 = simdDot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return v0 }

        let bp = point - v1
        let d3 = simdDot(ab, bp)
        let d4 = simdDot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return v1 }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let denom = d1 - d3
            if denom > 0 {
                return v0 + ab * (d1 / denom)
            }
        }

        let cp = point - v2
        let d5 = simdDot(ab, cp)
        let d6 = simdDot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return v2 }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let denom = d2 - d6
            if denom > 0 {
                return v0 + ac * (d2 / denom)
            }
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let denom = (d4 - d3) + (d5 - d6)
            if denom > 0 {
                return v1 + (v2 - v1) * ((d4 - d3) / denom)
            }
        }

        let denomSum = va + vb + vc
        if denomSum > 0 {
            let invDenom = 1.0 / denomSum
            let v = vb * invDenom
            let w = vc * invDenom
            return v0 + ab * v + ac * w
        }

        // Fallback para triângulos degenerados (vértices colineares ou coincidentes).
        return closestPointOnSegments(to: point)
    }

    @inlinable
    internal func closestPointOnSegments(to point: SIMD3<Float>) -> SIMD3<Float> {
        let p0 = closestPointOnSegment(a: v0, b: v1, p: point)
        let p1 = closestPointOnSegment(a: v1, b: v2, p: point)
        let p2 = closestPointOnSegment(a: v2, b: v0, p: point)
        let d0 = simdLengthSquared(point - p0)
        let d1 = simdLengthSquared(point - p1)
        let d2 = simdLengthSquared(point - p2)
        if d0 <= d1 && d0 <= d2 { return p0 }
        if d1 <= d2 { return p1 }
        return p2
    }

    @inlinable
    internal func closestPointOnSegment(
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        p: SIMD3<Float>
    ) -> SIMD3<Float> {
        let ab = b - a
        let lenSq = simdLengthSquared(ab)
        if lenSq <= 0 { return a }
        let t = Swift.max(0, Swift.min(1, simdDot(p - a, ab) / lenSq))
        return a + ab * t
    }

    /// Testa sobreposição exata entre este triângulo e uma esfera `(center, radius)`.
    @inlinable
    public func overlapsSphere(center: SIMD3<Float>, radius: Float) -> Bool {
        guard allFinite(v0), allFinite(v1), allFinite(v2),
            allFinite(center), radius.isFinite, radius >= 0
        else {
            return false
        }
        let closest = closestPoint(to: center)
        let diff = closest - center
        let distSq = simdLengthSquared(diff)
        let rSq = radius * radius
        if distSq.isFinite && rSq.isFinite {
            return distSq <= rSq
        }
        let maxScale = Swift.max(
            Swift.abs(diff.x),
            Swift.max(Swift.abs(diff.y), Swift.abs(diff.z))
        )
        let scale = Swift.max(maxScale, radius)
        if scale <= 0 { return true }
        let inv = 1.0 / scale
        return simdLengthSquared(diff * inv) <= (radius * inv) * (radius * inv)
    }
}
