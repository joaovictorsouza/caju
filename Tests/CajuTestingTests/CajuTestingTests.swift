import CajuTesting
import Testing

@Suite("CajuPCG32")
struct CajuPCG32Tests {
    @Test func sameSeedSameSequence() {
        var a = CajuPCG32(seed: 7)
        var b = CajuPCG32(seed: 7)
        for _ in 0..<1_000 { #expect(a.nextUInt32() == b.nextUInt32()) }
    }

    @Test func differentSeedsDiffer() {
        var a = CajuPCG32(seed: 1)
        var b = CajuPCG32(seed: 2)
        let same = (0..<64).filter { _ in a.nextUInt32() == b.nextUInt32() }.count
        #expect(same < 4)
    }

    @Test func floatStaysInRange() {
        var rng = CajuPCG32(seed: 3)
        for _ in 0..<10_000 {
            let f = rng.nextFloat(in: -2...5)
            #expect(f >= -2 && f <= 5)
        }
    }

    @Test func fuzzRunsEveryIteration() {
        var count = 0
        CajuFuzz.run(iterations: 25) { _, _ in count += 1 }
        #expect(count == 25)
    }
}
