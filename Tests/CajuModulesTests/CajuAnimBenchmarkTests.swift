import CajuAnim
import CajuMath
import CajuScene
import Testing

/// Benchmark de CPU da amostragem SIMD de animação (`AN-1`).
///
/// Mede amostragem de clipe + propagação hierárquica em espaço do modelo (sem `inverseBind`) +
/// escrita na `CajuPoseArena`, para `32` e `128` juntas (`CajuPoseArena.maxJointCount (?)`).
/// Imprime mediana e p95 em microssegundos; números de referência em aparelho permanecem `(?)`
/// até medição no iPhone 16 Pro e Galaxy S22+ (`docs/standards/performance.md`).
@Suite("CajuAnim: benchmark de amostragem SIMD", .serialized)
struct CajuAnimBenchmarkTests {
    private func makeBenchmarkRig(jointCount: Int) throws -> (CajuSkeleton, CajuAnimClip, CajuAnimClip) {
        var parents: [Int16] = []
        parents.reserveCapacity(jointCount)
        var channelsA: [CajuAnimChannel] = []
        var channelsB: [CajuAnimChannel] = []
        channelsA.reserveCapacity(jointCount * 3)
        channelsB.reserveCapacity(jointCount * 3)

        let q0 = CajuQuat.identity
        let q1 = CajuQuat(axis: .unitY, radians: .pi / 2) ?? .identity
        let q2 = CajuQuat(axis: .unitX, radians: .pi / 3) ?? .identity

        for j in 0..<jointCount {
            parents.append(j == 0 ? -1 : Int16(j - 1))
            channelsA.append(
                .translation(
                    jointIndex: j,
                    times: [0, 0.5, 1.0],
                    values: [CajuVec3(0, 0, 0), CajuVec3(0.5, 0.25, 0), CajuVec3(1, 0, 0)]
                )
            )
            channelsA.append(.rotation(jointIndex: j, times: [0, 1.0], values: [q0, q1]))
            channelsA.append(
                .scale(
                    jointIndex: j,
                    times: [0, 1.0],
                    values: [.one, CajuVec3(1.1, 1.1, 1.1)]
                )
            )

            channelsB.append(
                .translation(
                    jointIndex: j,
                    times: [0, 1.0],
                    values: [CajuVec3(0, 1, 0), CajuVec3(0, 2, 0)]
                )
            )
            channelsB.append(.rotation(jointIndex: j, times: [0, 1.0], values: [q0, q2]))
            channelsB.append(.scale(jointIndex: j, times: [0, 1.0], values: [.one, .one]))
        }

        let skeleton = try CajuSkeleton(parentIndices: parents)
        let clipA = try CajuAnimClip(name: "benchA", channels: channelsA)
        let clipB = try CajuAnimClip(name: "benchB", channels: channelsB)
        return (skeleton, clipA, clipB)
    }

    private func microseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
    }

    private func stats(_ samples: [Double]) -> (median: Double, p95: Double) {
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)])
    }

    @Test(arguments: [32, 128])
    func sampleHierarchyAndWritePose(jointCount: Int) throws {
        let (skeleton, clipA, clipB) = try makeBenchmarkRig(jointCount: jointCount)
        let arena = CajuPoseArena(skeletonCapacity: 1, jointsPerSkeleton: jointCount)
        var pose = try arena.allocate(jointCount: UInt16(jointCount))
        var scratch = CajuAnimScratchBuffer()
        let clock = ContinuousClock()
        let iterations = 1000

        var singleSamples: [Double] = []
        singleSamples.reserveCapacity(iterations)
        for i in 0..<iterations {
            let t = Float(i % 100) / 100.0
            let elapsed = try clock.measure {
                try CajuAnimSampler.sampleAndWrite(
                    clip: clipA,
                    time: t,
                    skeleton: skeleton,
                    into: &pose,
                    arena: arena,
                    scratch: &scratch
                )
            }
            singleSamples.append(microseconds(elapsed))
        }

        var crossfadeSamples: [Double] = []
        crossfadeSamples.reserveCapacity(iterations)
        for i in 0..<iterations {
            let t = Float(i % 100) / 100.0
            let elapsed = try clock.measure {
                try CajuAnimSampler.sampleCrossfadeAndWrite(
                    fromClip: clipA,
                    fromTime: t,
                    toClip: clipB,
                    toTime: t,
                    weight: 0.5,
                    skeleton: skeleton,
                    into: &pose,
                    arena: arena,
                    scratch: &scratch
                )
            }
            crossfadeSamples.append(microseconds(elapsed))
        }

        let s = stats(singleSamples)
        let c = stats(crossfadeSamples)
        print(
            "AN-1 amostragem \(jointCount) juntas: simples mediana \(s.median) us p95 \(s.p95) us; "
                + "crossfade mediana \(c.median) us p95 \(c.p95) us"
        )
        #expect(pose.version == UInt32(iterations * 2))
        #expect(arena.usedMatrixCount == jointCount)
    }
}
