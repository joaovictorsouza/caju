import CajuMath
import CajuTesting
import Testing

@Suite("CajuMat4")
struct CajuMat4Tests {
    @Test func identityIsNeutral() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let p = randomVec3(&rng)
            #expect(CajuMat4.identity.transformPoint(p) == p)
        }
    }

    @Test func rotationMatrixMatchesQuaternion() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let q = randomQuat(&rng)
            let p = randomVec3(&rng)
            #expect(close(CajuMat4.rotation(q).transformPoint(p), q.rotate(p)))
        }
    }

    @Test func multiplicationComposesTransforms() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let t = CajuMat4.translation(randomVec3(&rng))
            let r = CajuMat4.rotation(randomQuat(&rng))
            let s = CajuMat4.scale(randomVec3(&rng))
            let p = randomVec3(&rng)
            let combined = (t * r * s).transformPoint(p)
            let stepwise = t.transformPoint(r.transformPoint(s.transformPoint(p)))
            #expect(close(combined, stepwise))
        }
    }

    @Test func transposeIsInvolution() {
        let m = CajuMat4(
            columns: SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12),
            SIMD4(13, 14, 15, 16))
        #expect(m.transposed.transposed == m)
        #expect(m.transposed.c0 == SIMD4(1, 5, 9, 13))
    }

    @Test func inverseAndInverseAffineOnTRS() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let t = randomVec3(&rng, in: -10...10)
            let r = randomQuat(&rng)
            let s = CajuVec3(
                rng.nextFloat(in: 0.25...4),
                rng.nextFloat(in: 0.25...4),
                rng.nextFloat(in: 0.25...4)
            )
            let m = CajuMat4(translation: t, rotation: r, scale: s)
            #expect(close(m.determinant, s.x * s.y * s.z))

            guard let inv = m.inverse, let invAff = m.inverseAffine else {
                Issue.record("Inversa de TRS bem condicionada falhou")
                return
            }
            #expect(closeMat(m * inv, .identity))
            #expect(closeMat(inv * m, .identity))
            #expect(closeMat(inv, invAff))
        }

        // Singular e não finito
        #expect(CajuMat4.scale(.zero).inverse == nil)
        #expect(CajuMat4.scale(.zero).inverseAffine == nil)
        let singular = CajuMat4(
            columns: SIMD4(1, 2, 3, 4), SIMD4(2, 4, 6, 8), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        #expect(singular.inverse == nil)
        let nonFinite = CajuMat4(columns: SIMD4(.nan, 0, 0, 0), .zero, .zero, SIMD4(0, 0, 0, 1))
        #expect(nonFinite.inverse == nil)
        #expect(nonFinite.inverseAffine == nil)
        #expect(!nonFinite.isFinite)
    }

    @Test func decomposeComposeRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let t = randomVec3(&rng, in: -10...10)
            let r = randomQuat(&rng)
            let sxSign: Float = (rng.nextUInt32() & 1 == 0) ? 1 : -1
            let s = CajuVec3(
                sxSign * rng.nextFloat(in: 0.25...4),
                rng.nextFloat(in: 0.25...4),
                rng.nextFloat(in: 0.25...4)
            )
            let m = CajuMat4(translation: t, rotation: r, scale: s)
            guard let d = m.decompose() else {
                Issue.record("Decomposição TRS falhou")
                return
            }
            #expect(close(d.translation, t))
            #expect(close(d.scale, s))
            #expect(closeQuat(d.rotation, r))
            let recomposed = CajuMat4(translation: d.translation, rotation: d.rotation, scale: d.scale)
            #expect(closeMat(recomposed, m))
        }

        #expect(CajuMat4.scale(.zero).decompose() == nil)
        #expect(CajuMat4(columns: SIMD4(.nan, 0, 0, 0), .zero, .zero, SIMD4(0, 0, 0, 1)).decompose() == nil)
    }

    @Test func lookAtPerspectiveOrthographicAndDirection() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let eye = randomVec3(&rng, in: -10...10)
            let forward = randomUnitVec3(&rng)
            let target = eye + forward * rng.nextFloat(in: 1...10)
            let up = randomUnitVec3(&rng)
            if abs(forward.dot(up)) < 0.95,
                let view = CajuMat4.lookAt(eye: eye, target: target, up: up)
            {
                #expect(close(view.transformPoint(eye), .zero))
                #expect(close(view.transformDirection(forward), -CajuVec3.unitZ))
                if let inv = view.inverse {
                    #expect(closeMat(view * inv, .identity))
                }
            }

            let fov = rng.nextFloat(in: 0.3...2.2)
            let aspect = rng.nextFloat(in: 0.5...2.5)
            let near = rng.nextFloat(in: 0.2...2.0)
            let far = near + rng.nextFloat(in: 2...20)
            if let proj = CajuMat4.perspective(fovY: fov, aspect: aspect, near: near, far: far) {
                let pNear = proj * CajuVec4(0, 0, -near, 1)
                let pFar = proj * CajuVec4(0, 0, -far, 1)
                #expect(close(pNear.z / pNear.w, 0))
                #expect(close(pFar.z / pFar.w, 1))
                #expect(proj.inverseAffine == nil)
                if let invP = proj.inverse {
                    #expect(closeMat(proj * invP, .identity))
                }
            } else {
                Issue.record("Perspective válida retornou nil")
            }

            if let ortho = CajuMat4.orthographic(
                left: -5, right: 5, bottom: -3, top: 3, near: near, far: far)
            {
                let pNear = ortho * CajuVec4(0, 0, -near, 1)
                let pFar = ortho * CajuVec4(0, 0, -far, 1)
                #expect(close(pNear.z, 0))
                #expect(close(pFar.z, 1))
            }
        }

        #expect(CajuMat4.lookAt(eye: .zero, target: .zero, up: .unitY) == nil)
        #expect(CajuMat4.lookAt(eye: .zero, target: .unitY, up: .unitY) == nil)
        #expect(CajuMat4.perspective(fovY: 0, aspect: 1, near: 0.1, far: 10) == nil)
        #expect(CajuMat4.perspective(fovY: .pi, aspect: 1, near: 0.1, far: 10) == nil)
        #expect(CajuMat4.perspective(fovY: 1, aspect: 0, near: 0.1, far: 10) == nil)
        #expect(CajuMat4.perspective(fovY: 1, aspect: 1, near: 0, far: 10) == nil)
        #expect(CajuMat4.perspective(fovY: 1, aspect: 1, near: 10, far: 5) == nil)
        #expect(CajuMat4.orthographic(left: 1, right: 1, bottom: 0, top: 1, near: 0, far: 1) == nil)
        #expect(CajuMat4.orthographic(left: 0, right: 1, bottom: 1, top: 1, near: 0, far: 1) == nil)
        #expect(CajuMat4.orthographic(left: 0, right: 1, bottom: 0, top: 1, near: 2, far: 1) == nil)
    }
}
