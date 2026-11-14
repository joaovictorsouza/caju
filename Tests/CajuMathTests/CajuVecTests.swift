import CajuMath
import CajuTesting
import Testing

@Suite("CajuVec")
struct CajuVecTests {
    @Test func crossIsPerpendicular() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let a = randomVec3(&rng)
            let b = randomVec3(&rng)
            let c = a.cross(b)
            #expect(abs(c.dot(a)) <= testTolerance)
            #expect(abs(c.dot(b)) <= testTolerance)
        }
    }

    @Test func crossOfAxes() {
        #expect(CajuVec3.unitX.cross(.unitY) == .unitZ)
    }

    @Test func normalizedHasUnitLength() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            if let n = randomVec3(&rng).normalized() {
                #expect(abs(n.length - 1) <= testTolerance)
            }
            if let n2 = randomVec2(&rng).normalized() {
                #expect(abs(n2.length - 1) <= testTolerance)
            }
            if let n4 = randomVec4(&rng).normalized() {
                #expect(abs(n4.length - 1) <= testTolerance)
            }
        }
    }

    @Test func normalizedRejectsZeroAndNonFinite() {
        #expect(CajuVec2.zero.normalized() == nil)
        #expect(CajuVec2(.nan, 0).normalized() == nil)
        #expect(CajuVec2(.infinity, 0).normalized() == nil)
        #expect(CajuVec3.zero.normalized() == nil)
        #expect(CajuVec3(.nan, 0, 0).normalized() == nil)
        #expect(CajuVec3(.infinity, 0, 0).normalized() == nil)
        #expect(CajuVec4.zero.normalized() == nil)
        #expect(CajuVec4(.nan, 0, 0, 0).normalized() == nil)
        #expect(CajuVec4(.infinity, 0, 0, 0).normalized() == nil)
    }

    @Test func vec4HelpersAndVec2() {
        let v = CajuVec4(CajuVec3(1, 2, 3), w: 4)
        #expect(v.xyz == CajuVec3(1, 2, 3))
        #expect(v.xy == CajuVec2(1, 2))
        #expect(v.dot(v) == 30)
        #expect(CajuVec2(3, 4).length == 5)
        #expect(CajuVec3(CajuVec2(1, 2), z: 3) == CajuVec3(1, 2, 3))
        #expect(CajuVec3(1, 2, 3).xy == CajuVec2(1, 2))
        #expect(CajuVec4(CajuVec2(1, 2), z: 3, w: 4) == v)
    }

    @Test func arithmeticAndComponentOps() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            var a = randomVec3(&rng, in: -10...10)
            let b = randomVec3(&rng, in: 1...10)
            let orig = a
            a += b
            a -= b
            #expect(close(a, orig))
            a *= 2
            a /= 2
            #expect(close(a, orig))
            #expect(close(CajuVec3.min(a, b) + CajuVec3.max(a, b), a + b))
            let clamped = a.clamp(min: -b, max: b)
            #expect(clamped.x >= -b.x && clamped.x <= b.x)
            #expect(clamped.y >= -b.y && clamped.y <= b.y)
            #expect(clamped.z >= -b.z && clamped.z <= b.z)

            let f = a.floor
            let c = a.ceil
            #expect(f.x <= a.x && a.x <= c.x)
            #expect(a.abs.x >= 0 && a.abs.y >= 0 && a.abs.z >= 0)
        }
        #expect(CajuVec2(repeating: 3) == CajuVec2(3, 3))
        #expect(CajuVec3(repeating: 3) == CajuVec3(3, 3, 3))
        #expect(CajuVec4(repeating: 3) == CajuVec4(3, 3, 3, 3))
        #expect(-CajuVec4(1, -2, 3, -4) == CajuVec4(-1, 2, -3, 4))
        #expect(2 * CajuVec2(1, 2) == CajuVec2(2, 4))
        #expect(2 * CajuVec3(1, 2, 3) == CajuVec3(2, 4, 6))
        #expect(2 * CajuVec4(1, 2, 3, 4) == CajuVec4(2, 4, 6, 8))
    }

    @Test func distanceReflectProjectAndAngle() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let v = randomVec3(&rng, in: -5...5)
            let n = randomUnitVec3(&rng)
            let r = v.reflect(normal: n)
            #expect(close(r.length, v.length))
            #expect(close(r.dot(n), -v.dot(n)))

            let target = randomVec3(&rng, in: -5...5)
            if let proj = v.project(onto: target) {
                let residual = v - proj
                #expect(abs(residual.dot(target)) <= testTolerance * max(1, v.length * target.length))
            }

            if let ang1 = v.angle(to: target), let ang2 = target.angle(to: v) {
                #expect(close(ang1, ang2))
                #expect(ang1 >= 0 && ang1 <= .pi + testTolerance)
            }

            let d = v.distance(to: target)
            #expect(close(d * d, v.distanceSquared(to: target)))
        }

        #expect(CajuVec3.unitX.project(onto: .zero) == nil)
        #expect(CajuVec3.unitX.angle(to: .zero) == nil)
        #expect(CajuVec2.unitX.angle(to: .nan * .unitX) == nil)
        #expect(!CajuVec3(.nan, 0, 0).isFinite)
    }

    @Test func vec2PerpendicularAndVec3OrthonormalBasis() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let v2 = randomVec2(&rng, in: -10...10)
            let p2 = v2.perpendicular
            #expect(abs(v2.dot(p2)) <= testTolerance * max(1, v2.lengthSquared))
            #expect(close(v2.length, p2.length))

            let n = randomUnitVec3(&rng)
            let basis = n.orthonormalBasis()
            #expect(basis != nil)
            if let (t, b) = basis {
                #expect(abs(t.length - 1) <= testTolerance)
                #expect(abs(b.length - 1) <= testTolerance)
                #expect(abs(t.dot(n)) <= testTolerance)
                #expect(abs(b.dot(n)) <= testTolerance)
                #expect(abs(t.dot(b)) <= testTolerance)
                #expect(close(t.cross(b), n))
            }
        }
        #expect(CajuVec3.zero.orthonormalBasis() == nil)
        #expect(CajuVec3(.infinity, 0, 0).orthonormalBasis() == nil)
    }
}
