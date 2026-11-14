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

/// Oráculo independente em precisão dupla (`Double`) para interseção raio-AABB.
private func oracleRayAABB(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    tMin: Float,
    tMax: Float,
    box: CajuAABB
) -> (hit: Bool, nearBoundary: Bool, t: Float) {
    var t0 = Double(tMin)
    var t1 = Double(tMax)
    var nearBoundary = false

    let o = [Double(origin.x), Double(origin.y), Double(origin.z)]
    let d = [Double(direction.x), Double(direction.y), Double(direction.z)]
    let bMin = [Double(box.min.x), Double(box.min.y), Double(box.min.z)]
    let bMax = [Double(box.max.x), Double(box.max.y), Double(box.max.z)]

    for axis in 0..<3 {
        let dir = d[axis]
        if abs(dir) == 0 {
            let eps = 1e-4 * max(1.0, abs(bMin[axis]), abs(bMax[axis]))
            if abs(o[axis] - bMin[axis]) < eps || abs(o[axis] - bMax[axis]) < eps {
                nearBoundary = true
            }
            if o[axis] < bMin[axis] || o[axis] > bMax[axis] {
                return (false, nearBoundary, 0)
            }
        } else {
            let inv = 1.0 / dir
            var near = (bMin[axis] - o[axis]) * inv
            var far = (bMax[axis] - o[axis]) * inv
            if near > far {
                swap(&near, &far)
            }
            t0 = max(t0, near)
            t1 = min(t1, far)
        }
    }

    let boundaryMargin = 1e-4 * max(1.0, abs(t0), abs(t1))
    if abs(t0 - t1) < boundaryMargin {
        nearBoundary = true
    }
    return (t0 <= t1, nearBoundary, Float(t0))
}

@Suite("CajuRayQuery e primitivas")
struct CajuPhysicsSpatialPrimitivesTests {
    @Test func rayQueryValidationAndMathRayConversion() throws {
        let ray = try CajuRayQuery(
            origin: CajuVec3(1, 2, 3),
            direction: CajuVec3(0, 0, 2),
            tMin: 0.5,
            tMax: 10
        )
        #expect(ray.point(at: 2) == SIMD3<Float>(1, 2, 7))
        #expect(ray.inverseDirection.x == .infinity)
        #expect(ray.inverseDirection.y == .infinity)
        #expect(ray.inverseDirection.z == 0.5)

        let mathRay = CajuRay(origin: CajuVec3(1, 2, 3), direction: CajuVec3(0, 0, 2))
        let fromMathRay = try CajuRayQuery(ray: mathRay, tMin: 0.5, tMax: 10)
        #expect(fromMathRay == ray)

        for bad in [Float.nan, .infinity, -.infinity] {
            #expect(throws: CajuSpatialError.nonFiniteRay) {
                _ = try CajuRayQuery(origin: SIMD3<Float>(bad, 0, 0), direction: SIMD3<Float>(1, 0, 0))
            }
            #expect(throws: CajuSpatialError.nonFiniteRay) {
                _ = try CajuRayQuery(origin: .zero, direction: SIMD3<Float>(0, bad, 0))
            }
            #expect(throws: CajuSpatialError.nonFiniteRay) {
                _ = try CajuRayQuery(origin: .zero, direction: SIMD3<Float>(1, 0, 0), tMin: bad)
            }
            #expect(throws: CajuSpatialError.nonFiniteRay) {
                _ = try CajuRayQuery(origin: .zero, direction: SIMD3<Float>(1, 0, 0), tMax: bad)
            }
            #expect(throws: CajuSpatialError.nonFiniteRay) {
                _ = try CajuRayQuery(
                    ray: CajuRay(origin: CajuVec3(bad, 0, 0), direction: CajuVec3(1, 0, 0))
                )
            }
            #expect(throws: CajuSpatialError.nonFiniteRay) {
                _ = try CajuRayQuery(
                    ray: CajuRay(origin: .zero, direction: CajuVec3(0, 0, bad))
                )
            }
        }

        #expect(throws: CajuSpatialError.invalidRayDirection) {
            _ = try CajuRayQuery(origin: .zero, direction: .zero)
        }
        #expect(throws: CajuSpatialError.invalidRayDirection) {
            _ = try CajuRayQuery(ray: CajuRay(origin: .zero, direction: .zero))
        }
        #expect(throws: CajuSpatialError.invalidRayRange) {
            _ = try CajuRayQuery(origin: .zero, direction: SIMD3<Float>(1, 0, 0), tMin: -0.1, tMax: 5)
        }
        #expect(throws: CajuSpatialError.invalidRayRange) {
            _ = try CajuRayQuery(origin: .zero, direction: SIMD3<Float>(1, 0, 0), tMin: 5, tMax: 4)
        }
        #expect(throws: CajuSpatialError.invalidRayRange) {
            _ = try CajuRayQuery(ray: mathRay, tMin: -0.5, tMax: 1)
        }
        #expect(throws: CajuSpatialError.invalidRayRange) {
            _ = try CajuRayQuery(ray: mathRay, tMin: 2, tMax: 1)
        }
        #expect(throws: CajuSpatialError.nonFiniteRay) {
            _ = try CajuRayQuery(origin: CajuVec3(.nan, 0, 0), direction: CajuVec3(1, 0, 0))
        }
        #expect(throws: CajuSpatialError.invalidRayDirection) {
            _ = try CajuRayQuery(origin: CajuVec3(0, 0, 0), direction: CajuVec3(0, 0, 0))
        }
        #expect(throws: CajuSpatialError.invalidRayRange) {
            _ = try CajuRayQuery(origin: CajuVec3(0, 0, 0), direction: CajuVec3(1, 0, 0), tMin: 2, tMax: 1)
        }
    }

    @Test func rayAABBAnalyticalEdgeCasesAndInvalidAABBs() throws {
        let unitBox = makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 2, 2))

        // Origem dentro da caixa -> t == 0 (ou tMin se tMin > 0).
        let insideRay = try CajuRayQuery(origin: SIMD3<Float>(1, 1, 1), direction: SIMD3<Float>(1, 0, 0))
        #expect(insideRay.intersect(unitBox) == 0)

        let insideWithTMin = try CajuRayQuery(
            origin: SIMD3<Float>(1, 1, 1),
            direction: SIMD3<Float>(1, 0, 0),
            tMin: 0.25,
            tMax: 5
        )
        #expect(insideWithTMin.intersect(unitBox) == 0.25)

        // Raio paralelo aos planos (componentes 0 na direção -> 0 * inf = NaN evitado).
        let parallelHit = try CajuRayQuery(origin: SIMD3<Float>(-3, 1, 1), direction: SIMD3<Float>(2, 0, 0))
        #expect(parallelHit.intersect(unitBox) == 1.5)

        let parallelBoundary = try CajuRayQuery(
            origin: SIMD3<Float>(-3, 0, 2),
            direction: SIMD3<Float>(1, 0, 0)
        )
        #expect(parallelBoundary.intersect(unitBox) == 3)

        let parallelMiss = try CajuRayQuery(
            origin: SIMD3<Float>(-3, 2.1, 1),
            direction: SIMD3<Float>(1, 0, 0)
        )
        #expect(parallelMiss.intersect(unitBox) == nil)

        // Raio tocando aresta e canto.
        let edgeRay = try CajuRayQuery(origin: SIMD3<Float>(-2, 0, 0), direction: SIMD3<Float>(1, 0, 0))
        #expect(edgeRay.intersect(unitBox) == 2)

        let diagonalCorner = try CajuRayQuery(
            origin: SIMD3<Float>(-1, -1, -1),
            direction: SIMD3<Float>(1, 1, 1)
        )
        #expect(diagonalCorner.intersect(unitBox) == 1)

        // AABB de volume zero (plano, segmento e ponto).
        let flatBox = makeAABB(SIMD3<Float>(0, 0, 3), SIMD3<Float>(2, 2, 3))
        let perpHit = try CajuRayQuery(origin: SIMD3<Float>(1, 1, 0), direction: SIMD3<Float>(0, 0, 1))
        #expect(perpHit.intersect(flatBox) == 3)

        let coplanarHit = try CajuRayQuery(origin: SIMD3<Float>(-1, 1, 3), direction: SIMD3<Float>(1, 0, 0))
        #expect(coplanarHit.intersect(flatBox) == 1)

        let coplanarMiss = try CajuRayQuery(
            origin: SIMD3<Float>(-1, 1, 3.01),
            direction: SIMD3<Float>(1, 0, 0)
        )
        #expect(coplanarMiss.intersect(flatBox) == nil)

        let segmentBox = makeAABB(SIMD3<Float>(0, 1, 1), SIMD3<Float>(5, 1, 1))
        let toSegment = try CajuRayQuery(origin: SIMD3<Float>(2.5, 1, -1), direction: SIMD3<Float>(0, 0, 1))
        #expect(toSegment.intersect(segmentBox) == 2)

        let pointBox = makeAABB(SIMD3<Float>(3, 4, 5), SIMD3<Float>(3, 4, 5))
        let toPoint = try CajuRayQuery(origin: SIMD3<Float>(0, 4, 5), direction: SIMD3<Float>(1, 0, 0))
        #expect(toPoint.intersect(pointBox) == 3)

        // Corte por tMax e tMaxLimit (incluindo NaN).
        #expect(perpHit.intersect(flatBox, tMaxLimit: 2.99) == nil)
        #expect(perpHit.intersect(flatBox, tMaxLimit: 3.0) == 3)
        #expect(perpHit.intersect(flatBox, tMaxLimit: .nan) == nil)

        // AABB inválida (NaN/inf ou min > max) retorna nil em intersect.
        let nonFiniteBox = makeAABB(SIMD3<Float>(.nan, 0, 0), SIMD3<Float>(1, 1, 1))
        let infBox = makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(.infinity, 1, 1))
        let invertedBox = makeAABB(SIMD3<Float>(2, 0, 0), SIMD3<Float>(1, 1, 1))
        #expect(insideRay.intersect(nonFiniteBox) == nil)
        #expect(insideRay.intersect(infBox) == nil)
        #expect(insideRay.intersect(invertedBox) == nil)

        // Componente subnormal cujo recíproco satura em ±infinity é tratado como paralelo sem NaN.
        let subnormalParallelHit = try CajuRayQuery(
            origin: SIMD3<Float>(-2, 1, 1),
            direction: SIMD3<Float>(1, .leastNonzeroMagnitude, 0)
        )
        #expect(!subnormalParallelHit.inverseDirection.y.isFinite)
        #expect(subnormalParallelHit.intersect(unitBox) == 2)

        let subnormalParallelMiss = try CajuRayQuery(
            origin: SIMD3<Float>(-2, 2.5, 1),
            direction: SIMD3<Float>(1, .leastNonzeroMagnitude, 0)
        )
        #expect(subnormalParallelMiss.intersect(unitBox) == nil)
    }

    @Test func rayAABBMatchesDoubleOracleFuzz() throws {
        try CajuFuzz.run(seed: 0xAA88_0001, iterations: fuzzIterations) { rng, _ in
            let p0 = SIMD3<Float>(
                rng.nextFloat(in: -20...20),
                rng.nextFloat(in: -20...20),
                rng.nextFloat(in: -20...20)
            )
            let size = SIMD3<Float>(
                rng.nextUInt32() % 8 == 0 ? 0 : rng.nextFloat(in: 0.05...8),
                rng.nextUInt32() % 8 == 0 ? 0 : rng.nextFloat(in: 0.05...8),
                rng.nextUInt32() % 8 == 0 ? 0 : rng.nextFloat(in: 0.05...8)
            )
            let box = makeAABB(p0, p0 + size)

            let origin = SIMD3<Float>(
                rng.nextFloat(in: -30...30),
                rng.nextFloat(in: -30...30),
                rng.nextFloat(in: -30...30)
            )
            var dir = SIMD3<Float>(
                rng.nextFloat(in: -4...4),
                rng.nextFloat(in: -4...4),
                rng.nextFloat(in: -4...4)
            )
            // Ocasionalmente força componente exata 0 para exercitar caminho paralelo.
            let zeroMask = rng.nextUInt32() % 10
            if zeroMask == 0 { dir.x = 0 }
            if zeroMask == 1 { dir.y = 0 }
            if zeroMask == 2 { dir.z = 0 }
            if abs(dir.x) < 1e-2 && dir.x != 0 { dir.x = dir.x >= 0 ? 0.5 : -0.5 }
            if abs(dir.y) < 1e-2 && dir.y != 0 { dir.y = dir.y >= 0 ? 0.5 : -0.5 }
            if abs(dir.z) < 1e-2 && dir.z != 0 { dir.z = dir.z >= 0 ? 0.5 : -0.5 }
            if dir == .zero { dir.x = 1 }

            let tMin = rng.nextUInt32() % 4 == 0 ? rng.nextFloat(in: 0.1...5) : 0
            let tMax = tMin + rng.nextFloat(in: 1...80)
            let ray = try CajuRayQuery(
                ray: CajuRay(origin: CajuVec3(storage: origin), direction: CajuVec3(storage: dir)),
                tMin: tMin,
                tMax: tMax
            )

            let oracle = oracleRayAABB(
                origin: origin,
                direction: dir,
                tMin: tMin,
                tMax: tMax,
                box: box
            )
            if oracle.nearBoundary { return }

            let actual = ray.intersect(box)
            if oracle.hit {
                let t = try #require(actual)
                #expect(closeRelative(t, oracle.t))
            } else {
                #expect(actual == nil)
            }
        }
    }
}
