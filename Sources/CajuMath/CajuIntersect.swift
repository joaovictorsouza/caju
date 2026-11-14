/// Raio semi-infinito definido por uma origem e uma direção.
///
/// ```swift
/// let ray = CajuRay(origin: CajuVec3(0, 0, 5), direction: CajuVec3(0, 0, -1))
/// let hitT = ray.intersects(CajuSphere(center: .zero, radius: 1))  // 4
/// ```
public struct CajuRay: Sendable, Equatable, Hashable {
    public var origin: CajuVec3
    public var direction: CajuVec3

    @inlinable public init(origin: CajuVec3, direction: CajuVec3) {
        self.origin = origin
        self.direction = direction
    }

    /// Constrói um raio normalizando `direction`, ou retorna `nil` se a direção ou origem forem inválidas.
    @inlinable public init?(origin: CajuVec3, normalizingDirection direction: CajuVec3) {
        guard origin.isFinite, let dir = direction.normalized() else { return nil }
        self.origin = origin
        self.direction = dir
    }

    /// Indica se origem e direção são finitas.
    @inlinable public var isFinite: Bool { origin.isFinite && direction.isFinite }

    /// Ponto ao longo do raio em `origin + direction * t`.
    @inlinable public func point(at t: Float) -> CajuVec3 {
        origin + direction * t
    }

    /// Interseção raio × AABB via método dos *slabs* (robusto a componentes nulos de `direction`).
    ///
    /// Retorna o menor `t >= 0` sobre a superfície da caixa (saída se a origem estiver dentro), ou `nil` se não houver interseção.
    @inlinable public func intersects(_ aabb: CajuAABB) -> Float? {
        guard origin.isFinite, direction.isFinite, direction.lengthSquared > 0,
            aabb.isFinite,
            aabb.min.x <= aabb.max.x, aabb.min.y <= aabb.max.y, aabb.min.z <= aabb.max.z
        else { return nil }

        var tMin: Float = -.infinity
        var tMax: Float = .infinity

        if !slab(origin.x, direction.x, aabb.min.x, aabb.max.x, &tMin, &tMax) { return nil }
        if !slab(origin.y, direction.y, aabb.min.y, aabb.max.y, &tMin, &tMax) { return nil }
        if !slab(origin.z, direction.z, aabb.min.z, aabb.max.z, &tMin, &tMax) { return nil }

        guard tMax >= 0 else { return nil }
        let t = tMin >= 0 ? tMin : tMax
        return t.isFinite ? t : nil
    }

    @inlinable func slab(
        _ o: Float,
        _ d: Float,
        _ bMin: Float,
        _ bMax: Float,
        _ tMin: inout Float,
        _ tMax: inout Float
    ) -> Bool {
        if d == 0 {
            return o >= bMin && o <= bMax
        }
        let invD = 1 / d
        guard invD.isFinite else {
            return o >= bMin && o <= bMax
        }
        var t0 = (bMin - o) * invD
        var t1 = (bMax - o) * invD
        if t0 > t1 { swap(&t0, &t1) }
        tMin = max(tMin, t0)
        tMax = min(tMax, t1)
        return tMin <= tMax
    }

    /// Interseção raio × esfera: retorna o menor `t >= 0` sobre a superfície, ou `nil`.
    @inlinable public func intersects(_ sphere: CajuSphere) -> Float? {
        guard origin.isFinite, direction.isFinite, sphere.isFinite, sphere.radius >= 0 else {
            return nil
        }
        let a = direction.lengthSquared
        guard a > 0, a.isFinite else { return nil }
        let oc = origin - sphere.center
        let tCenter = -oc.dot(direction) / a
        let closest = oc + direction * tCenter
        let d2 = closest.lengthSquared
        let r2 = sphere.radius * sphere.radius
        guard d2 <= r2, d2.isFinite, r2.isFinite else { return nil }
        let halfChord = ((r2 - d2) / a).squareRoot()
        let t0 = tCenter - halfChord
        if t0 >= 0 { return t0.isFinite ? t0 : nil }
        let t1 = tCenter + halfChord
        return (t1 >= 0 && t1.isFinite) ? t1 : nil
    }

    /// Interseção raio × plano: retorna `t >= 0` ou `nil` se paralelo ou atrás da origem.
    @inlinable public func intersects(_ plane: CajuPlane) -> Float? {
        guard origin.isFinite, direction.isFinite, plane.isFinite else { return nil }
        let dirLen = direction.length
        guard dirLen > 0, dirLen.isFinite else { return nil }
        let denom = plane.normal.dot(direction)
        guard abs(denom) > 1e-6 * dirLen else { return nil }
        let t = -(plane.normal.dot(origin) + plane.distance) / denom
        guard t.isFinite, t >= 0 else { return nil }
        return t
    }

    /// Interseção raio × triângulo via algoritmo de Möller–Trumbore.
    ///
    /// - Parameters:
    ///   - a: Primeiro vértice (sentido anti-horário define a face frontal).
    ///   - b: Segundo vértice.
    ///   - c: Terceiro vértice.
    ///   - backfaceCulling: Quando `true`, descarta faces traseiras (`det <= 0`).
    /// - Returns: `(t, u, v)` com coordenadas baricêntricas `(1 - u - v, u, v)`, ou `nil`.
    @inlinable public func intersectsTriangle(
        _ a: CajuVec3,
        _ b: CajuVec3,
        _ c: CajuVec3,
        backfaceCulling: Bool = true
    ) -> CajuRayTriangleHit? {
        guard origin.isFinite, direction.isFinite, a.isFinite, b.isFinite, c.isFinite else {
            return nil
        }
        let e1 = b - a
        let e2 = c - a
        let pvec = direction.cross(e2)
        let det = e1.dot(pvec)
        let scale = e1.length * pvec.length
        let eps = 1e-7 * scale
        guard scale > 0, scale.isFinite else { return nil }

        if backfaceCulling {
            guard det > eps else { return nil }
        } else {
            guard abs(det) > eps else { return nil }
        }

        let invDet = 1 / det
        guard invDet.isFinite else { return nil }
        let tvec = origin - a
        let u = tvec.dot(pvec) * invDet
        guard u >= 0, u <= 1 else { return nil }

        let qvec = tvec.cross(e1)
        let v = direction.dot(qvec) * invDet
        guard v >= 0, u + v <= 1 else { return nil }

        let t = e2.dot(qvec) * invDet
        guard t.isFinite, t >= 0 else { return nil }
        return CajuRayTriangleHit(t: t, u: u, v: v)
    }
}

/// Resultado de interseção raio × triângulo com parâmetro `t` e coordenadas baricêntricas `(u, v)`.
public struct CajuRayTriangleHit: Sendable, Equatable, Hashable {
    public var t: Float
    public var u: Float
    public var v: Float

    @inlinable public init(t: Float, u: Float, v: Float) {
        self.t = t
        self.u = u
        self.v = v
    }
}

/// Caixa delimitadora alinhada aos eixos (*Axis-Aligned Bounding Box*).
public struct CajuAABB: Sendable, Equatable, Hashable {
    public var min: CajuVec3
    public var max: CajuVec3

    @inlinable public init(min: CajuVec3, max: CajuVec3) {
        self.min = min
        self.max = max
    }

    /// Constrói a partir do centro e dos semi-eixos (`extents >= 0`).
    @inlinable public init(center: CajuVec3, extents: CajuVec3) {
        min = center - extents
        max = center + extents
    }

    @inlinable public var isFinite: Bool { min.isFinite && max.isFinite }

    @inlinable public var center: CajuVec3 { (min + max) * 0.5 }
    @inlinable public var extents: CajuVec3 { (max - min) * 0.5 }
    @inlinable public var size: CajuVec3 { max - min }

    /// Menor caixa que contém `self` e `other`.
    @inlinable public func union(_ other: Self) -> Self {
        Self(min: CajuVec3.min(min, other.min), max: CajuVec3.max(max, other.max))
    }

    /// Menor caixa que contém `self` e `point`.
    @inlinable public func union(_ point: CajuVec3) -> Self {
        Self(min: CajuVec3.min(min, point), max: CajuVec3.max(max, point))
    }

    @inlinable public func contains(_ point: CajuVec3) -> Bool {
        point.x >= min.x && point.x <= max.x
            && point.y >= min.y && point.y <= max.y
            && point.z >= min.z && point.z <= max.z
    }

    @inlinable public func intersects(_ other: Self) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x
            && min.y <= other.max.y && max.y >= other.min.y
            && min.z <= other.max.z && max.z >= other.min.z
    }

    @inlinable public func intersects(_ sphere: CajuSphere) -> Bool {
        sphere.intersects(self)
    }

    @inlinable public func intersects(_ plane: CajuPlane) -> Bool {
        plane.classify(self) == .intersecting
    }

    /// Expande os limites em todas as direções por `amount`.
    @inlinable public func expanded(by amount: Float) -> Self {
        let d = CajuVec3(repeating: amount)
        return Self(min: min - d, max: max + d)
    }

    /// Expande os limites em cada eixo por `delta`.
    @inlinable public func expanded(by delta: CajuVec3) -> Self {
        Self(min: min - delta, max: max + delta)
    }

    /// Transforma a caixa pela matriz `matrix` usando o algoritmo O(1) de Arvo (sem alocações).
    @inlinable public func transformed(by matrix: CajuMat4) -> Self {
        let t = CajuVec3(matrix.c3.x, matrix.c3.y, matrix.c3.z)
        var newMin = t
        var newMax = t

        let c0 = CajuVec3(matrix.c0.x, matrix.c0.y, matrix.c0.z)
        let a0 = c0 * min.x
        let b0 = c0 * max.x
        newMin += CajuVec3.min(a0, b0)
        newMax += CajuVec3.max(a0, b0)

        let c1 = CajuVec3(matrix.c1.x, matrix.c1.y, matrix.c1.z)
        let a1 = c1 * min.y
        let b1 = c1 * max.y
        newMin += CajuVec3.min(a1, b1)
        newMax += CajuVec3.max(a1, b1)

        let c2 = CajuVec3(matrix.c2.x, matrix.c2.y, matrix.c2.z)
        let a2 = c2 * min.z
        let b2 = c2 * max.z
        newMin += CajuVec3.min(a2, b2)
        newMax += CajuVec3.max(a2, b2)

        return Self(min: newMin, max: newMax)
    }
}

/// Esfera delimitadora definida por centro e raio.
public struct CajuSphere: Sendable, Equatable, Hashable {
    public var center: CajuVec3
    public var radius: Float

    @inlinable public init(center: CajuVec3, radius: Float) {
        self.center = center
        self.radius = radius
    }

    @inlinable public var isFinite: Bool { center.isFinite && radius.isFinite }

    @inlinable public func contains(_ point: CajuVec3) -> Bool {
        guard isFinite, point.isFinite, radius >= 0 else { return false }
        return (point - center).lengthSquared <= radius * radius
    }

    @inlinable public func intersects(_ other: Self) -> Bool {
        guard isFinite, other.isFinite, radius >= 0, other.radius >= 0 else { return false }
        let sumR = radius + other.radius
        return (center - other.center).lengthSquared <= sumR * sumR
    }

    @inlinable public func intersects(_ aabb: CajuAABB) -> Bool {
        guard isFinite, aabb.isFinite, radius >= 0,
            aabb.min.x <= aabb.max.x, aabb.min.y <= aabb.max.y, aabb.min.z <= aabb.max.z
        else { return false }
        let closest = center.clamp(min: aabb.min, max: aabb.max)
        return (closest - center).lengthSquared <= radius * radius
    }

    @inlinable public func intersects(_ plane: CajuPlane) -> Bool {
        plane.classify(self) == .intersecting
    }
}

/// Classificação espacial de um volume em relação a um plano.
public enum CajuPlaneSide: Sendable, Equatable, Hashable {
    /// Totalmente no semi-espaço positivo da normal (`signedDistance > 0`).
    case front
    /// Totalmente no semi-espaço negativo da normal (`signedDistance < 0`).
    case back
    /// Cruza ou toca o plano.
    case intersecting
}

/// Plano em 3D definido por `normal.dot(p) + distance == 0` (com `normal` unitário).
public struct CajuPlane: Sendable, Equatable, Hashable {
    public var normal: CajuVec3
    public var distance: Float

    @inlinable public init(normal: CajuVec3, distance: Float) {
        self.normal = normal
        self.distance = distance
    }

    /// Constrói plano passando por `point` com normal normalizada, ou `nil` se inválido.
    @inlinable public init?(normal: CajuVec3, point: CajuVec3) {
        guard point.isFinite, let n = normal.normalized() else { return nil }
        self.init(normal: n, distance: -n.dot(point))
    }

    /// Constrói plano passando pelos três pontos em ordem anti-horária `(b - a) × (c - a)`.
    @inlinable public init?(a: CajuVec3, b: CajuVec3, c: CajuVec3) {
        guard a.isFinite, b.isFinite, c.isFinite,
            let n = (b - a).cross(c - a).normalized()
        else { return nil }
        self.init(normal: n, distance: -n.dot(a))
    }

    @inlinable public var isFinite: Bool { normal.isFinite && distance.isFinite }

    /// Normaliza o plano dividindo `normal` e `distance` pela norma de `normal`.
    @inlinable public func normalized() -> Self? {
        guard distance.isFinite, let n = normal.normalized() else { return nil }
        let len = n.dot(normal)
        guard len.isFinite, len > 0 else { return nil }
        let d = distance / len
        guard d.isFinite else { return nil }
        return Self(normal: n, distance: d)
    }

    /// Distância assinada de `point` até o plano (positiva no lado da normal).
    @inlinable public func signedDistance(to point: CajuVec3) -> Float {
        normal.dot(point) + distance
    }

    /// Projeção ortogonal de `point` sobre o plano.
    @inlinable public func closestPoint(to point: CajuVec3) -> CajuVec3 {
        point - normal * signedDistance(to: point)
    }

    /// Classifica uma esfera em relação ao plano.
    @inlinable public func classify(_ sphere: CajuSphere) -> CajuPlaneSide {
        let d = signedDistance(to: sphere.center)
        if d > sphere.radius { return .front }
        if d < -sphere.radius { return .back }
        return .intersecting
    }

    /// Classifica uma AABB em relação ao plano.
    @inlinable public func classify(_ aabb: CajuAABB) -> CajuPlaneSide {
        let c = aabb.center
        let e = aabb.extents
        let r = e.x * abs(normal.x) + e.y * abs(normal.y) + e.z * abs(normal.z)
        let d = signedDistance(to: c)
        if d > r { return .front }
        if d < -r { return .back }
        return .intersecting
    }
}

/// Tronco de visão (*frustum*) com 6 planos apontando para dentro, extraído de matriz view-projeção `[0, 1]`.
public struct CajuFrustum: Sendable, Equatable {
    public var left: CajuPlane
    public var right: CajuPlane
    public var bottom: CajuPlane
    public var top: CajuPlane
    public var near: CajuPlane
    public var far: CajuPlane

    @inlinable public init(
        left: CajuPlane,
        right: CajuPlane,
        bottom: CajuPlane,
        top: CajuPlane,
        near: CajuPlane,
        far: CajuPlane
    ) {
        self.left = left
        self.right = right
        self.bottom = bottom
        self.top = top
        self.near = near
        self.far = far
    }

    /// Extrai os 6 planos via Gribb–Hartmann para matriz `projection * view` direita com profundidade `[0, 1]` (Metal/Vulkan).
    ///
    /// Retorna `nil` se a matriz não for finita ou se algum plano for degenerado.
    @inlinable public init?(viewProjection m: CajuMat4) {
        guard m.isFinite else { return nil }
        let r0 = SIMD4<Float>(m.c0.x, m.c1.x, m.c2.x, m.c3.x)
        let r1 = SIMD4<Float>(m.c0.y, m.c1.y, m.c2.y, m.c3.y)
        let r2 = SIMD4<Float>(m.c0.z, m.c1.z, m.c2.z, m.c3.z)
        let r3 = SIMD4<Float>(m.c0.w, m.c1.w, m.c2.w, m.c3.w)

        guard let left = Self.plane(from: r3 + r0),
            let right = Self.plane(from: r3 - r0),
            let bottom = Self.plane(from: r3 + r1),
            let top = Self.plane(from: r3 - r1),
            let near = Self.plane(from: r2),
            let far = Self.plane(from: r3 - r2)
        else { return nil }

        self.init(left: left, right: right, bottom: bottom, top: top, near: near, far: far)
    }

    @inlinable static func plane(from row: SIMD4<Float>) -> CajuPlane? {
        CajuPlane(normal: CajuVec3(row.x, row.y, row.z), distance: row.w).normalized()
    }

    /// Verifica se `point` está dentro (ou sobre a borda) de todos os 6 planos.
    @inlinable public func contains(_ point: CajuVec3) -> Bool {
        guard point.isFinite else { return false }
        return left.signedDistance(to: point) >= 0
            && right.signedDistance(to: point) >= 0
            && bottom.signedDistance(to: point) >= 0
            && top.signedDistance(to: point) >= 0
            && near.signedDistance(to: point) >= 0
            && far.signedDistance(to: point) >= 0
    }

    /// Verifica se `sphere` intersecta ou está contida no frustum.
    @inlinable public func intersects(_ sphere: CajuSphere) -> Bool {
        guard sphere.isFinite, sphere.radius >= 0 else { return false }
        let r = sphere.radius
        return left.signedDistance(to: sphere.center) >= -r
            && right.signedDistance(to: sphere.center) >= -r
            && bottom.signedDistance(to: sphere.center) >= -r
            && top.signedDistance(to: sphere.center) >= -r
            && near.signedDistance(to: sphere.center) >= -r
            && far.signedDistance(to: sphere.center) >= -r
    }

    /// Verifica se `sphere` está inteiramente contida no frustum.
    @inlinable public func contains(_ sphere: CajuSphere) -> Bool {
        guard sphere.isFinite, sphere.radius >= 0 else { return false }
        let r = sphere.radius
        return left.signedDistance(to: sphere.center) >= r
            && right.signedDistance(to: sphere.center) >= r
            && bottom.signedDistance(to: sphere.center) >= r
            && top.signedDistance(to: sphere.center) >= r
            && near.signedDistance(to: sphere.center) >= r
            && far.signedDistance(to: sphere.center) >= r
    }

    /// Verifica se `aabb` intersecta ou está contida no frustum.
    @inlinable public func intersects(_ aabb: CajuAABB) -> Bool {
        guard aabb.isFinite,
            aabb.min.x <= aabb.max.x, aabb.min.y <= aabb.max.y, aabb.min.z <= aabb.max.z
        else { return false }
        return left.classify(aabb) != .back
            && right.classify(aabb) != .back
            && bottom.classify(aabb) != .back
            && top.classify(aabb) != .back
            && near.classify(aabb) != .back
            && far.classify(aabb) != .back
    }

    /// Verifica se `aabb` está inteiramente contida no frustum.
    @inlinable public func contains(_ aabb: CajuAABB) -> Bool {
        guard aabb.isFinite,
            aabb.min.x <= aabb.max.x, aabb.min.y <= aabb.max.y, aabb.min.z <= aabb.max.z
        else { return false }
        let c = aabb.center
        let e = aabb.extents
        return Self.containsAABB(left, c, e)
            && Self.containsAABB(right, c, e)
            && Self.containsAABB(bottom, c, e)
            && Self.containsAABB(top, c, e)
            && Self.containsAABB(near, c, e)
            && Self.containsAABB(far, c, e)
    }

    @inlinable static func containsAABB(_ plane: CajuPlane, _ c: CajuVec3, _ e: CajuVec3) -> Bool {
        let r = e.x * abs(plane.normal.x) + e.y * abs(plane.normal.y) + e.z * abs(plane.normal.z)
        return plane.signedDistance(to: c) >= r
    }
}
