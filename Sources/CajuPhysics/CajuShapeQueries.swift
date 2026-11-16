import CajuCore
import CajuMath

/// Resultado de uma consulta de raio ou varredura contra um volume do ECS.
public struct CajuPhysicsHit: Sendable, Equatable {
    public var entity: CajuEntity
    /// Parâmetro `t` do raio (em unidades de `direction`; para varredura, fração `0...1`).
    public var t: Float
    /// Ponto de impacto no mundo.
    public var point: CajuVec3
    /// Normal da superfície no mundo (unitária). Se a origem está dentro do volume, é `-direção`.
    public var normal: CajuVec3
}

/// Estado de um volume já levado ao mundo (matriz, inversa e forma), usado pela fase estreita.
@usableFromInline
internal struct CajuColliderEntry {
    var entity: CajuEntity
    var collider: CajuCollider
    var world: CajuMat4
    var inverse: CajuMat4
    var stamp: UInt64
    var live: Bool

    /// AABB do volume no mundo (conservadora para rotação/escala).
    func worldBounds() -> CajuAABB {
        let c = world.transformPoint(CajuVec3(storage: collider.center)).storage
        let half = collider.shape == .sphere ? SIMD3<Float>(repeating: collider.size.x) : collider.size
        let m0 = SIMD3<Float>(world.c0.x, world.c0.y, world.c0.z)
        let m1 = SIMD3<Float>(world.c1.x, world.c1.y, world.c1.z)
        let m2 = SIMD3<Float>(world.c2.x, world.c2.y, world.c2.z)
        var e = pointwiseMax(m0, -m0) * half.x
        e += pointwiseMax(m1, -m1) * half.y
        e += pointwiseMax(m2, -m2) * half.z
        return CajuAABB(min: CajuVec3(storage: c - e), max: CajuVec3(storage: c + e))
    }

    /// Maior fator de escala dos eixos locais.
    func maxScale() -> Float {
        func len(_ c: SIMD4<Float>) -> Float { (c.x * c.x + c.y * c.y + c.z * c.z).squareRoot() }
        return Swift.max(len(world.c0), Swift.max(len(world.c1), len(world.c2)))
    }

    /// Normal local → mundo (inversa transposta), normalizada.
    func worldNormal(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let i = inverse
        let v = SIMD3<Float>(
            i.c0.x * n.x + i.c0.y * n.y + i.c0.z * n.z,
            i.c1.x * n.x + i.c1.y * n.y + i.c1.z * n.z,
            i.c2.x * n.x + i.c2.y * n.y + i.c2.z * n.z)
        let l = (v * v).sum().squareRoot()
        return l > 0 ? v / l : n
    }

    /// Raio (mundo) contra o volume. `t` é preservado entre espaços porque a transformação é afim.
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, tMin: Float, tMax: Float)
        -> (t: Float, normal: SIMD3<Float>)?
    {
        let o = inverse.transformPoint(CajuVec3(storage: origin)).storage
        let d = inverse.transformDirection(CajuVec3(storage: direction)).storage
        let c = collider.center
        var t: Float
        var localNormal: SIMD3<Float>? = nil
        switch collider.shape {
        case .box:
            let h = collider.size
            var tEnter = -Float.infinity
            var tExit = Float.infinity
            var axis = -1
            var sgn: Float = 0
            for a in 0..<3 {
                let lo = c[a] - h[a]
                let hi = c[a] + h[a]
                if d[a] == 0 {
                    if o[a] < lo || o[a] > hi { return nil }
                } else {
                    let inv = 1 / d[a]
                    let t1 = (lo - o[a]) * inv
                    let t2 = (hi - o[a]) * inv
                    let near = Swift.min(t1, t2)
                    let far = Swift.max(t1, t2)
                    if near > tEnter {
                        tEnter = near
                        axis = a
                        sgn = inv > 0 ? -1 : 1
                    }
                    if far < tExit { tExit = far }
                    if tEnter > tExit { return nil }
                }
            }
            guard tExit >= tMin, tEnter <= tMax else { return nil }
            if tEnter >= tMin, axis >= 0 {
                t = tEnter
                var n = SIMD3<Float>.zero
                n[axis] = sgn
                localNormal = n
            } else {
                t = tMin
            }
        case .sphere:
            let r = collider.size.x
            let oc = o - c
            let a = (d * d).sum()
            guard a > 0 else { return nil }
            let b = (oc * d).sum()
            let cc = (oc * oc).sum() - r * r
            let disc = b * b - a * cc
            guard disc >= 0 else { return nil }
            let s = disc.squareRoot()
            let t0 = (-b - s) / a
            let t1 = (-b + s) / a
            guard t1 >= tMin, t0 <= tMax else { return nil }
            if t0 >= tMin {
                t = t0
                let p = o + d * t0 - c
                let l = (p * p).sum().squareRoot()
                localNormal = l > 0 ? p / l : SIMD3(0, 1, 0)
            } else {
                t = tMin
            }
        }
        guard t <= tMax else { return nil }
        if let n = localNormal { return (t, worldNormal(n)) }
        let dl = (direction * direction).sum().squareRoot()
        return (t, dl > 0 ? -direction / dl : SIMD3(0, 1, 0))
    }

    /// Esfera do mundo × volume (exato para movimento rígido e escala uniforme; conservador caso contrário).
    func overlaps(sphereCenter: SIMD3<Float>, radius: Float) -> Bool {
        switch collider.shape {
        case .sphere:
            let wc = world.transformPoint(CajuVec3(storage: collider.center)).storage
            let rr = radius + collider.size.x * maxScale()
            let d = sphereCenter - wc
            return (d * d).sum() <= rr * rr
        case .box:
            let lc = inverse.transformPoint(CajuVec3(storage: sphereCenter)).storage
            let lo = collider.center - collider.size
            let hi = collider.center + collider.size
            let closest = SIMD3<Float>(
                Swift.max(lo.x, Swift.min(lc.x, hi.x)), Swift.max(lo.y, Swift.min(lc.y, hi.y)),
                Swift.max(lo.z, Swift.min(lc.z, hi.z)))
            let wp = world.transformPoint(CajuVec3(storage: closest)).storage
            let d = sphereCenter - wp
            return (d * d).sum() <= radius * radius
        }
    }

    /// Varredura de esfera (`t` em `0...1`): raio contra o volume inflado por `radius`
    /// (exato contra esferas; contra caixas é conservador nas arestas e cantos).
    func spherecast(origin: SIMD3<Float>, displacement: SIMD3<Float>, radius: Float)
        -> (t: Float, normal: SIMD3<Float>)?
    {
        var inflated = self
        switch collider.shape {
        case .sphere:
            inflated.collider.size = SIMD3(repeating: collider.size.x + radius / Swift.max(maxScale(), 1e-12))
        case .box:
            let i = inverse
            let k = SIMD3<Float>(
                (i.c0.x * i.c0.x + i.c1.x * i.c1.x + i.c2.x * i.c2.x).squareRoot(),
                (i.c0.y * i.c0.y + i.c1.y * i.c1.y + i.c2.y * i.c2.y).squareRoot(),
                (i.c0.z * i.c0.z + i.c1.z * i.c1.z + i.c2.z * i.c2.z).squareRoot())
            inflated.collider.size = collider.size + k * radius
        }
        return inflated.raycast(origin: origin, direction: displacement, tMin: 0, tMax: 1)
    }
}
