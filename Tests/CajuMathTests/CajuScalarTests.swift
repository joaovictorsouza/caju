import CajuMath
import CajuTesting
import Testing

@Suite("CajuScalar")
struct CajuScalarTests {
    @Test func lerpAndInverseLerpRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let a = rng.nextFloat(in: -20...20)
            let span = (rng.nextUInt32() & 1 == 0 ? 1 : -1) * rng.nextFloat(in: 1...20)
            let b = a + span
            let t = rng.nextFloat(in: -2...3)
            let v = CajuScalar.lerp(a, b, t: t)
            let recovered = CajuScalar.inverseLerp(a, b, value: v)
            #expect(recovered != nil)
            if let recovered {
                #expect(close(recovered, t))
            }
        }
    }

    @Test func remapRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let fromMin = rng.nextFloat(in: -20...0)
            let fromMax = fromMin + rng.nextFloat(in: 2...20)
            let toMin = rng.nextFloat(in: -20...0)
            let toMax = toMin + rng.nextFloat(in: 2...20)
            let x = rng.nextFloat(in: fromMin...fromMax)
            if let mapped = CajuScalar.remap(
                x, fromMin: fromMin, fromMax: fromMax, toMin: toMin, toMax: toMax),
                let back = CajuScalar.remap(
                    mapped, fromMin: toMin, fromMax: toMax, toMin: fromMin, toMax: fromMax)
            {
                #expect(close(back, x))
            } else {
                Issue.record("Remap falhou inesperadamente")
            }
        }
    }

    @Test func clampSaturateAndSmoothstep() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let a = rng.nextFloat(in: -100...0)
            let b = rng.nextFloat(in: 0.1...100)
            let x = rng.nextFloat(in: -200...200)
            let clamped = CajuScalar.clamp(x, min: a, max: b)
            #expect(clamped >= a && clamped <= b)

            let sat = CajuScalar.saturate(x)
            #expect(sat >= 0 && sat <= 1)

            let s = CajuScalar.smoothstep(edge0: a, edge1: b, x: x)
            #expect(s >= 0 && s <= 1)
            let x2 = x + rng.nextFloat(in: 0...10)
            #expect(CajuScalar.smoothstep(edge0: a, edge1: b, x: x2) >= s)
        }
        #expect(CajuScalar.clamp(5, min: 10, max: 0) == 5)
        #expect(CajuScalar.smoothstep(edge0: 5, edge1: 5, x: 4) == 0)
        #expect(CajuScalar.smoothstep(edge0: 5, edge1: 5, x: 5) == 1)
    }

    @Test func degreesRadiansRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let deg = rng.nextFloat(in: -720...720)
            let rad = CajuScalar.radians(fromDegrees: deg)
            let back = CajuScalar.degrees(fromRadians: rad)
            #expect(close(back, deg))
        }
        #expect(close(CajuScalar.radians(fromDegrees: 180), .pi))
        #expect(close(CajuScalar.degrees(fromRadians: .pi), 180))
    }

    @Test func approximatelyEqualAndEdgeCases() {
        #expect(CajuScalar.approximatelyEqual(1000, 1000 + 0.005, tolerance: 1e-5))
        #expect(!CajuScalar.approximatelyEqual(1, 1.001, tolerance: 1e-5))
        #expect(!CajuScalar.approximatelyEqual(.nan, 0))
        #expect(!CajuScalar.approximatelyEqual(.infinity, .infinity))
        #expect(!CajuScalar.approximatelyEqual(0, 0, tolerance: -1e-5))
        #expect(CajuScalar.inverseLerp(2, 2, value: 2) == nil)
        #expect(CajuScalar.inverseLerp(.nan, 1, value: 0) == nil)
        #expect(CajuScalar.remap(0, fromMin: 1, fromMax: 1, toMin: 0, toMax: 10) == nil)
        #expect(CajuScalar.remap(.infinity, fromMin: 0, fromMax: 1, toMin: 0, toMax: 10) == nil)
    }
}
