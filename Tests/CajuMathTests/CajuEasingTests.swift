import CajuMath
import CajuTesting
import Testing

@Suite("CajuEasing")
struct CajuEasingTests {
    @Test func endpointsAreExactAndClamped() {
        for curve in CajuEasing.allCases {
            #expect(curve(0) == 0)
            #expect(curve(-1) == 0)
            #expect(curve(.nan) == 0)
            #expect(curve(1) == 1)
            #expect(curve(2) == 1)
        }
        #expect(CajuEasing.cubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1, t: 0) == 0)
        #expect(CajuEasing.cubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1, t: 1) == 1)
        #expect(CajuEasing.cubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1, t: .nan) == 0)
    }

    @Test func monotonicCurvesAreNonDecreasing() {
        let monotonic: [CajuEasing] = [
            .linear,
            .quadIn, .quadOut, .quadInOut,
            .cubicIn, .cubicOut, .cubicInOut,
            .quartIn, .quartOut, .quartInOut,
            .quintIn, .quintOut, .quintInOut,
            .sineIn, .sineOut, .sineInOut,
            .expoIn, .expoOut, .expoInOut,
            .circIn, .circOut, .circInOut,
        ]
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let t0 = rng.nextFloat(in: 0...1)
            let t1 = min(1, t0 + rng.nextFloat(in: 0...0.5))
            for curve in monotonic {
                #expect(curve(t1) + 1e-6 >= curve(t0))
            }
        }
    }

    @Test func inOutMirroring() {
        let pairs: [(CajuEasing, CajuEasing)] = [
            (.quadIn, .quadOut),
            (.cubicIn, .cubicOut),
            (.quartIn, .quartOut),
            (.quintIn, .quintOut),
            (.sineIn, .sineOut),
            (.expoIn, .expoOut),
            (.circIn, .circOut),
            (.backIn, .backOut),
            (.elasticIn, .elasticOut),
            (.bounceIn, .bounceOut),
        ]
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let t = rng.nextFloat(in: 0...1)
            for (easeIn, easeOut) in pairs {
                #expect(close(easeOut(t), 1 - easeIn(1 - t)))
            }
        }
    }

    @Test func cubicBezierLinearAndMonotonic() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let t = rng.nextFloat(in: 0...1)
            #expect(close(CajuEasing.cubicBezier(x1: 0, y1: 0, x2: 1, y2: 1, t: t), t))

            let x1 = rng.nextFloat(in: 0...1)
            let y1 = rng.nextFloat(in: 0...1)
            let x2 = rng.nextFloat(in: 0...1)
            let y2 = rng.nextFloat(in: 0...1)
            let t2 = min(1, t + rng.nextFloat(in: 0...0.3))
            let b1 = CajuEasing.cubicBezier(x1: x1, y1: y1, x2: x2, y2: y2, t: t)
            let b2 = CajuEasing.cubicBezier(x1: x1, y1: y1, x2: x2, y2: y2, t: t2)
            #expect(b1.isFinite && b2.isFinite)
            #expect(b2 + 1e-5 >= b1)
        }
    }
}
