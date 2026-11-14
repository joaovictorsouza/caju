import CajuMath
import CajuTesting
import Testing

@Suite("CajuIntersect")
struct CajuIntersectTests {
    @Test func rayVsAABB() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let c = randomVec3(&rng, in: -5...5)
            let ext = CajuVec3(
                rng.nextFloat(in: 0.5...2),
                rng.nextFloat(in: 0.5...2),
                rng.nextFloat(in: 0.5...2)
            )
            let box = CajuAABB(center: c, extents: ext)

            // Raio externo apontando para dentro da caixa
            let target = CajuVec3(
                rng.nextFloat(in: (box.min.x + 0.05)...(box.max.x - 0.05)),
                rng.nextFloat(in: (box.min.y + 0.05)...(box.max.y - 0.05)),
                rng.nextFloat(in: (box.min.z + 0.05)...(box.max.z - 0.05))
            )
            let dir = randomUnitVec3(&rng)
            let origin = target - dir * 10
            let ray = CajuRay(origin: origin, direction: dir)
            if let t = ray.intersects(box) {
                let hit = ray.point(at: t)
                let distToFaces = min(
                    min(abs(hit.x - box.min.x), abs(hit.x - box.max.x)),
                    min(
                        min(abs(hit.y - box.min.y), abs(hit.y - box.max.y)),
                        min(abs(hit.z - box.min.z), abs(hit.z - box.max.z))
                    )
                )
                #expect(distToFaces <= testTolerance * max(1, hit.length))
                #expect(box.contains(hit.clamp(min: box.min, max: box.max)))
            } else {
                Issue.record("Raio apontando para AABB deveria acertar")
            }

            // Raio de dentro da caixa sai na superfície
            let insideRay = CajuRay(origin: target, direction: dir)
            if let tOut = insideRay.intersects(box) {
                #expect(tOut >= 0)
                let hitOut = insideRay.point(at: tOut)
                let distToFaces = min(
                    min(abs(hitOut.x - box.min.x), abs(hitOut.x - box.max.x)),
                    min(
                        min(abs(hitOut.y - box.min.y), abs(hitOut.y - box.max.y)),
                        min(abs(hitOut.z - box.min.z), abs(hitOut.z - box.max.z))
                    )
                )
                #expect(distToFaces <= testTolerance * max(1, hitOut.length))
            } else {
                Issue.record("Raio de dentro da AABB deveria atingir a superfície de saída")
            }

            // Miss apontando para trás
            let missRay = CajuRay(origin: target + dir * 10, direction: dir)
            #expect(missRay.intersects(box) == nil)
        }

        // Componentes zero na direção (incluindo deslizando exatamente sobre a face)
        let box = CajuAABB(min: CajuVec3(0, 0, 0), max: CajuVec3(2, 2, 2))
        let axisRay = CajuRay(origin: CajuVec3(0, 1, -3), direction: CajuVec3(0, 0, 1))
        #expect(axisRay.intersects(box) == 3)
        let missParallel = CajuRay(origin: CajuVec3(3, 1, -3), direction: CajuVec3(0, 0, 1))
        #expect(missParallel.intersects(box) == nil)
        #expect(CajuRay(origin: .zero, normalizingDirection: .zero) == nil)
        #expect(CajuRay(origin: .zero, direction: .zero).intersects(box) == nil)
    }

    @Test func rayVsSphere() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let center = randomVec3(&rng, in: -5...5)
            let radius = rng.nextFloat(in: 0.5...3)
            let sphere = CajuSphere(center: center, radius: radius)
            let target = center + randomUnitVec3(&rng) * (radius * 0.5)
            let dir = randomUnitVec3(&rng)

            let outsideRay = CajuRay(origin: target - dir * 10, direction: dir)
            if let t = outsideRay.intersects(sphere) {
                let hit = outsideRay.point(at: t)
                #expect(close((hit - center).length, radius))
            } else {
                Issue.record("Raio deveria atingir esfera")
            }

            let insideRay = CajuRay(origin: target, direction: dir)
            if let tIn = insideRay.intersects(sphere) {
                #expect(tIn >= 0)
                let hit = insideRay.point(at: tIn)
                #expect(close((hit - center).length, radius))
            } else {
                Issue.record("Raio de dentro da esfera deveria sair na superfície")
            }

            let missRay = CajuRay(origin: center + dir * (radius + 1), direction: dir)
            #expect(missRay.intersects(sphere) == nil)
        }

        // Tangente e paralelo/miss
        let s = CajuSphere(center: .zero, radius: 1)
        let tangent = CajuRay(origin: CajuVec3(1, 0, -5), direction: CajuVec3(0, 0, 1))
        if let t = tangent.intersects(s) {
            #expect(close(t, 5))
        }
        #expect(CajuRay(origin: CajuVec3(2, 0, -5), direction: CajuVec3(0, 0, 1)).intersects(s) == nil)
        #expect(
            CajuRay(origin: .zero, direction: .unitX).intersects(CajuSphere(center: .zero, radius: -1)) == nil
        )
    }

    @Test func rayVsPlane() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let p0 = randomVec3(&rng, in: -5...5)
            let n = randomUnitVec3(&rng)
            guard let plane = CajuPlane(normal: n, point: p0) else {
                Issue.record("Plano válido falhou")
                return
            }

            let dir = randomUnitVec3(&rng)
            let denom = n.dot(dir)
            if abs(denom) > 0.05 {
                let target = p0 + (dir.cross(n).normalized() ?? .unitX) * rng.nextFloat(in: -2...2)
                let dist = rng.nextFloat(in: 0.5...10)
                let ray = CajuRay(origin: target - dir * dist, direction: dir)
                if let t = ray.intersects(plane) {
                    let hit = ray.point(at: t)
                    #expect(abs(plane.signedDistance(to: hit)) <= testTolerance * max(1, hit.length))
                } else {
                    Issue.record("Raio não paralelo deveria atingir plano")
                }
            }

            // Raio paralelo ao plano
            if let basis = n.orthonormalBasis() {
                let parallel = CajuRay(origin: p0 + n, direction: basis.tangent)
                #expect(parallel.intersects(plane) == nil)
            }
        }
    }

    @Test func rayVsTriangle() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let a = randomVec3(&rng, in: -3...3)
            let b =
                a + CajuVec3(rng.nextFloat(in: 0.5...2), rng.nextFloat(in: -1...1), rng.nextFloat(in: -1...1))
            let c =
                a + CajuVec3(rng.nextFloat(in: -1...1), rng.nextFloat(in: 0.5...2), rng.nextFloat(in: -1...1))
            let normal = (b - a).cross(c - a)
            guard normal.length > 0.1, let unitN = normal.normalized() else { return }

            let w1 = rng.nextFloat(in: 0.05...0.45)
            let w2 = rng.nextFloat(in: 0.05...0.45)
            let w0 = 1 - w1 - w2
            let pointOnTri = a * w0 + b * w1 + c * w2

            // Frente -> hit com culling e sem culling
            let frontRay = CajuRay(origin: pointOnTri + unitN * 3, direction: -unitN)
            if let hit = frontRay.intersectsTriangle(a, b, c, backfaceCulling: true) {
                #expect(close(hit.u, w1))
                #expect(close(hit.v, w2))
                let recon = a * (1 - hit.u - hit.v) + b * hit.u + c * hit.v
                #expect(close(frontRay.point(at: hit.t), recon))
            } else {
                Issue.record("Raio frontal deveria acertar triângulo")
            }

            // Costas -> nil com culling, hit sem culling
            let backRay = CajuRay(origin: pointOnTri - unitN * 3, direction: unitN)
            #expect(backRay.intersectsTriangle(a, b, c, backfaceCulling: true) == nil)
            if let backHit = backRay.intersectsTriangle(a, b, c, backfaceCulling: false) {
                #expect(close(backHit.u, w1))
                #expect(close(backHit.v, w2))
            } else {
                Issue.record("Raio traseiro sem culling deveria acertar triângulo")
            }

            // Paralelo e fora do triângulo
            if let dirParallel = (b - a).normalized() {
                #expect(
                    CajuRay(origin: pointOnTri + unitN, direction: dirParallel).intersectsTriangle(a, b, c)
                        == nil)
            }
            let outsidePoint = a - (b - a) - (c - a)
            #expect(
                CajuRay(origin: outsidePoint + unitN * 3, direction: -unitN).intersectsTriangle(a, b, c)
                    == nil)
        }
    }

    @Test func primitiveSymmetryAndTransforms() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let a1 = CajuAABB(center: randomVec3(&rng, in: -3...3), extents: randomVec3(&rng, in: 0.2...2))
            let a2 = CajuAABB(center: randomVec3(&rng, in: -3...3), extents: randomVec3(&rng, in: 0.2...2))
            #expect(a1.intersects(a2) == a2.intersects(a1))

            let s1 = CajuSphere(center: randomVec3(&rng, in: -3...3), radius: rng.nextFloat(in: 0.2...2))
            let s2 = CajuSphere(center: randomVec3(&rng, in: -3...3), radius: rng.nextFloat(in: 0.2...2))
            #expect(s1.intersects(s2) == s2.intersects(s1))
            #expect(s1.intersects(a1) == a1.intersects(s1))

            if let plane = CajuPlane(normal: randomUnitVec3(&rng), point: randomVec3(&rng, in: -2...2)) {
                #expect(a1.intersects(plane) == (plane.classify(a1) == .intersecting))
                #expect(s1.intersects(plane) == (plane.classify(s1) == .intersecting))
                let cp = plane.closestPoint(to: s1.center)
                #expect(abs(plane.signedDistance(to: cp)) <= testTolerance * max(1, cp.length))
            }

            let m = CajuMat4(
                translation: randomVec3(&rng, in: -5...5),
                rotation: randomQuat(&rng),
                scale: randomVec3(&rng, in: 0.5...2)
            )
            let ta = a1.transformed(by: m)
            let corners = [
                CajuVec3(a1.min.x, a1.min.y, a1.min.z),
                CajuVec3(a1.max.x, a1.min.y, a1.min.z),
                CajuVec3(a1.min.x, a1.max.y, a1.min.z),
                CajuVec3(a1.max.x, a1.max.y, a1.min.z),
                CajuVec3(a1.min.x, a1.min.y, a1.max.z),
                CajuVec3(a1.max.x, a1.min.y, a1.max.z),
                CajuVec3(a1.min.x, a1.max.y, a1.max.z),
                CajuVec3(a1.max.x, a1.max.y, a1.max.z),
            ]
            var expected = CajuAABB(min: m.transformPoint(corners[0]), max: m.transformPoint(corners[0]))
            for corner in corners.dropFirst() {
                expected = expected.union(m.transformPoint(corner))
            }
            #expect(close(ta.min, expected.min))
            #expect(close(ta.max, expected.max))
        }
    }

    @Test func frustumContainsAndIntersects() throws {
        let view = try #require(
            CajuMat4.lookAt(eye: CajuVec3(0, 0, 5), target: .zero, up: .unitY))
        let proj = try #require(
            CajuMat4.perspective(fovY: .pi / 3, aspect: 1.5, near: 1, far: 20))
        let vp = proj * view
        let invVP = try #require(vp.inverse)
        let frustum = try #require(CajuFrustum(viewProjection: vp))

        CajuFuzz.run(iterations: testIterations) { rng, _ in
            // Ponto em NDC dentro [-0.9, 0.9] × [-0.9, 0.9] × [0.05, 0.95] -> dentro do frustum
            let ndcIn = CajuVec4(
                rng.nextFloat(in: -0.9...0.9),
                rng.nextFloat(in: -0.9...0.9),
                rng.nextFloat(in: 0.05...0.95),
                1
            )
            let worldInH = invVP * ndcIn
            let worldIn = worldInH.xyz / worldInH.w
            #expect(frustum.contains(worldIn))
            let smallSphere = CajuSphere(center: worldIn, radius: 0.01)
            #expect(frustum.intersects(smallSphere))
            let smallBox = CajuAABB(center: worldIn, extents: CajuVec3(repeating: 0.01))
            #expect(frustum.intersects(smallBox))

            // Ponto atrás da câmera (z = 10 no mundo) -> fora do frustum
            let behind = CajuVec3(rng.nextFloat(in: -5...5), rng.nextFloat(in: -5...5), 10)
            #expect(!frustum.contains(behind))
            #expect(!frustum.intersects(CajuSphere(center: behind, radius: 0.5)))
            #expect(!frustum.intersects(CajuAABB(center: behind, extents: CajuVec3(repeating: 0.5))))
        }

        let centerSphere = CajuSphere(center: CajuVec3(0, 0, -2), radius: 0.5)
        #expect(frustum.contains(centerSphere))
        #expect(frustum.contains(CajuAABB(center: CajuVec3(0, 0, -2), extents: CajuVec3(repeating: 0.5))))
        #expect(
            CajuFrustum(viewProjection: CajuMat4(columns: SIMD4(.nan, 0, 0, 0), .zero, .zero, .zero)) == nil)
    }
}
