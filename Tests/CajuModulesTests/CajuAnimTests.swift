import CajuAnim
import CajuCore
import CajuMath
import CajuScene
import CajuTesting
import Testing

private func closeVec3(_ a: CajuVec3, _ b: CajuVec3, tol: Float = 1e-4) -> Bool {
    (a - b).length <= tol
}

private func closeFloat(_ a: Float, _ b: Float, tol: Float = 1e-5) -> Bool {
    abs(a - b) <= tol
}

private func maxAbs(_ v: SIMD4<Float>) -> Float {
    max(max(abs(v.x), abs(v.y)), max(abs(v.z), abs(v.w)))
}

private func closeMat4(_ a: CajuMat4, _ b: CajuMat4, tol: Float = 1e-4) -> Bool {
    max(
        max(maxAbs(a.c0 - b.c0), maxAbs(a.c1 - b.c1)),
        max(maxAbs(a.c2 - b.c2), maxAbs(a.c3 - b.c3))
    ) <= tol
}

private func quatLength(_ q: CajuQuat) -> Float {
    (q.storage * q.storage).sum().squareRoot()
}

@Suite("CajuAnim: arena de poses, esqueletos, clipes, player e propriedades")
struct CajuAnimTests {

    // MARK: - CajuPoseArena & CajuSkinPose

    @Test func poseArenaAllocateReleaseCoalesceAndErrors() throws {
        let arena = CajuPoseArena(matrixCapacity: 16)
        #expect(arena.availableMatrixCount == 16)
        #expect(MemoryLayout<CajuSkinPose>.stride <= 16)

        var p0 = try arena.allocate(jointCount: 6)
        var p1 = try arena.allocate(jointCount: 6)
        #expect(p0.poseSlot == 0 && p1.poseSlot == 6)
        #expect(arena.usedMatrixCount == 12)

        #expect(throws: CajuPoseArena.ArenaError.capacityExceeded(requested: 5, available: 4)) {
            _ = try arena.allocate(jointCount: 5)
        }
        #expect(throws: CajuPoseArena.ArenaError.invalidJointCount(0)) {
            _ = try arena.allocate(jointCount: 0)
        }
        #expect(throws: CajuPoseArena.ArenaError.invalidJointCount(129)) {
            _ = try arena.allocate(jointCount: 129)
        }

        try arena.release(&p0)
        #expect(!p0.isValid)
        #expect(arena.usedMatrixCount == 6)
        // Double-release rejeitado
        #expect(
            throws: CajuPoseArena.ArenaError.invalidPoseRange(slot: CajuSkinPose.invalidSlot, jointCount: 0)
        ) {
            try arena.release(&p0)
        }

        // Reutiliza faixa livre e coalesce ao liberar tudo
        var p2 = try arena.allocate(jointCount: 6)
        #expect(p2.poseSlot == 0)
        try arena.release(&p2)
        try arena.release(&p1)
        #expect(arena.usedMatrixCount == 0)
        #expect(arena.availableMatrixCount == 16)

        // Agora há 16 contínuos novamente
        let full = try arena.allocate(jointCount: 16)
        #expect(full.poseSlot == 0)
        arena.reset()
        #expect(arena.usedMatrixCount == 0)
    }

    // MARK: - Esqueleto e hierarquia

    @Test func skeletonValidatesCycleParentsAndNonTopologicalOrder() throws {
        #expect(throws: CajuAnimError.invalidJointCount(0)) {
            _ = try CajuSkeleton(parentIndices: [])
        }
        #expect(throws: CajuAnimError.invalidJointCount(129)) {
            _ = try CajuSkeleton(parentIndices: Array(repeating: -1, count: 129))
        }
        #expect(throws: CajuAnimError.invalidParentIndex(joint: 0, parent: 0)) {
            _ = try CajuSkeleton(parentIndices: [0])
        }
        #expect(throws: CajuAnimError.cycleDetected(joint: 0)) {
            _ = try CajuSkeleton(parentIndices: [1, 0])
        }

        // Filho no índice 0, pai no índice 2 (não ordenado topologicamente, como ocorre em glTF)
        let skel = try CajuSkeleton(parentIndices: [2, 0, -1])
        #expect(!skel.isTopologicallyOrdered)
        #expect(Array(skel.evaluationOrder) == [2, 0, 1])
    }

    @Test func hierarchyModelSpacePoseMatchesManualCompositionWithoutInverseBind() throws {
        let rotZ90 = try #require(CajuQuat(axis: .unitZ, radians: .pi / 2))
        // Junta 0 = raiz (rest: translação (10, 0, 0), rot Z 90°)
        // Junta 1 = filha de 0 (rest: translação (2, 0, 0))
        // Junta 2 = filha de 1 (rest: escala 2, translação (1, 0, 0))
        let skel = try CajuSkeleton(
            parentIndices: [-1, 0, 1],
            restPose: [
                CajuJointTransform(translation: CajuVec3(10, 0, 0), rotation: rotZ90),
                CajuJointTransform(translation: CajuVec3(2, 0, 0)),
                CajuJointTransform(translation: CajuVec3(1, 0, 0), scale: CajuVec3(2, 2, 2)),
            ]
        )

        // Clipe anima apenas a junta 1 com translação (3, 0, 0) no instante t=0.5
        let clip = try CajuAnimClip(channels: [
            .translation(jointIndex: 1, times: [0, 1], values: [CajuVec3(1, 0, 0), CajuVec3(5, 0, 0)])
        ])

        let arena = CajuPoseArena(skeletonCapacity: 2, jointsPerSkeleton: 3)
        var pose = try arena.allocate(jointCount: 3)
        var scratch = CajuAnimScratchBuffer()

        let didSample = try CajuAnimSampler.sampleAndWrite(
            clip: clip,
            time: 0.5,
            skeleton: skel,
            into: &pose,
            arena: arena,
            scratch: &scratch
        )
        #expect(didSample)
        #expect(pose.version == 1)

        // Espaço do modelo (sem inverseBind):
        // M0 = T(10,0,0) * Rz(90°)
        // M1 = M0 * T(3,0,0) -> origem da junta 1 em (10, 3, 0)
        // M2 = M1 * T(1,0,0) * S(2) -> origem da junta 2 em (10, 4, 0)
        let m0 = try arena.matrix(at: 0, for: pose)
        let m1 = try arena.matrix(at: 1, for: pose)
        let m2 = try arena.matrix(at: 2, for: pose)
        #expect(closeVec3(m0.transformPoint(.zero), CajuVec3(10, 0, 0)))
        #expect(closeVec3(m1.transformPoint(.zero), CajuVec3(10, 3, 0)))
        #expect(closeVec3(m2.transformPoint(.zero), CajuVec3(10, 4, 0)))
        #expect(closeVec3(m2.transformPoint(CajuVec3(1, 0, 0)), CajuVec3(10, 6, 0)))
    }

    // MARK: - Interpolação step/linear e validação de canais

    @Test func channelInterpolationStepAndShortestArcSlerp() throws {
        let stepCh = try CajuAnimVec3Channel(
            jointIndex: 0,
            interpolation: .step,
            times: [0, 1, 2],
            values: [CajuVec3(0, 0, 0), CajuVec3(10, 0, 0), CajuVec3(20, 0, 0)]
        )
        #expect(stepCh.sample(at: -1) == CajuVec3(0, 0, 0))
        #expect(stepCh.sample(at: 0.99) == CajuVec3(0, 0, 0))
        #expect(stepCh.sample(at: 1.0) == CajuVec3(10, 0, 0))
        #expect(stepCh.sample(at: 1.99) == CajuVec3(10, 0, 0))
        #expect(stepCh.sample(at: 2.0) == CajuVec3(20, 0, 0))
        #expect(stepCh.sample(at: 5.0) == CajuVec3(20, 0, 0))

        // Menor arco: q0 = identidade, q1 = -rotZ(90°) (hemisfério oposto, dot < 0)
        let q0 = CajuQuat.identity
        let qPos = try #require(CajuQuat(axis: .unitZ, radians: .pi / 2))
        let qNeg = CajuQuat(x: -qPos.x, y: -qPos.y, z: -qPos.z, w: -qPos.w)
        let quatCh = try CajuAnimQuatChannel(
            jointIndex: 0,
            interpolation: .linear,
            times: [0, 1],
            values: [q0, qNeg]
        )
        let mid = quatCh.sample(at: 0.5)
        let expectedMid = try #require(CajuQuat(axis: .unitZ, radians: .pi / 4))
        #expect(closeMat4(CajuMat4.rotation(mid), CajuMat4.rotation(expectedMid)))
        #expect(closeFloat(quatLength(mid), 1.0))

        // Validações de erro tipado
        #expect(throws: CajuAnimError.invalidKeyframeOrder(jointIndex: 0, keyframeIndex: 1)) {
            _ = try CajuAnimVec3Channel(
                jointIndex: 0,
                times: [1.0, 0.5],
                values: [.zero, .one]
            )
        }
        #expect(throws: CajuAnimError.invalidKeyframeCount(times: 2, values: 1)) {
            _ = try CajuAnimVec3Channel(jointIndex: 0, times: [0, 1], values: [.zero])
        }
    }

    // MARK: - Player, crossfade, cull flag/hook e sistema ECS

    @Test func playerTimeLoopSpeedCrossfadeAndCull() throws {
        let skel = try CajuSkeleton(parentIndices: [-1, 0])
        let clipA = try CajuAnimClip(
            name: "a",
            duration: 2.0,
            channels: [
                .translation(jointIndex: 0, times: [0, 2], values: [.zero, CajuVec3(2, 0, 0)])
            ]
        )
        let clipB = try CajuAnimClip(
            name: "b",
            duration: 1.0,
            channels: [
                .translation(jointIndex: 0, times: [0, 1], values: [CajuVec3(0, 10, 0), CajuVec3(0, 10, 0)])
            ]
        )
        let clips = [clipA, clipB]

        let arena = CajuPoseArena(matrixCapacity: 16)
        var pose = try arena.allocate(jointCount: 2)
        var scratch = CajuAnimScratchBuffer()

        var player = CajuAnimPlayer(clipIndex: 0, speed: 2.0, isLooping: true)
        player.advance(by: 0.75, clips: clips)  // t = 1.5
        #expect(closeFloat(player.time, 1.5))
        player.advance(by: 0.5, clips: clips)  // t = 2.5 -> wrap 0.5
        #expect(closeFloat(player.time, 0.5))

        // Crossfade de 1.0 s para clipB
        player.crossfade(to: 1, duration: 1.0, speed: 1.0, isLooping: false)
        #expect(player.isCrossfading)
        player.advance(by: 0.5, clips: clips)
        let w = player.crossfadeWeights
        #expect(closeFloat(w.from, 0.5) && closeFloat(w.to, 0.5))
        #expect(closeFloat(w.from + w.to, 1.0))

        let sampled = try player.sampleAndWrite(
            skeleton: skel, clips: clips, into: &pose, arena: arena, scratch: &scratch
        )
        #expect(sampled)
        #expect(pose.version == 1)

        // Cull por flag pula amostragem e não altera pose.version nem a arena
        player.isCulled = true
        let versionBeforeCull = pose.version
        let skippedByFlag = try player.sampleAndWrite(
            skeleton: skel, clips: clips, into: &pose, arena: arena, scratch: &scratch
        )
        #expect(!skippedByFlag)
        #expect(pose.version == versionBeforeCull)

        // Cull por hook também pula amostragem
        player.isCulled = false
        let skippedByHook = try player.sampleAndWrite(
            skeleton: skel,
            clips: clips,
            into: &pose,
            arena: arena,
            scratch: &scratch,
            shouldSample: { _ in false }
        )
        #expect(!skippedByHook)
        #expect(pose.version == versionBeforeCull)

        // Finaliza crossfade e avança até terminar clipe não-looping
        player.advance(by: 0.6, clips: clips)
        #expect(!player.isCrossfading)
        #expect(player.state.isFinished(duration: clipB.duration))
    }

    @Test func ecsPoseUpdateSystemRespectsCullFlagAndHook() throws {
        let world = CajuWorld()
        let arena = CajuPoseArena(skeletonCapacity: 4, jointsPerSkeleton: 2)
        let library = CajuAnimLibrary()

        let skel = try CajuSkeleton(parentIndices: [-1, 0])
        let clip = try CajuAnimClip(channels: [
            .translation(jointIndex: 0, times: [0, 1], values: [.zero, CajuVec3(10, 0, 0)])
        ])
        let skelID = library.registerSkeleton(skel)
        let clipID = library.registerClip(clip)

        let visibleEntity = try world.spawn(
            CajuAnimPlayback(skeletonID: skelID, clipID: clipID, isCulled: false),
            try arena.allocate(jointCount: 2)
        )
        let culledEntity = try world.spawn(
            CajuAnimPlayback(skeletonID: skelID, clipID: clipID, isCulled: true),
            try arena.allocate(jointCount: 2)
        )

        var hookAllows = true
        let scheduler = CajuScheduler(world: world)
        try scheduler.add(
            CajuAnim.poseUpdateSystem(
                library: library,
                arena: arena,
                shouldSample: { _, _ in hookAllows }
            )
        )
        try scheduler.build()

        try scheduler.tick(delta: 0.5)
        #expect(library.lastFrameSampledCount == 1)
        #expect(library.lastFrameCulledCount == 1)
        #expect(library.errorCount == 0)

        let visiblePose = try #require(world.get(CajuSkinPose.self, of: visibleEntity))
        let culledPose = try #require(world.get(CajuSkinPose.self, of: culledEntity))
        #expect(visiblePose.version == 1)
        #expect(culledPose.version == 0)

        // Relógio avançou mesmo com cull; ao ligar visibilidade, amostra no instante acumulado
        let culledPlayback = try #require(world.get(CajuAnimPlayback.self, of: culledEntity))
        #expect(closeFloat(culledPlayback.time, 0.5))

        // Hook bloqueia amostragem globalmente no próximo quadro
        hookAllows = false
        try scheduler.tick(delta: 0.25)
        #expect(library.lastFrameSampledCount == 0)
        #expect(library.lastFrameCulledCount == 2)
        #expect(try #require(world.get(CajuSkinPose.self, of: visibleEntity)).version == 1)
    }

    // MARK: - Testes de propriedade com semente fixa (≥ 10 000 casos)

    @Test func propertyInterpolationEndpointsAndBounds() throws {
        try CajuFuzz.run(seed: 0xA110_0001, iterations: 10_000) { rng, _ in
            let t0 = rng.nextFloat(in: 0...10)
            let dt = rng.nextFloat(in: 0.01...10)
            let t1 = t0 + dt
            let v0 = CajuVec3(
                rng.nextFloat(in: -50...50),
                rng.nextFloat(in: -50...50),
                rng.nextFloat(in: -50...50)
            )
            let v1 = CajuVec3(
                rng.nextFloat(in: -50...50),
                rng.nextFloat(in: -50...50),
                rng.nextFloat(in: -50...50)
            )

            let chLinear = try CajuAnimVec3Channel(
                jointIndex: 0, interpolation: .linear, times: [t0, t1], values: [v0, v1]
            )
            let chStep = try CajuAnimVec3Channel(
                jointIndex: 0, interpolation: .step, times: [t0, t1], values: [v0, v1]
            )

            // Extremos exatos e fora do intervalo
            #expect(closeVec3(chLinear.sample(at: t0), v0, tol: 1e-5))
            #expect(closeVec3(chLinear.sample(at: max(0, t0 - 1)), v0, tol: 1e-5))
            #expect(closeVec3(chLinear.sample(at: t1), v1, tol: 1e-5))
            #expect(closeVec3(chLinear.sample(at: t1 + 1), v1, tol: 1e-5))

            #expect(chStep.sample(at: t0) == v0)
            #expect(chStep.sample(at: t0 + dt * 0.5) == v0)
            #expect(chStep.sample(at: t1) == v1)

            // Ponto aleatório dentro do segmento respeita envelope min/max
            let alpha = rng.nextFloat(in: 0...1)
            let sample = chLinear.sample(at: t0 + dt * alpha)
            let low = CajuVec3.min(v0, v1) - CajuVec3(repeating: 1e-4)
            let high = CajuVec3.max(v0, v1) + CajuVec3(repeating: 1e-4)
            #expect(sample.x >= low.x && sample.x <= high.x)
            #expect(sample.y >= low.y && sample.y <= high.y)
            #expect(sample.z >= low.z && sample.z <= high.z)
        }
    }

    @Test func propertyQuaternionChannelsAndBlendingStayNormalized() throws {
        try CajuFuzz.run(seed: 0xA110_0002, iterations: 10_000) { rng, _ in
            let q0Raw = CajuQuat(
                x: rng.nextFloat(in: -10...10),
                y: rng.nextFloat(in: -10...10),
                z: rng.nextFloat(in: -10...10),
                w: rng.nextFloat(in: -10...10) + 0.05
            )
            let q1Raw = CajuQuat(
                x: rng.nextFloat(in: -10...10),
                y: rng.nextFloat(in: -10...10),
                z: rng.nextFloat(in: -10...10),
                w: rng.nextFloat(in: -10...10) + 0.05
            )
            guard let q0 = q0Raw.normalized(), let q1 = q1Raw.normalized() else { return }

            let t0 = rng.nextFloat(in: 0...2)
            let t1 = t0 + rng.nextFloat(in: 0.05...5)
            let ch = try CajuAnimQuatChannel(
                jointIndex: 0, interpolation: .linear, times: [t0, t1], values: [q0Raw, q1Raw]
            )

            let queryT = rng.nextFloat(in: 0...(t1 + 1))
            let sampled = ch.sample(at: queryT)
            #expect(sampled.isFinite)
            #expect(closeFloat(quatLength(sampled), 1.0, tol: 1e-5))

            // Extremos reproduzem a rotação exata (módulo sinal de dupla cobertura)
            #expect(closeMat4(CajuMat4.rotation(ch.sample(at: t0)), CajuMat4.rotation(q0), tol: 1e-4))
            #expect(closeMat4(CajuMat4.rotation(ch.sample(at: t1)), CajuMat4.rotation(q1), tol: 1e-4))

            // Mistura de dois transforms também mantém quaternion unitário
            let blendWeight = rng.nextFloat(in: -0.5...1.5)
            let blended = CajuJointTransform.blend(
                CajuJointTransform(rotation: q0),
                CajuJointTransform(rotation: q1),
                weight: blendWeight
            )
            #expect(blended.rotation.isFinite)
            #expect(closeFloat(quatLength(blended.rotation), 1.0, tol: 1e-5))
        }
    }

    @Test func propertyCrossfadeWeightsSumToOne() {
        CajuFuzz.run(seed: 0xA110_0003, iterations: 10_000) { rng, _ in
            let fadeDuration = rng.nextFloat(in: 0.01...5.0)
            let clipDurationA = rng.nextFloat(in: 0.5...4.0)
            let clipDurationB = rng.nextFloat(in: 0.5...4.0)
            let dt = rng.nextFloat(in: 0...(fadeDuration * 1.5))

            var pb = CajuAnimPlayback(skeletonID: 0, clipID: 0, time: 0, speed: 1, isLooping: true)
            pb.crossfade(to: 1, duration: fadeDuration, speed: 1, isLooping: true)

            let w0 = pb.crossfadeWeights
            #expect(closeFloat(w0.from, 1.0, tol: 1e-6) && closeFloat(w0.to, 0.0, tol: 1e-6))
            #expect(closeFloat(w0.from + w0.to, 1.0, tol: 1e-6))

            pb.advance(by: dt, currentDuration: clipDurationB, previousDuration: clipDurationA)
            let w1 = pb.crossfadeWeights
            #expect(w1.from >= 0 && w1.to >= 0)
            #expect(closeFloat(w1.from + w1.to, 1.0, tol: 1e-6))

            if dt >= fadeDuration {
                #expect(!pb.isCrossfading)
                #expect(closeFloat(w1.from, 0.0, tol: 1e-6) && closeFloat(w1.to, 1.0, tol: 1e-6))
            }
        }
    }

    @Test func propertyJointMaskIsolatesMaskedOutJoints() throws {
        var localPose = ContiguousArray<CajuJointTransform>(repeating: .identity, count: 128)
        try CajuFuzz.run(seed: 0xA110_0004, iterations: 10_000) { rng, _ in
            let jointCount = Int(rng.nextUInt32() % 32) + 1
            var parents: [Int16] = []
            parents.reserveCapacity(jointCount)
            var rest: [CajuJointTransform] = []
            rest.reserveCapacity(jointCount)

            for j in 0..<jointCount {
                parents.append(j == 0 ? -1 : Int16(rng.nextUInt32() % UInt32(j)))
                rest.append(
                    CajuJointTransform(
                        translation: CajuVec3(Float(j), 1, -1),
                        rotation: .identity,
                        scale: .one
                    )
                )
            }
            let skel = try CajuSkeleton(parentIndices: parents, restPose: rest)

            var channels: [CajuAnimChannel] = []
            channels.reserveCapacity(jointCount)
            for j in 0..<jointCount {
                channels.append(
                    .translation(
                        jointIndex: j,
                        times: [0, 1],
                        values: [CajuVec3(100 + Float(j), 20, 30), CajuVec3(200 + Float(j), 40, 60)]
                    )
                )
            }
            let clip = try CajuAnimClip(channels: channels)

            let mask = CajuJointMask(low: rng.next(), high: rng.next())
            try CajuAnimSampler.sampleLocalPose(
                clip: clip,
                time: 0.5,
                skeleton: skel,
                mask: mask,
                into: &localPose
            )

            for j in 0..<jointCount {
                if mask.contains(j) {
                    #expect(closeVec3(localPose[j].translation, CajuVec3(150 + Float(j), 30, 45)))
                } else {
                    #expect(localPose[j] == rest[j])
                }
            }
        }
    }

    @Test func subtreeMaskAndCrossfadeMaskIsolation() throws {
        // Esqueleto: 0 -> 1 -> 2 (braço) e 0 -> 3 (perna)
        let skel = try CajuSkeleton(parentIndices: [-1, 0, 1, 0])
        let armMask = try CajuJointMask.subtree(of: skel, rootJoint: 1)
        #expect(!armMask.contains(0))
        #expect(armMask.contains(1) && armMask.contains(2))
        #expect(!armMask.contains(3))

        let baseClip = try CajuAnimClip(channels: [
            .translation(jointIndex: 1, times: [0, 1], values: [CajuVec3(1, 0, 0), CajuVec3(1, 0, 0)]),
            .translation(jointIndex: 3, times: [0, 1], values: [CajuVec3(0, 5, 0), CajuVec3(0, 5, 0)]),
        ])
        let waveClip = try CajuAnimClip(channels: [
            .translation(jointIndex: 1, times: [0, 1], values: [CajuVec3(3, 0, 0), CajuVec3(3, 0, 0)]),
            .translation(jointIndex: 3, times: [0, 1], values: [CajuVec3(0, 99, 0), CajuVec3(0, 99, 0)]),
        ])

        let arena = CajuPoseArena(skeletonCapacity: 1, jointsPerSkeleton: 4)
        var pose = try arena.allocate(jointCount: 4)
        var scratch = CajuAnimScratchBuffer()

        try CajuAnimSampler.sampleCrossfadeAndWrite(
            fromClip: baseClip,
            fromTime: 0,
            fromMask: .all,
            toClip: waveClip,
            toTime: 0,
            toMask: armMask,
            weight: 0.5,
            skeleton: skel,
            into: &pose,
            arena: arena,
            scratch: &scratch
        )

        // Junta 1 (na máscara do braço): blend 50% entre (1,0,0) e (3,0,0) -> (2,0,0)
        let m1 = try arena.matrix(at: 1, for: pose)
        #expect(closeVec3(m1.transformPoint(.zero), CajuVec3(2, 0, 0)))
        // Junta 3 (fora da máscara do braço): preserva integralmente o baseClip (0,5,0)
        let m3 = try arena.matrix(at: 3, for: pose)
        #expect(closeVec3(m3.transformPoint(.zero), CajuVec3(0, 5, 0)))
    }
}
