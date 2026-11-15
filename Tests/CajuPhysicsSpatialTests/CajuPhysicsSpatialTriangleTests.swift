import CajuMath
import CajuPhysicsSpatial
import CajuTesting
import Testing

private let fuzzIterations = 10_000
private let relTolerance: Float = 1e-4

private func closeRelative(_ a: Float, _ b: Float, tolerance: Float = relTolerance) -> Bool {
    abs(a - b) <= tolerance * max(1.0, abs(a), abs(b))
}

private func makeAABB(_ min: SIMD3<Float>, _ max: SIMD3<Float>) -> CajuAABB {
    CajuAABB(min: CajuVec3(storage: min), max: CajuVec3(storage: max))
}

private func makeSphere(_ center: SIMD3<Float>, _ radius: Float) -> CajuSphere {
    CajuSphere(center: CajuVec3(storage: center), radius: radius)
}

/// Oráculo independente em precisão dupla (`Double`) para interseção raio-triângulo.
private func doubleRayTriangle(
    ray: CajuRayQuery,
    tri: CajuTriangle,
    twoSided: Bool
) -> (hit: Bool, nearBoundary: Bool, t: Float, u: Float, v: Float) {
    let o = SIMD3<Double>(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z))
    let d = SIMD3<Double>(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z))
    let v0 = SIMD3<Double>(Double(tri.v0.x), Double(tri.v0.y), Double(tri.v0.z))
    let v1 = SIMD3<Double>(Double(tri.v1.x), Double(tri.v1.y), Double(tri.v1.z))
    let v2 = SIMD3<Double>(Double(tri.v2.x), Double(tri.v2.y), Double(tri.v2.z))

    let e1 = v1 - v0
    let e2 = v2 - v0
    let normal = SIMD3<Double>(
        e1.y * e2.z - e1.z * e2.y,
        e1.z * e2.x - e1.x * e2.z,
        e1.x * e2.y - e1.y * e2.x
    )
    let areaSq4 = (normal * normal).sum()
    let e1Sq = (e1 * e1).sum()
    let e2Sq = (e2 * e2).sum()
    if areaSq4 <= 1e-10 * e1Sq * e2Sq || e1Sq == 0 || e2Sq == 0 {
        return (false, true, 0, 0, 0)
    }

    let denom = (d * normal).sum()
    if abs(denom) < 1e-5 * (d * d).sum().squareRoot() * areaSq4.squareRoot() {
        return (false, true, 0, 0, 0)
    }
    if !twoSided && denom >= 0 {
        return (false, false, 0, 0, 0)
    }

    let t = ((v0 - o) * normal).sum() / denom
    if abs(t - Double(ray.tMin)) < 1e-4 || abs(t - Double(ray.tMax)) < 1e-4 {
        return (false, true, 0, 0, 0)
    }
    if t < Double(ray.tMin) || t > Double(ray.tMax) {
        return (false, false, 0, 0, 0)
    }

    let p = o + d * t
    let rel = p - v0
    let d00 = (e1 * e1).sum()
    let d01 = (e1 * e2).sum()
    let d11 = (e2 * e2).sum()
    let d20 = (rel * e1).sum()
    let d21 = (rel * e2).sum()
    let baryDenom = d00 * d11 - d01 * d01
    if abs(baryDenom) <= 1e-14 {
        return (false, true, 0, 0, 0)
    }
    let u = (d11 * d20 - d01 * d21) / baryDenom
    let v = (d00 * d21 - d01 * d20) / baryDenom
    let w = 1.0 - u - v

    if abs(u) < 1e-4 || abs(v) < 1e-4 || abs(w) < 1e-4 {
        return (false, true, 0, 0, 0)
    }
    let inside = u >= 0 && v >= 0 && u + v <= 1
    return (inside, false, Float(t), Float(u), Float(v))
}

@Suite("CajuTriangle e CajuTriangleBVH")
struct CajuPhysicsSpatialTriangleTests {
    @Test func triangleMollerTrumboreAnalyticalAndDegenerate() throws {
        let tri = CajuTriangle(CajuVec3(0, 0, 0), CajuVec3(2, 0, 0), CajuVec3(0, 2, 0))
        #expect(tri.bounds == makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 2, 0)))

        // Normal é +Z (CCW). Raio vindo de +Z em direção -Z atinge a frente (twoSided == false aceita).
        let frontRay = try CajuRayQuery(origin: SIMD3<Float>(0.5, 0.5, 3), direction: SIMD3<Float>(0, 0, -1))
        let frontHit = try #require(tri.intersect(ray: frontRay, twoSided: false))
        #expect(closeRelative(frontHit.t, 3))
        #expect(closeRelative(frontHit.u, 0.25))
        #expect(closeRelative(frontHit.v, 0.25))

        // Raio vindo de -Z em direção +Z atinge o verso: descartado com twoSided: false, aceito com true.
        let backRay = try CajuRayQuery(origin: SIMD3<Float>(0.5, 0.5, -2), direction: SIMD3<Float>(0, 0, 1))
        #expect(tri.intersect(ray: backRay, twoSided: false) == nil)
        let backHit = try #require(tri.intersect(ray: backRay, twoSided: true))
        #expect(closeRelative(backHit.t, 2))
        #expect(closeRelative(backHit.u, 0.25))
        #expect(closeRelative(backHit.v, 0.25))

        // Toque exato em vértice e aresta.
        let vertexRay = try CajuRayQuery(origin: SIMD3<Float>(0, 0, -1), direction: SIMD3<Float>(0, 0, 1))
        let vertexHit = try #require(tri.intersect(ray: vertexRay))
        #expect(closeRelative(vertexHit.t, 1))
        #expect(closeRelative(vertexHit.u, 0))
        #expect(closeRelative(vertexHit.v, 0))

        let edgeRay = try CajuRayQuery(origin: SIMD3<Float>(1, 1, -1), direction: SIMD3<Float>(0, 0, 1))
        let edgeHit = try #require(tri.intersect(ray: edgeRay))
        #expect(closeRelative(edgeHit.u + edgeHit.v, 1))

        // Corte por tMax / tMaxLimit e tMin (incluindo NaN).
        #expect(tri.intersect(ray: frontRay, tMaxLimit: 2.99) == nil)
        #expect(tri.intersect(ray: frontRay, tMaxLimit: 3.0) != nil)
        #expect(tri.intersect(ray: frontRay, tMaxLimit: .nan) == nil)
        let pastOrigin = try CajuRayQuery(
            origin: SIMD3<Float>(0.5, 0.5, 3),
            direction: SIMD3<Float>(0, 0, -1),
            tMin: 3.1,
            tMax: 10
        )
        #expect(tri.intersect(ray: pastOrigin) == nil)

        // Triângulos degenerados nunca geram hit.
        let coincident = CajuTriangle(SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, 1))
        let collinear = CajuTriangle(SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0))
        let testRay = try CajuRayQuery(origin: SIMD3<Float>(1, 0, -1), direction: SIMD3<Float>(0, 0, 1))
        #expect(coincident.intersect(ray: testRay) == nil)
        #expect(collinear.intersect(ray: testRay) == nil)

        // Vértices não finitos.
        let nanTri = CajuTriangle(SIMD3<Float>(.nan, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
        #expect(nanTri.bounds == nil)
        #expect(nanTri.intersect(ray: frontRay) == nil)
    }

    @Test func triangleSATAndSphereVoronoiRegions() throws {
        // Separação apenas pelo eixo normal do plano do triângulo (AABBs se sobrepõem).
        let tilted = CajuTriangle(
            SIMD3<Float>(0, 0, 2),
            SIMD3<Float>(2, 0, 0),
            SIMD3<Float>(0, 2, 0)
        )
        let cornerBox = makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0.5, 0.5))
        #expect(!tilted.overlaps(cornerBox))

        let touchingBox = makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        #expect(tilted.overlaps(touchingBox))

        // AABBs inválidas retornam false em overlaps.
        #expect(!tilted.overlaps(makeAABB(SIMD3<Float>(.nan, 0, 0), SIMD3<Float>(1, 1, 1))))
        #expect(!tilted.overlaps(makeAABB(SIMD3<Float>(2, 0, 0), SIMD3<Float>(1, 1, 1))))

        // Separação por eixo de produto vetorial (arestas inclinadas cruzando sem intersecção).
        let crossTri = CajuTriangle(
            SIMD3<Float>(-1, 1.5, 0.5),
            SIMD3<Float>(1.5, -1, 0.5),
            SIMD3<Float>(1.5, -1, -0.5)
        )
        let centerBox = makeAABB(SIMD3<Float>(-0.2, -0.2, -0.2), SIMD3<Float>(0.2, 0.2, 0.2))
        #expect(!crossTri.overlaps(centerBox))

        // Regiões de Voronoi em closestPoint e overlaps(sphere).
        let tri = CajuTriangle(SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 0, 0), SIMD3<Float>(0, 2, 0))
        #expect(tri.closestPoint(to: SIMD3<Float>(-1, -1, 0)) == SIMD3<Float>(0, 0, 0))
        #expect(tri.closestPoint(to: SIMD3<Float>(3, -1, 0)) == SIMD3<Float>(2, 0, 0))
        #expect(tri.closestPoint(to: SIMD3<Float>(-1, 3, 0)) == SIMD3<Float>(0, 2, 0))
        #expect(tri.closestPoint(to: SIMD3<Float>(1, -1, 0)) == SIMD3<Float>(1, 0, 0))
        #expect(tri.closestPoint(to: SIMD3<Float>(-1, 1, 0)) == SIMD3<Float>(0, 1, 0))
        #expect(tri.closestPoint(to: SIMD3<Float>(2, 2, 0)) == SIMD3<Float>(1, 1, 0))
        #expect(tri.closestPoint(to: SIMD3<Float>(0.5, 0.5, 4)) == SIMD3<Float>(0.5, 0.5, 0))

        #expect(tri.overlaps(makeSphere(SIMD3<Float>(0.5, 0.5, 1), 1)))
        #expect(!tri.overlaps(makeSphere(SIMD3<Float>(0.5, 0.5, 1.01), 1)))
        #expect(tri.overlaps(makeSphere(SIMD3<Float>(0.5, 0.5, 0), 0)))
        #expect(!tri.overlaps(makeSphere(SIMD3<Float>(0.5, 0.5, 0), -1)))
        #expect(!tri.overlaps(makeSphere(SIMD3<Float>(.nan, 0, 0), 1)))

        // Fallback degenerado em closestPoint.
        let deg = CajuTriangle(SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 0, 0), SIMD3<Float>(4, 0, 0))
        #expect(deg.closestPoint(to: SIMD3<Float>(3, 2, 0)) == SIMD3<Float>(3, 0, 0))
    }

    @Test func triangleBVHValidationEmptyAndVariants() throws {
        let empty = CajuTriangleBVH()
        #expect(empty.isEmpty)
        #expect(empty.triangleCount == 0)
        #expect(empty.bounds == nil)
        #expect(empty.triangle(at: 0) == nil)
        #expect(empty.validate())

        let ray = try CajuRayQuery(origin: SIMD3<Float>(0, 0, -5), direction: SIMD3<Float>(0, 0, 1))
        #expect(empty.raycastFirst(ray) == nil)

        var emptyStack = CajuBVHTraversalStack()
        var emptyRayHits: [CajuTriangleBVHHit] = []
        empty.raycastAll(ray, into: &emptyRayHits, stack: &emptyStack)
        #expect(emptyRayHits.isEmpty)

        let emptyQueryBox = makeAABB(SIMD3<Float>(-1, -1, -1), SIMD3<Float>(1, 1, 1))
        var emptyBoxCount = 0
        try empty.query(overlapping: emptyQueryBox) { _ in
            emptyBoxCount += 1
            return true
        }
        #expect(emptyBoxCount == 0)

        var emptySphereCount = 0
        try empty.query(overlapping: makeSphere(.zero, 5)) { _ in
            emptySphereCount += 1
            return true
        }
        #expect(emptySphereCount == 0)

        let builtEmpty = try CajuTriangleBVH(positions: [SIMD3<Float>](), indices: [])
        #expect(builtEmpty.isEmpty)
        #expect(builtEmpty.validate())

        // Validações de entrada inválida.
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            _ = try CajuTriangleBVH(
                positions: [CajuVec3(.nan, 0, 0), CajuVec3(1, 0, 0), CajuVec3(0, 1, 0)],
                indices: [0, 1, 2]
            )
        }
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            _ = try CajuTriangleBVH(
                positions: [SIMD3<Float>(0, .infinity, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                indices: [0, 1, 2]
            )
        }
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            _ = try CajuTriangleBVH(
                packedPositions: [0, 0, -.infinity, 1, 0, 0, 0, 1, 0],
                indices: [0, 1, 2]
            )
        }
        #expect(throws: CajuSpatialError.invalidTriangleIndices) {
            _ = try CajuTriangleBVH(
                packedPositions: [0, 0, 0, 1, 0],
                indices: [0, 1, 2]
            )
        }
        #expect(throws: CajuSpatialError.invalidTriangleIndices) {
            _ = try CajuTriangleBVH(
                positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                indices: [0, 1]
            )
        }
        #expect(throws: CajuSpatialError.invalidTriangleIndices) {
            _ = try CajuTriangleBVH(
                positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                indices: [0, 1, 3]
            )
        }
        #expect(throws: CajuSpatialError.invalidTriangleIndices) {
            _ = try CajuTriangleBVH(
                positions: [SIMD3<Float>](),
                indices: [0, 1, 2]
            )
        }
        #expect(throws: CajuSpatialError.capacityExceeded) {
            _ = try CajuTriangleBVH(
                positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                indices: [0, 1, 2],
                maxCapacity: 0
            )
        }

        // Equivalência entre os 3 construtores (CajuVec3, SIMD3, packedPositions).
        let posVec = [
            CajuVec3(0, 0, 0), CajuVec3(1, 0, 0), CajuVec3(0, 1, 0), CajuVec3(1, 1, 1),
        ]
        let posSIMD = posVec.map(\.storage)
        let packed: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1]
        let indices: [UInt32] = [0, 1, 2, 1, 3, 2]

        let bvhA = try CajuTriangleBVH(positions: posVec, indices: indices)
        let bvhB = try CajuTriangleBVH(positions: posSIMD, indices: indices)
        let bvhC = try CajuTriangleBVH(packedPositions: packed, indices: indices)
        #expect(bvhA.validate())
        #expect(bvhB.validate())
        #expect(bvhC.validate())
        #expect(bvhA.triangleCount == 2)
        #expect(bvhA.triangle(at: 0) == bvhB.triangle(at: 0))
        #expect(bvhA.triangle(at: 1) == bvhC.triangle(at: 1))
        #expect(bvhA.triangle(at: -1) == nil)
        #expect(bvhA.triangle(at: 2) == nil)

        let hitRay = try CajuRayQuery(origin: SIMD3<Float>(0.2, 0.2, -1), direction: SIMD3<Float>(0, 0, 1))
        #expect(bvhA.raycastFirst(hitRay) == bvhB.raycastFirst(hitRay))
        #expect(bvhA.raycastFirst(hitRay) == bvhC.raycastFirst(hitRay))

        // Erros na consulta por esfera e AABB inválida, além de parada antecipada de visitors.
        #expect(throws: CajuSpatialError.nonFiniteBounds) {
            try bvhA.query(overlapping: makeAABB(SIMD3<Float>(.nan, 0, 0), SIMD3<Float>(1, 1, 1))) { _ in
                true
            }
        }
        #expect(throws: CajuSpatialError.invalidBounds) {
            try bvhA.query(overlapping: makeAABB(SIMD3<Float>(2, 0, 0), SIMD3<Float>(1, 1, 1))) { _ in
                true
            }
        }
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            try bvhA.query(overlapping: makeSphere(SIMD3<Float>(.nan, 0, 0), 1)) { _ in true }
        }
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            try bvhA.query(overlapping: makeSphere(.zero, .infinity)) { _ in true }
        }
        #expect(throws: CajuSpatialError.invalidRadius) {
            try bvhA.query(overlapping: makeSphere(.zero, -0.1)) { _ in true }
        }

        // Muitos triângulos idênticos + early-stop em visitors.
        var sameIndices: [UInt32] = []
        for _ in 0..<80 {
            sameIndices.append(contentsOf: [0, 1, 2])
        }
        let identicalBVH = try CajuTriangleBVH(positions: posSIMD, indices: sameIndices)
        #expect(identicalBVH.validate())

        var rayCount = 0
        identicalBVH.raycastAll(hitRay) { _ in
            rayCount += 1
            return false
        }
        #expect(rayCount == 1)

        var overlapCount = 0
        let allBox = makeAABB(SIMD3<Float>(-1, -1, -1), SIMD3<Float>(2, 2, 2))
        try identicalBVH.query(overlapping: allBox) { _ in
            overlapCount += 1
            return false
        }
        #expect(overlapCount == 1)

        var sphereCount = 0
        try identicalBVH.query(overlapping: makeSphere(.zero, 3)) { _ in
            sphereCount += 1
            return false
        }
        #expect(sphereCount == 1)
    }

    @Test func singleTriangleDegenerateOnlyAndDeepMeshQueries() throws {
        // Malha com 1 único triângulo: todas as consultas sem e com stack.
        let singleBVH = try CajuTriangleBVH(
            positions: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(2, 0, 0),
                SIMD3<Float>(0, 2, 0),
            ],
            indices: [0, 1, 2]
        )
        #expect(singleBVH.validate())
        #expect(singleBVH.triangleCount == 1)

        let ray = try CajuRayQuery(origin: SIMD3<Float>(0.5, 0.5, -2), direction: SIMD3<Float>(0, 0, 1))
        let singleFirst = try #require(singleBVH.raycastFirst(ray))
        #expect(singleFirst.triangleIndex == 0)
        #expect(closeRelative(singleFirst.t, 2))

        var singleAll: [UInt32] = []
        singleBVH.raycastAll(ray) { hit in
            singleAll.append(hit.triangleIndex)
            return true
        }
        #expect(singleAll == [0])

        let box = makeAABB(SIMD3<Float>(0, 0, -1), SIMD3<Float>(1, 1, 1))
        var singleBox: [UInt32] = []
        try singleBVH.query(overlapping: box) { idx in
            singleBox.append(idx)
            return true
        }
        #expect(singleBox == [0])

        var singleSphere: [UInt32] = []
        try singleBVH.query(overlapping: makeSphere(SIMD3<Float>(0.5, 0.5, 0.5), 0.6)) { idx in
            singleSphere.append(idx)
            return true
        }
        #expect(singleSphere == [0])

        // Malha contendo apenas triângulos degenerados (colinear e coincidente).
        let degPositions: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0),
            SIMD3<Float>(5, 5, 5), SIMD3<Float>(5, 5, 5), SIMD3<Float>(5, 5, 5),
        ]
        let degBVH = try CajuTriangleBVH(positions: degPositions, indices: [0, 1, 2, 3, 4, 5])
        #expect(degBVH.validate())

        let degRay = try CajuRayQuery(origin: SIMD3<Float>(1, 0, -1), direction: SIMD3<Float>(0, 0, 1))
        #expect(degBVH.raycastFirst(degRay) == nil)
        var degAll: [CajuTriangleBVHHit] = []
        var stack = CajuBVHTraversalStack()
        degBVH.raycastAll(degRay, into: &degAll, stack: &stack)
        #expect(degAll.isEmpty)

        let degQueryBox = makeAABB(SIMD3<Float>(0.5, -0.5, -0.5), SIMD3<Float>(1.5, 0.5, 0.5))
        var degBoxHits: [UInt32] = []
        try degBVH.query(overlapping: degQueryBox, stack: &stack) { idx in
            degBoxHits.append(idx)
            return true
        }
        #expect(degBoxHits == [0])

        var degSphereHits: [UInt32] = []
        try degBVH.query(overlapping: makeSphere(SIMD3<Float>(5, 5, 5), 0.1), stack: &stack) { idx in
            degSphereHits.append(idx)
            return true
        }
        #expect(degSphereHits == [1])
    }

    @Test func triangleBVHRaycastFirstExitSlackRegression() throws {
        // Caso onde AABB plana em z = 1.7 gera tNear = 1.0000001 no slab, acima de tMax = 1.0,
        // mas ainda dentro de aabbTraversalSlack.
        let zPlane: Float = 1.7
        let triPositions = [
            SIMD3<Float>(0, 0, zPlane),
            SIMD3<Float>(1, 0, zPlane),
            SIMD3<Float>(0, 1, zPlane),
        ]
        let bvh = try CajuTriangleBVH(positions: triPositions, indices: [0, 1, 2])
        let dz: Float = 0.7
        let exactT = (zPlane - 1.0) / dz
        let ray = try CajuRayQuery(
            origin: SIMD3<Float>(0.2, 0.2, 1.0),
            direction: SIMD3<Float>(0, 0, dz),
            tMin: 0,
            tMax: exactT
        )
        let tri = try #require(bvh.triangle(at: 0))
        let brute = tri.intersect(ray: ray, twoSided: true)
        let bvhHit = bvh.raycastFirst(ray)
        if let brute {
            let hit = try #require(bvhHit)
            #expect(closeRelative(hit.t, brute.t))
        }
    }

    @Test func triangleIntersectMatchesDoubleOracleFuzz() throws {
        try CajuFuzz.run(seed: 0x7121_0001, iterations: fuzzIterations) { rng, i in
            let v0 = SIMD3<Float>(
                rng.nextFloat(in: -10...10),
                rng.nextFloat(in: -10...10),
                rng.nextFloat(in: -10...10)
            )
            let v1 =
                v0
                + SIMD3<Float>(
                    rng.nextFloat(in: -4...4),
                    rng.nextFloat(in: -4...4),
                    rng.nextFloat(in: -4...4)
                )
            let v2 =
                v0
                + SIMD3<Float>(
                    rng.nextFloat(in: -4...4),
                    rng.nextFloat(in: -4...4),
                    rng.nextFloat(in: -4...4)
                )
            let tri = CajuTriangle(v0, v1, v2)

            let origin = SIMD3<Float>(
                rng.nextFloat(in: -15...15),
                rng.nextFloat(in: -15...15),
                rng.nextFloat(in: -15...15)
            )
            let target =
                (v0 + v1 + v2) / 3.0
                + SIMD3<Float>(
                    rng.nextFloat(in: -3...3),
                    rng.nextFloat(in: -3...3),
                    rng.nextFloat(in: -3...3)
                )
            var dir = target - origin
            if dir == .zero { dir = SIMD3<Float>(0, 0, 1) }
            let ray = try CajuRayQuery(
                origin: origin,
                direction: dir,
                tMin: 0,
                tMax: rng.nextFloat(in: 0.5...5.0)
            )
            let twoSided = (i & 1) == 0

            let oracle = doubleRayTriangle(ray: ray, tri: tri, twoSided: twoSided)
            if oracle.nearBoundary { return }

            let actual = tri.intersect(ray: ray, twoSided: twoSided)
            if oracle.hit {
                let hit = try #require(actual)
                #expect(closeRelative(hit.t, oracle.t))
                #expect(closeRelative(hit.u, oracle.u))
                #expect(closeRelative(hit.v, oracle.v))
            } else {
                #expect(actual == nil)
            }
        }
    }

    @Test func triangleBVHMatchesBruteForceFuzz() throws {
        var bvh = CajuTriangleBVH()
        var triangles: [CajuTriangle] = []
        var stack = CajuBVHTraversalStack()

        try CajuFuzz.run(seed: 0x7121_0002, iterations: fuzzIterations) { rng, i in
            if i % 50 == 0 {
                let triCount = Int(rng.nextUInt32() % 28) + 1
                var positions: [SIMD3<Float>] = []
                var indices: [UInt32] = []
                positions.reserveCapacity(triCount * 3)
                indices.reserveCapacity(triCount * 3)
                triangles.removeAll(keepingCapacity: true)

                for t in 0..<triCount {
                    let base = SIMD3<Float>(
                        rng.nextFloat(in: -20...20),
                        rng.nextFloat(in: -20...20),
                        rng.nextFloat(in: -20...20)
                    )
                    let v0 = base
                    let v1 =
                        base
                        + SIMD3<Float>(
                            rng.nextFloat(in: -3...3),
                            rng.nextFloat(in: -3...3),
                            rng.nextFloat(in: -3...3)
                        )
                    // Ocasionalmente insere triângulo degenerado na malha.
                    let v2 =
                        (t % 11 == 0)
                        ? (v0 + (v1 - v0) * 0.5)
                        : (base
                            + SIMD3<Float>(
                                rng.nextFloat(in: -3...3),
                                rng.nextFloat(in: -3...3),
                                rng.nextFloat(in: -3...3)
                            ))
                    let idxBase = UInt32(positions.count)
                    positions.append(v0)
                    positions.append(v1)
                    positions.append(v2)
                    indices.append(contentsOf: [idxBase, idxBase + 1, idxBase + 2])
                    triangles.append(CajuTriangle(v0, v1, v2))
                }

                bvh = try CajuTriangleBVH(positions: positions, indices: indices)
                #expect(bvh.validate())
            }

            // 1. Raycast first & all vs laço bruto Möller-Trumbore.
            let focus = triangles[Int(rng.nextUInt32()) % triangles.count]
            let centroid = (focus.v0 + focus.v1 + focus.v2) / 3.0
            let origin = SIMD3<Float>(
                rng.nextFloat(in: -25...25),
                rng.nextFloat(in: -25...25),
                rng.nextFloat(in: -25...25)
            )
            var dir =
                (centroid - origin)
                + SIMD3<Float>(
                    rng.nextFloat(in: -4...4),
                    rng.nextFloat(in: -4...4),
                    rng.nextFloat(in: -4...4)
                )
            if dir == .zero { dir = SIMD3<Float>(1, 0, 0) }
            let ray = try CajuRayQuery(
                origin: origin,
                direction: dir,
                tMin: rng.nextUInt32() % 4 == 0 ? rng.nextFloat(in: 0.05...0.5) : 0,
                tMax: rng.nextFloat(in: 1.0...50.0)
            )
            let twoSided = (i & 1) == 0

            var bruteHits: [UInt32: CajuRayTriangleHit] = [:]
            var bruteBestIdx: UInt32?
            var bruteBestHit: CajuRayTriangleHit?
            var bruteSecondT = Float.greatestFiniteMagnitude

            for idx in 0..<triangles.count {
                if let hit = triangles[idx].intersect(ray: ray, twoSided: twoSided) {
                    let triIdx = UInt32(idx)
                    bruteHits[triIdx] = hit
                    if let curBest = bruteBestHit {
                        if hit.t < curBest.t {
                            bruteSecondT = curBest.t
                            bruteBestHit = hit
                            bruteBestIdx = triIdx
                        } else if hit.t < bruteSecondT {
                            bruteSecondT = hit.t
                        }
                    } else {
                        bruteBestHit = hit
                        bruteBestIdx = triIdx
                    }
                }
            }

            var bvhAll: [CajuTriangleBVHHit] = []
            bvh.raycastAll(ray, twoSided: twoSided, into: &bvhAll, stack: &stack)
            #expect(Set(bvhAll.map(\.triangleIndex)) == Set(bruteHits.keys))
            for hit in bvhAll {
                let expected = try #require(bruteHits[hit.triangleIndex])
                #expect(closeRelative(hit.t, expected.t))
                #expect(closeRelative(hit.u, expected.u))
                #expect(closeRelative(hit.v, expected.v))
            }

            let bvhFirst = bvh.raycastFirst(ray, twoSided: twoSided, stack: &stack)
            if let expectedBest = bruteBestHit {
                let actualBest = try #require(bvhFirst)
                #expect(closeRelative(actualBest.t, expectedBest.t))
                if bruteSecondT - expectedBest.t > 1e-4 * max(1, expectedBest.t) {
                    #expect(actualBest.triangleIndex == bruteBestIdx)
                    #expect(closeRelative(actualBest.u, expectedBest.u))
                    #expect(closeRelative(actualBest.v, expectedBest.v))
                }
            } else {
                #expect(bvhFirst == nil)
            }

            // 2. Sobreposição de AABB vs laço bruto.
            let qMin = SIMD3<Float>(
                rng.nextFloat(in: -22...22),
                rng.nextFloat(in: -22...22),
                rng.nextFloat(in: -22...22)
            )
            let qBox = makeAABB(
                qMin,
                qMin
                    + SIMD3<Float>(
                        rng.nextFloat(in: 0.2...6),
                        rng.nextFloat(in: 0.2...6),
                        rng.nextFloat(in: 0.2...6)
                    )
            )
            var expectedBox = Set<UInt32>()
            for idx in 0..<triangles.count where triangles[idx].overlaps(qBox) {
                expectedBox.insert(UInt32(idx))
            }
            var actualBox = Set<UInt32>()
            try bvh.query(overlapping: qBox, stack: &stack) { triIdx in
                actualBox.insert(triIdx)
                return true
            }
            #expect(actualBox == expectedBox)

            // 3. Sobreposição de esfera vs laço bruto.
            let sCenter = SIMD3<Float>(
                rng.nextFloat(in: -22...22),
                rng.nextFloat(in: -22...22),
                rng.nextFloat(in: -22...22)
            )
            let sRadius = rng.nextFloat(in: 0.2...6.0)
            let sphere = makeSphere(sCenter, sRadius)
            var expectedSphere = Set<UInt32>()
            for idx in 0..<triangles.count
            where triangles[idx].overlaps(sphere) {
                expectedSphere.insert(UInt32(idx))
            }
            var actualSphere = Set<UInt32>()
            try bvh.query(overlapping: sphere, stack: &stack) { triIdx in
                actualSphere.insert(triIdx)
                return true
            }
            #expect(actualSphere == expectedSphere)
        }
    }
}
