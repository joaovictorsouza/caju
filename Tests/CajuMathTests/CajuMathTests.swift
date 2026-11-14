import CajuMath
import CajuTesting
import Testing

private let tolerance: Float = 1e-5
private let iterations = 10_000

private func randomVec(_ rng: inout CajuPCG32) -> CajuVec3 {
    CajuVec3(
        rng.nextFloat(in: -1...1), rng.nextFloat(in: -1...1), rng.nextFloat(in: -1...1))
}

private func randomQuat(_ rng: inout CajuPCG32) -> CajuQuat {
    let axis = randomVec(&rng)
    let angle = rng.nextFloat(in: -6.28...6.28)
    return CajuQuat(axis: axis, radians: angle) ?? .identity
}

private func close(_ a: CajuVec3, _ b: CajuVec3) -> Bool {
    (a - b).length <= tolerance * max(1, a.length, b.length)
}

@Suite("CajuVec")
struct CajuVecTests {
    @Test func crossIsPerpendicular() {
        CajuFuzz.run(iterations: iterations) { rng, _ in
            let a = randomVec(&rng)
            let b = randomVec(&rng)
            let c = a.cross(b)
            #expect(abs(c.dot(a)) <= tolerance)
            #expect(abs(c.dot(b)) <= tolerance)
        }
    }

    @Test func crossOfAxes() {
        #expect(CajuVec3.unitX.cross(.unitY) == .unitZ)
    }

    @Test func normalizedHasUnitLength() {
        CajuFuzz.run(iterations: iterations) { rng, _ in
            if let n = randomVec(&rng).normalized() {
                #expect(abs(n.length - 1) <= tolerance)
            }
        }
    }

    @Test func normalizedRejectsZeroAndNonFinite() {
        #expect(CajuVec3.zero.normalized() == nil)
        #expect(CajuVec3(.nan, 0, 0).normalized() == nil)
        #expect(CajuVec3(.infinity, 0, 0).normalized() == nil)
    }

    @Test func vec4HelpersAndVec2() {
        let v = CajuVec4(CajuVec3(1, 2, 3), w: 4)
        #expect(v.xyz == CajuVec3(1, 2, 3))
        #expect(v.dot(v) == 30)
        #expect(CajuVec2(3, 4).length == 5)
    }
}

@Suite("CajuQuat")
struct CajuQuatTests {
    @Test func rotationPreservesLength() {
        CajuFuzz.run(iterations: iterations) { rng, _ in
            let q = randomQuat(&rng)
            let v = randomVec(&rng)
            #expect(abs(q.rotate(v).length - v.length) <= tolerance)
        }
    }

    @Test func inverseUndoesRotation() {
        CajuFuzz.run(iterations: iterations) { rng, _ in
            let q = randomQuat(&rng)
            let v = randomVec(&rng)
            #expect(close(q.conjugate.rotate(q.rotate(v)), v))
        }
    }

    @Test func compositionMatchesSequentialRotation() {
        CajuFuzz.run(iterations: iterations) { rng, _ in
            let a = randomQuat(&rng)
            let b = randomQuat(&rng)
            let v = randomVec(&rng)
            #expect(close((a * b).rotate(v), a.rotate(b.rotate(v))))
        }
    }

    @Test func quarterTurnAroundZ() throws {
        let q = try #require(CajuQuat(axis: .unitZ, radians: .pi / 2))
        #expect(close(q.rotate(.unitX), .unitY))
    }

    @Test func zeroAxisIsRejected() {
        #expect(CajuQuat(axis: .zero, radians: 1) == nil)
    }
}

@Suite("CajuMat4")
struct CajuMat4Tests {
    @Test func identityIsNeutral() {
        CajuFuzz.run(iterations: iterations) { rng, _ in
            let p = randomVec(&rng)
            #expect(CajuMat4.identity.transformPoint(p) == p)
        }
    }

    @Test func rotationMatrixMatchesQuaternion() {
        CajuFuzz.run(iterations: iterations) { rng, _ in
            let q = randomQuat(&rng)
            let p = randomVec(&rng)
            #expect(close(CajuMat4.rotation(q).transformPoint(p), q.rotate(p)))
        }
    }

    @Test func multiplicationComposesTransforms() {
        CajuFuzz.run(iterations: iterations) { rng, _ in
            let t = CajuMat4.translation(randomVec(&rng))
            let r = CajuMat4.rotation(randomQuat(&rng))
            let s = CajuMat4.scale(randomVec(&rng))
            let p = randomVec(&rng)
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
}
