import CajuMath
import CajuPhysicsSpatial
import CajuTesting
import Testing

private let relTolerance: Float = 1e-4

private func close(_ a: Float, _ b: Float) -> Bool {
    abs(a - b) <= relTolerance * max(1, max(abs(a), abs(b)))
}

@Suite("CajuTriangle e CajuTriangleBVH")
struct CajuPhysicsSpatialTriangleTests {
    @Test func triangleValidationAndMollerTrumboreAndDegenerate() throws {
        #expect(throws: CajuSpatialError.nonFiniteVertex) {
            _ = try CajuTriangle(SIMD3(.nan, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
        #expect(throws: CajuSpatialError.nonFiniteVertex) {
            _ = try CajuTriangle(CajuVec3.zero, CajuVec3(1, .infinity, 0), CajuVec3(0, 1, 0))
        }

        let tri = try CajuTriangle(CajuVec3(0, 0, 0), CajuVec3(1, 0, 0), CajuVec3(0, 1, 0))
        let frontRay = try CajuRay(origin: SIMD3(0.25, 0.25, 2), direction: SIMD3(0, 0, -1))
        let frontHit = try #require(tri.intersect(ray: frontRay, twoSided: false))
        #expect(close(frontHit.t, 2))
        #expect(close(frontHit.u, 0.25))
        #expect(close(frontHit.v, 0.25))

        // Face traseira rejeitada quando twoSided = false, aceita quando twoSided = true
        let backRay = try CajuRay(origin: SIMD3(0.25, 0.25, -2), direction: SIMD3(0, 0, 1))
        #expect(tri.intersect(ray: backRay, twoSided: false) == nil)
        let backHit = try #require(tri.intersect(ray: backRay, twoSided: true))
        #expect(close(backHit.t, 2))

        // Raio paralelo ao plano do triângulo
        let parallelRay = try CajuRay(origin: SIMD3(-1, 0.25, 0), direction: SIMD3(1, 0, 0))
        #expect(tri.intersect(ray: parallelRay) == nil)

        // Triângulos degenerados (vértices repetidos ou colineares) nunca geram hit
        let repeated = try CajuTriangle(SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0, 0))
        let collinear = try CajuTriangle(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0))
        let probe = try CajuRay(origin: SIMD3(0.5, 0, 1), direction: SIMD3(0, 0, -1))
        #expect(repeated.intersect(ray: probe) == nil)
        #expect(collinear.intersect(ray: probe) == nil)
    }

    @Test func triangleBVHValidationAndEdgeCases() throws {
        #expect(throws: CajuSpatialError.invalidVertexCoordinateCount(4)) {
            _ = try CajuTriangleBVH(positions: [0, 0, 0, 1], indices: [0, 0, 0])
        }
        #expect(throws: CajuSpatialError.nonFiniteVertex) {
            _ = try CajuTriangleBVH(positions: [0, 0, 0, 1, .nan, 0, 0, 1, 0], indices: [0, 1, 2])
        }
        #expect(throws: CajuSpatialError.invalidTriangleIndexCount(2)) {
            _ = try CajuTriangleBVH(positions: [CajuVec3.zero], indices: [0, 0])
        }
        #expect(throws: CajuSpatialError.invalidTriangleIndex(index: 3, vertexCount: 3)) {
            _ = try CajuTriangleBVH(
                positions: [CajuVec3(0, 0, 0), CajuVec3(1, 0, 0), CajuVec3(0, 1, 0)],
                indices: [0, 1, 3]
            )
        }

        // BVH vazia
        let empty = try CajuTriangleBVH(positions: [CajuVec3](), indices: [])
        #expect(empty.isEmpty)
        #expect(empty.triangleCount == 0)
        #expect(empty.bounds == nil)
        #expect(empty.validate())
        let ray = try CajuRay(origin: SIMD3(0, 0, 1), direction: SIMD3(0, 0, -1))
        #expect(empty.raycastFirst(ray: ray) == nil)

        // Malha com triângulo degenerado + triângulo válido
        let mesh = try CajuTriangleBVH(
            positions: [
                0, 0, 0,
                1, 0, 0,
                2, 0, 0,
                0, 1, 0,
            ],
            indices: [
                0, 1, 2,  // colinear (degenerado)
                0, 1, 3,  // válido em z = 0
            ]
        )
        #expect(mesh.triangleCount == 2)
        #expect(mesh.validate())

        let degRay = try CajuRay(origin: SIMD3(1.5, 0, 1), direction: SIMD3(0, 0, -1))
        #expect(mesh.raycastFirst(ray: degRay) == nil)

        let validRay = try CajuRay(origin: SIMD3(0.2, 0.2, 1), direction: SIMD3(0, 0, -1))
        let hit = try #require(mesh.raycastFirst(ray: validRay))
        #expect(hit.triangleIndex == 1)
        #expect(close(hit.t, 1))

        // Parada antecipada em query e raycastAll na BVH de triângulos
        var stopCount = 0
        mesh.query(overlapping: try CajuAABB(min: SIMD3(-1, -1, -1), max: SIMD3(3, 3, 1))) { _ in
            stopCount += 1
            return false
        }
        #expect(stopCount == 1)
    }

    @Test func fuzzTriangleBVHAgainstBruteForce() throws {
        var rng = CajuPCG32(seed: 0x771A)
        var vertices: [CajuVec3] = []
        var triangles: [CajuTriangle] = []
        var indices: [UInt32] = []

        let triCount = 96
        for i in 0..<triCount {
            let base = CajuVec3(
                rng.nextFloat(in: -15...15),
                rng.nextFloat(in: -15...15),
                rng.nextFloat(in: -15...15)
            )
            let v0 = base
            let v1 =
                base
                + CajuVec3(
                    rng.nextFloat(in: -2...2),
                    rng.nextFloat(in: -2...2),
                    rng.nextFloat(in: -2...2)
                )
            let v2 =
                base
                + CajuVec3(
                    rng.nextFloat(in: -2...2),
                    rng.nextFloat(in: -2...2),
                    rng.nextFloat(in: -2...2)
                )
            vertices.append(v0)
            vertices.append(v1)
            vertices.append(v2)
            triangles.append(try CajuTriangle(v0, v1, v2))
            let b = UInt32(i * 3)
            indices.append(b)
            indices.append(b + 1)
            indices.append(b + 2)
        }

        let bvh = try CajuTriangleBVH(positions: vertices, indices: indices)
        #expect(bvh.triangleCount == triCount)
        #expect(bvh.validate())

        var stack = CajuBVHTraversalStack()
        try CajuFuzz.run(seed: 0x99A1, iterations: 10_000) { fuzzRng, iter in
            let kind = iter % 3
            if kind == 0 {
                let origin = SIMD3(
                    fuzzRng.nextFloat(in: -20...20),
                    fuzzRng.nextFloat(in: -20...20),
                    fuzzRng.nextFloat(in: -20...20)
                )
                var dir = SIMD3(
                    fuzzRng.nextFloat(in: -1...1),
                    fuzzRng.nextFloat(in: -1...1),
                    fuzzRng.nextFloat(in: -1...1)
                )
                if (dir * dir).sum() < 1e-4 {
                    dir = SIMD3(0, 1, 0)
                }
                let ray = try CajuRay(origin: origin, direction: dir, tMin: 0, tMax: 60)
                let twoSided = (iter % 2) == 0

                let gotFirst = bvh.raycastFirst(ray: ray, twoSided: twoSided, stack: &stack)
                var bruteBestT = ray.tMax
                var bruteBestHit: CajuTriangleBVHHit?
                for idx in 0..<triCount {
                    if let h = triangles[idx].intersect(ray: ray, twoSided: twoSided) {
                        if bruteBestHit == nil || h.t < bruteBestT {
                            bruteBestT = h.t
                            bruteBestHit = CajuTriangleBVHHit(
                                triangleIndex: UInt32(idx),
                                t: h.t,
                                u: h.u,
                                v: h.v
                            )
                        }
                    }
                }
                if let brute = bruteBestHit {
                    let got = try #require(gotFirst)
                    #expect(close(got.t, brute.t))
                    if got.triangleIndex == brute.triangleIndex {
                        #expect(close(got.u, brute.u))
                        #expect(close(got.v, brute.v))
                    }
                } else {
                    #expect(gotFirst == nil)
                }

                var bvhAll: Set<UInt32> = []
                bvh.raycastAll(ray: ray, twoSided: twoSided, stack: &stack) { h in
                    bvhAll.insert(h.triangleIndex)
                    return true
                }
                var bruteAll: Set<UInt32> = []
                for idx in 0..<triCount {
                    if triangles[idx].intersect(ray: ray, twoSided: twoSided) != nil {
                        bruteAll.insert(UInt32(idx))
                    }
                }
                #expect(bvhAll == bruteAll)
            } else if kind == 1 {
                let p = SIMD3(
                    fuzzRng.nextFloat(in: -18...18),
                    fuzzRng.nextFloat(in: -18...18),
                    fuzzRng.nextFloat(in: -18...18)
                )
                let size = SIMD3(
                    fuzzRng.nextFloat(in: 0.1...5),
                    fuzzRng.nextFloat(in: 0.1...5),
                    fuzzRng.nextFloat(in: 0.1...5)
                )
                let box = try CajuAABB(min: p, max: p + size)
                var bvhSet: Set<UInt32> = []
                bvh.query(overlapping: box, stack: &stack) { idx in
                    bvhSet.insert(idx)
                    return true
                }
                var bruteSet: Set<UInt32> = []
                for idx in 0..<triCount {
                    if triangles[idx].overlaps(box) {
                        bruteSet.insert(UInt32(idx))
                    }
                }
                #expect(bvhSet == bruteSet)
            } else {
                let center = SIMD3(
                    fuzzRng.nextFloat(in: -18...18),
                    fuzzRng.nextFloat(in: -18...18),
                    fuzzRng.nextFloat(in: -18...18)
                )
                let radius = fuzzRng.nextFloat(in: 0.1...6)
                var bvhSet: Set<UInt32> = []
                try bvh.query(sphereCenter: center, radius: radius, stack: &stack) { idx in
                    bvhSet.insert(idx)
                    return true
                }
                var bruteSet: Set<UInt32> = []
                for idx in 0..<triCount {
                    if triangles[idx].intersects(sphereCenter: center, radius: radius) {
                        bruteSet.insert(UInt32(idx))
                    }
                }
                #expect(bvhSet == bruteSet)
            }
        }
    }
}
