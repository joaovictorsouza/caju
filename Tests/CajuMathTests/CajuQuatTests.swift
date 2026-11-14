import CajuMath
import CajuTesting
import Testing

@Suite("CajuQuat")
struct CajuQuatTests {
    @Test func rotationPreservesLength() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let q = randomQuat(&rng)
            let v = randomVec3(&rng)
            #expect(abs(q.rotate(v).length - v.length) <= testTolerance)
        }
    }

    @Test func inverseUndoesRotation() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let q = randomQuat(&rng)
            let v = randomVec3(&rng)
            #expect(close(q.conjugate.rotate(q.rotate(v)), v))
            let scaled = CajuQuat(
                x: q.x * 2.5, y: q.y * 2.5, z: q.z * 2.5, w: q.w * 2.5
            )
            if let inv = scaled.inverse {
                #expect(closeQuat(scaled * inv, .identity))
            } else {
                Issue.record("Inverso de quaternion não nulo falhou")
            }
        }
        #expect(CajuQuat(x: 0, y: 0, z: 0, w: 0).inverse == nil)
        #expect(CajuQuat(x: .nan, y: 0, z: 0, w: 1).inverse == nil)
    }

    @Test func compositionMatchesSequentialRotation() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let a = randomQuat(&rng)
            let b = randomQuat(&rng)
            let v = randomVec3(&rng)
            #expect(close((a * b).rotate(v), a.rotate(b.rotate(v))))
        }
    }

    @Test func quarterTurnAroundZ() throws {
        let q = try #require(CajuQuat(axis: .unitZ, radians: .pi / 2))
        #expect(close(q.rotate(.unitX), .unitY))
    }

    @Test func zeroAxisIsRejected() {
        #expect(CajuQuat(axis: .zero, radians: 1) == nil)
        #expect(CajuQuat(axis: .unitX, radians: .nan) == nil)
    }

    @Test func axisAngleRoundTrip() {
        let id = CajuQuat.identity.toAxisAngle()
        #expect(id.axis == .unitX)
        #expect(id.radians == 0)

        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let q = randomQuat(&rng)
            let aa = q.toAxisAngle()
            if let reconstructed = CajuQuat(axis: aa.axis, radians: aa.radians) {
                #expect(closeQuat(reconstructed, q))
            } else {
                Issue.record("Falha ao reconstruir quaternion de axis-angle")
            }
        }
    }

    @Test func matrixRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let q = randomQuat(&rng)
            let m = CajuMat4.rotation(q)
            if let back = CajuQuat(matrix: m) {
                #expect(closeQuat(back, q))
            } else {
                Issue.record("Falha ao reconstruir quaternion da matriz")
            }
        }

        // Testa os 4 ramos da diagonal (identidade e rotações de 180° em X, Y, Z)
        for axis in [CajuVec3.unitX, .unitY, .unitZ] {
            if let q = CajuQuat(axis: axis, radians: .pi),
                let back = CajuQuat(matrix: CajuMat4.rotation(q))
            {
                #expect(closeQuat(back, q))
            }
        }
        #expect(CajuQuat(matrix: CajuMat4(columns: SIMD4(.nan, 0, 0, 0), .zero, .zero, .zero)) == nil)
    }

    @Test func eulerAnglesRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let yaw = rng.nextFloat(in: -.pi...(.pi))
            let pitch = rng.nextFloat(in: -1.4...1.4)
            let roll = rng.nextFloat(in: -.pi...(.pi))
            let q = CajuQuat(yaw: yaw, pitch: pitch, roll: roll)
            let e = q.eulerAngles
            let back = CajuQuat(yaw: e.yaw, pitch: e.pitch, roll: e.roll)
            #expect(closeQuat(back, q))
        }

        // Gimbal lock
        for sign: Float in [-1, 1] {
            let q = CajuQuat(yaw: 0.7, pitch: sign * (.pi * 0.5), roll: -0.4)
            let e = q.eulerAngles
            let back = CajuQuat(yaw: e.yaw, pitch: e.pitch, roll: e.roll)
            #expect(closeQuat(back, q))
        }
    }

    @Test func slerpAndNlerpProperties() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let a = randomQuat(&rng)
            var b = randomQuat(&rng)
            if rng.nextUInt32() & 1 == 0 {
                b = CajuQuat(x: -b.x, y: -b.y, z: -b.z, w: -b.w)
            }
            #expect(closeQuat(CajuQuat.slerp(a, b, t: 0), a))
            #expect(closeQuat(CajuQuat.slerp(a, b, t: 1), b))
            #expect(closeQuat(CajuQuat.nlerp(a, b, t: 0), a))
            #expect(closeQuat(CajuQuat.nlerp(a, b, t: 1), b))

            let t = rng.nextFloat(in: 0...1)
            let s = CajuQuat.slerp(a, b, t: t)
            let n = CajuQuat.nlerp(a, b, t: t)
            #expect(close(s.dot(s), 1))
            #expect(close(n.dot(n), 1))

            if let totalAngle = a.angle(to: b), let partialAngle = a.angle(to: s) {
                #expect(close(partialAngle, t * totalAngle))
            }
        }
    }

    @Test func fromToAndLookRotation() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let a = randomUnitVec3(&rng)
            let b = randomUnitVec3(&rng)
            if let q = CajuQuat(from: a, to: b) {
                #expect(close(q.rotate(a), b))
            } else {
                Issue.record("Falha em init(from:to:)")
            }

            if let anti = CajuQuat(from: a, to: -a) {
                #expect(close(anti.rotate(a), -a))
            } else {
                Issue.record("Falha em init(from:to:) antiparalelo")
            }

            let forward = randomUnitVec3(&rng)
            let up = randomUnitVec3(&rng)
            if abs(forward.dot(up)) < 0.99 {
                if let look = CajuQuat.lookRotation(forward: forward, up: up) {
                    #expect(close(look.rotate(-CajuVec3.unitZ), forward))
                } else {
                    Issue.record("Falha em lookRotation")
                }
            }
        }
        #expect(CajuQuat(from: .zero, to: .unitX) == nil)
        #expect(CajuQuat(from: .unitX, to: .nan * .unitX) == nil)
        #expect(CajuQuat.lookRotation(forward: .zero, up: .unitY) == nil)
        #expect(CajuQuat.lookRotation(forward: .unitY, up: .unitY) == nil)
    }
}
