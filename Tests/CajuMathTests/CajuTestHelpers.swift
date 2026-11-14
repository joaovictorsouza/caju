import CajuMath
import CajuTesting

let testTolerance: Float = 1e-5
let testIterations = 10_000

func close(_ a: Float, _ b: Float, tolerance: Float = testTolerance) -> Bool {
    CajuScalar.approximatelyEqual(a, b, tolerance: tolerance)
}

func close(_ a: CajuVec2, _ b: CajuVec2, tolerance: Float = testTolerance) -> Bool {
    (a - b).length <= tolerance * max(1, a.length, b.length)
}

func close(_ a: CajuVec3, _ b: CajuVec3, tolerance: Float = testTolerance) -> Bool {
    (a - b).length <= tolerance * max(1, a.length, b.length)
}

func close(_ a: CajuVec4, _ b: CajuVec4, tolerance: Float = testTolerance) -> Bool {
    (a - b).length <= tolerance * max(1, a.length, b.length)
}

func closeQuat(_ a: CajuQuat, _ b: CajuQuat, tolerance: Float = testTolerance) -> Bool {
    let diff = (a.storage - b.storage)
    let sum = (a.storage + b.storage)
    let diffLen = (diff * diff).sum().squareRoot()
    let sumLen = (sum * sum).sum().squareRoot()
    return min(diffLen, sumLen) <= tolerance
}

func closeMat(_ a: CajuMat4, _ b: CajuMat4, tolerance: Float = testTolerance) -> Bool {
    close(CajuVec4(storage: a.c0), CajuVec4(storage: b.c0), tolerance: tolerance)
        && close(CajuVec4(storage: a.c1), CajuVec4(storage: b.c1), tolerance: tolerance)
        && close(CajuVec4(storage: a.c2), CajuVec4(storage: b.c2), tolerance: tolerance)
        && close(CajuVec4(storage: a.c3), CajuVec4(storage: b.c3), tolerance: tolerance)
}

func randomVec2(_ rng: inout CajuPCG32, in range: ClosedRange<Float> = -1...1) -> CajuVec2 {
    CajuVec2(rng.nextFloat(in: range), rng.nextFloat(in: range))
}

func randomVec3(_ rng: inout CajuPCG32, in range: ClosedRange<Float> = -1...1) -> CajuVec3 {
    CajuVec3(rng.nextFloat(in: range), rng.nextFloat(in: range), rng.nextFloat(in: range))
}

func randomVec4(_ rng: inout CajuPCG32, in range: ClosedRange<Float> = -1...1) -> CajuVec4 {
    CajuVec4(
        rng.nextFloat(in: range),
        rng.nextFloat(in: range),
        rng.nextFloat(in: range),
        rng.nextFloat(in: range)
    )
}

func randomUnitVec3(_ rng: inout CajuPCG32) -> CajuVec3 {
    for _ in 0..<8 {
        if let v = randomVec3(&rng, in: -1...1).normalized() {
            return v
        }
    }
    return .unitX
}

func randomQuat(_ rng: inout CajuPCG32) -> CajuQuat {
    let axis = randomVec3(&rng)
    let angle = rng.nextFloat(in: -6.28...6.28)
    return CajuQuat(axis: axis, radians: angle) ?? .identity
}
