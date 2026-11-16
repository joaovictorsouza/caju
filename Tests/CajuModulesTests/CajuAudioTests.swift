import CajuAudio
import CajuMath
import CajuPlatform
import Testing

private func makeWavBytes(
    sampleRate: UInt32 = 48_000,
    channels: UInt16 = 1,
    samplesInt16: [Int16]
) -> [UInt8] {
    let dataSize = UInt32(samplesInt16.count * 2)
    let riffSize = 36 + dataSize
    let byteRate = sampleRate * UInt32(channels) * 2
    let blockAlign = channels * 2

    var bytes: [UInt8] = []
    bytes.reserveCapacity(44 + Int(dataSize))

    func appendASCII(_ s: String) {
        bytes.append(contentsOf: s.utf8)
    }
    func appendLE32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }
    func appendLE16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
    }

    appendASCII("RIFF")
    appendLE32(riffSize)
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendLE32(16)
    appendLE16(1)  // PCM
    appendLE16(channels)
    appendLE32(sampleRate)
    appendLE32(byteRate)
    appendLE16(blockAlign)
    appendLE16(16)  // bits per sample
    appendASCII("data")
    appendLE32(dataSize)
    for sample in samplesInt16 {
        appendLE16(UInt16(bitPattern: sample))
    }
    return bytes
}

private func mapPlatformLifecycle(_ event: CajuLifecycleEvent) -> CajuAudioLifecycleEvent {
    switch event {
    case .didBecomeActive: return .didBecomeActive
    case .willResignActive: return .willResignActive
    case .didEnterBackground: return .didEnterBackground
    case .willEnterForeground: return .willEnterForeground
    case .lowMemory: return .lowMemory
    case .willTerminate: return .willTerminate
    }
}

@Suite("CajuAudio: ciclo de vida e dispositivo nulo")
struct CajuAudioLifecycleTests {
    @Test func nullDeviceInitPlayPauseResumeShutdown() throws {
        let config = CajuAudioConfiguration(
            backend: .null,
            sampleRate: 48_000,
            channels: 2,
            listenerCount: 1,
            periodSizeInFrames: 256,
            startImmediately: true
        )
        let engine = try CajuAudioEngine(configuration: config)
        #expect(engine.sampleRate == 48_000)
        #expect(engine.channels == 2)
        #expect(engine.lifecycleState == .running)
        #expect(!engine.isPaused)
        #expect(!engine.isShutdown)

        let clip = try engine.createClip(
            pcmFloat32: [Float](repeating: 0.25, count: 512),
            channels: 1,
            sampleRate: 48_000
        )
        let source = try engine.createSource(
            CajuAudioSourceDescriptor(clip: clip, isLooping: true)
        )
        try engine.play(source)
        #expect(try engine.isPlaying(source))

        // Confirma que a thread do backend nulo invoca o callback @convention(c) e avança os quadros.
        var attempts = 0
        while engine.playedFrames == 0 && attempts < 50 {
            attempts += 1
            for _ in 0..<100_000 { _ = engine.playedFrames }
        }
        #expect(engine.playedFrames > 0)

        try engine.pause()
        #expect(engine.isPaused)
        #expect(engine.lifecycleState == .paused)
        // Pausa duplicada deve ser idempotente.
        try engine.pause()
        #expect(engine.lifecycleState == .paused)

        try engine.resume()
        #expect(!engine.isPaused)
        #expect(engine.lifecycleState == .running)
        #expect(try engine.isPlaying(source))
        // Retomada duplicada deve ser idempotente.
        try engine.resume()
        #expect(engine.lifecycleState == .running)

        engine.shutdown()
        #expect(engine.isShutdown)
        #expect(engine.lifecycleState == .stopped)
        // Shutdown duplicado não falha nem vaza.
        engine.shutdown()

        #expect(throws: CajuAudioError.alreadyShutdown) {
            try engine.pause()
        }
        #expect(throws: CajuAudioError.alreadyShutdown) {
            try engine.resume()
        }
        #expect(throws: CajuAudioError.alreadyShutdown) {
            try engine.play(source)
        }
    }

    @Test func fiftyLifecycleCyclesWithNullDevice() throws {
        for cycle in 0..<20 {
            let engine = try CajuAudioEngine(
                configuration: CajuAudioConfiguration(
                    backend: .null,
                    sampleRate: 48_000,
                    channels: 2,
                    periodSizeInFrames: 128
                )
            )
            let clip = try engine.createClip(
                pcmFloat32: [Float](repeating: 0.1, count: 256),
                channels: 1,
                sampleRate: 48_000
            )
            let source = try engine.createSource(
                CajuAudioSourceDescriptor(clip: clip, isLooping: true)
            )
            try engine.play(source)

            var platformState = CajuLifecycleState.active
            let innerCycles = cycle == 0 ? 50 : 2
            for _ in 0..<innerCycles {
                if platformState.apply(.willResignActive) != nil {
                    try engine.handleLifecycle(mapPlatformLifecycle(.willResignActive))
                }
                #expect(engine.isPaused)

                if platformState.apply(.didEnterBackground) != nil {
                    try engine.handleLifecycle(mapPlatformLifecycle(.didEnterBackground))
                }
                #expect(engine.isPaused)

                // Android pode retomar direto de background para didBecomeActive.
                if platformState.apply(.didBecomeActive) != nil {
                    try engine.handleLifecycle(mapPlatformLifecycle(.didBecomeActive))
                }
                #expect(!engine.isPaused)
            }

            try engine.handleLifecycle(mapPlatformLifecycle(.willTerminate))
            #expect(engine.isShutdown)
            #expect(engine.diagnostics.activeSources == 0)
            #expect(engine.diagnostics.activeClips == 0)
        }
    }

    @Test func offlineLifecyclePausesMixingDeterministically() throws {
        let engine = try CajuAudioEngine(
            configuration: CajuAudioConfiguration(backend: .offline, sampleRate: 48_000, channels: 2)
        )
        defer { engine.shutdown() }

        let clip = try engine.createClip(
            pcmFloat32: [Float](repeating: 0.5, count: 1024),
            channels: 1,
            sampleRate: 48_000
        )
        let source = try engine.createSource(CajuAudioSourceDescriptor(clip: clip, isLooping: true))
        try engine.play(source)

        let activeFrames = try engine.renderFrames(frameCount: 128)
        #expect(activeFrames.contains { abs($0) > 0.05 })
        let framesBeforePause = engine.playedFrames
        #expect(framesBeforePause == 128)

        try engine.handleLifecycle(.didEnterBackground)
        let pausedFrames = try engine.renderFrames(frameCount: 128)
        #expect(pausedFrames.allSatisfy { $0 == 0 })
        #expect(engine.playedFrames == framesBeforePause)

        try engine.handleLifecycle(.didBecomeActive)
        let resumedFrames = try engine.renderFrames(frameCount: 128)
        #expect(resumedFrames.contains { abs($0) > 0.05 })
        #expect(engine.playedFrames == framesBeforePause + 128)
    }
}

@Suite("CajuAudio: espacialização 2D/3D e CajuMath")
struct CajuAudioSpatialTests {
    @Test func spatialMathAttenuationAndPan() {
        let linear = CajuAudioAttenuation(
            model: .linear,
            minDistance: 2,
            maxDistance: 10,
            rolloff: 1,
            minGain: 0.1,
            maxGain: 1
        )
        #expect(
            CajuScalar.approximatelyEqual(
                CajuAudioSpatialMath.attenuationGain(distance: 1, attenuation: linear), 1))
        #expect(
            CajuScalar.approximatelyEqual(
                CajuAudioSpatialMath.attenuationGain(distance: 6, attenuation: linear), 0.5))
        #expect(
            CajuScalar.approximatelyEqual(
                CajuAudioSpatialMath.attenuationGain(distance: 20, attenuation: linear), 0.1))

        let inverse = CajuAudioAttenuation(
            model: .inverse,
            minDistance: 1,
            maxDistance: 100,
            rolloff: 1,
            minGain: 0,
            maxGain: 1
        )
        #expect(
            CajuScalar.approximatelyEqual(
                CajuAudioSpatialMath.attenuationGain(distance: 3, attenuation: inverse), 1.0 / 3.0))

        let exponential = CajuAudioAttenuation(
            model: .exponential,
            minDistance: 2,
            maxDistance: 100,
            rolloff: 2,
            minGain: 0,
            maxGain: 1
        )
        #expect(
            CajuScalar.approximatelyEqual(
                CajuAudioSpatialMath.attenuationGain(distance: 4, attenuation: exponential), 0.25))

        #expect(
            CajuScalar.approximatelyEqual(
                CajuAudioSpatialMath.stereoPan2D(
                    sourcePosition: CajuVec2(-5, 0),
                    listenerPosition: .zero
                ), -1))
        #expect(
            CajuScalar.approximatelyEqual(
                CajuAudioSpatialMath.stereoPan2D(
                    sourcePosition: CajuVec2(5, 0),
                    listenerPosition: .zero
                ), 1))
        #expect(
            CajuScalar.approximatelyEqual(
                CajuAudioSpatialMath.stereoPan2D(
                    sourcePosition: CajuVec2(0, 5),
                    listenerPosition: .zero
                ), 0))

        // Ouvinte rotacionado 90° em torno de Y para olhar para +X: frente = +X, direita = +Z.
        let rot = CajuQuat(axis: .unitY, radians: -.pi / 2) ?? .identity
        let rotatedListener = CajuAudioListener(position: .zero, orientation: rot)
        let panRight = CajuAudioSpatialMath.stereoPan3D(
            sourcePosition: CajuVec3(0, 0, 5),
            listener: rotatedListener
        )
        #expect(CajuScalar.approximatelyEqual(panRight, 1, tolerance: 1e-4))
    }

    @Test func offlineDirectAndPlanar2DPanAndAttenuation() throws {
        let engine = try CajuAudioEngine(
            configuration: CajuAudioConfiguration(backend: .offline, sampleRate: 48_000, channels: 2)
        )
        defer { engine.shutdown() }

        let clip = try engine.createClip(
            pcmFloat32: [Float](repeating: 0.5, count: 2048),
            channels: 1,
            sampleRate: 48_000
        )

        let leftSource = try engine.createSource(
            CajuAudioSourceDescriptor(clip: clip, isLooping: true, spatialMode: .direct2D(pan: -1))
        )
        try engine.play(leftSource)
        let leftMix = try engine.renderFrames(frameCount: 256)
        let leftAvg =
            leftMix.enumerated().filter { $0.offset % 2 == 0 }.map { abs($0.element) }.reduce(0, +) / 256
        let rightAvg =
            leftMix.enumerated().filter { $0.offset % 2 == 1 }.map { abs($0.element) }.reduce(0, +) / 256
        #expect(leftAvg > 0.2)
        #expect(rightAvg < 0.01)

        // Muda para planar2D à direita e longe (atenuação linear pela metade).
        let atten = CajuAudioAttenuation(
            model: .linear,
            minDistance: 0,
            maxDistance: 10,
            rolloff: 1,
            minGain: 0,
            maxGain: 1
        )
        try engine.setSpatialMode(
            .planar2D(position: CajuVec2(5, 0), attenuation: atten),
            for: leftSource
        )
        // Aquece suavização de ganho/pan e valida canal direito > canal esquerdo.
        _ = try engine.renderFrames(frameCount: 512)
        let planarMix = try engine.renderFrames(frameCount: 256)
        let pLeft =
            planarMix.enumerated().filter { $0.offset % 2 == 0 }.map { abs($0.element) }.reduce(0, +) / 256
        let pRight =
            planarMix.enumerated().filter { $0.offset % 2 == 1 }.map { abs($0.element) }.reduce(0, +) / 256
        #expect(pRight > 0.1)
        #expect(pLeft < 0.02)

        // Movendo o ouvinte para (10, 0), a fonte em (5, 0) passa para a esquerda do ouvinte.
        try engine.setListener(CajuAudioListener(position: CajuVec3(10, 0, 0)))
        _ = try engine.renderFrames(frameCount: 512)
        let movedMix = try engine.renderFrames(frameCount: 256)
        let mLeft =
            movedMix.enumerated().filter { $0.offset % 2 == 0 }.map { abs($0.element) }.reduce(0, +) / 256
        let mRight =
            movedMix.enumerated().filter { $0.offset % 2 == 1 }.map { abs($0.element) }.reduce(0, +) / 256
        #expect(mLeft > 0.1)
        #expect(mRight < 0.02)
    }

    @Test func offlineSpatial3DAttenuatesAndPans() throws {
        let engine = try CajuAudioEngine(
            configuration: CajuAudioConfiguration(backend: .offline, sampleRate: 48_000, channels: 2)
        )
        defer { engine.shutdown() }

        let clip = try engine.createClip(
            pcmFloat32: [Float](repeating: 0.6, count: 4096),
            channels: 1,
            sampleRate: 48_000
        )
        let atten = CajuAudioAttenuation(
            model: .linear,
            minDistance: 1,
            maxDistance: 11,
            rolloff: 1,
            minGain: 0,
            maxGain: 1
        )
        let source = try engine.createSource(
            CajuAudioSourceDescriptor(
                clip: clip,
                isLooping: true,
                spatialMode: .spatial3D(position: CajuVec3(5, 0, 0), attenuation: atten)
            )
        )
        try engine.play(source)
        _ = try engine.renderFrames(frameCount: 1024)
        let nearMix = try engine.renderFrames(frameCount: 256)
        let nearL =
            nearMix.enumerated().filter { $0.offset % 2 == 0 }.map { abs($0.element) }.reduce(0, +) / 256
        let nearR =
            nearMix.enumerated().filter { $0.offset % 2 == 1 }.map { abs($0.element) }.reduce(0, +) / 256
        #expect(nearR > nearL * 2)

        // Move para além de maxDistance -> ganho deve cair para ~0.
        try engine.setPosition3D(CajuVec3(20, 0, 0), for: source)
        _ = try engine.renderFrames(frameCount: 1024)
        let farMix = try engine.renderFrames(frameCount: 256)
        let farMax = farMix.map { abs($0) }.max() ?? 0
        #expect(farMax < 0.01)
    }
}

@Suite("CajuAudio: mixagem, buses, decodificação e erros tipados")
struct CajuAudioMixingAndValidationTests {
    @Test func busHierarchyAndMultiSourceMixing() throws {
        let engine = try CajuAudioEngine(
            configuration: CajuAudioConfiguration(backend: .offline, sampleRate: 48_000, channels: 2)
        )
        defer { engine.shutdown() }

        let masterSfx = try engine.createBus(CajuAudioBusDescriptor(volume: 0.5))
        let subSfx = try engine.createBus(CajuAudioBusDescriptor(volume: 0.5, parent: masterSfx))

        let clip = try engine.createClip(
            pcmFloat32: [Float](repeating: 0.4, count: 1024),
            channels: 1,
            sampleRate: 48_000
        )
        let s1 = try engine.createSource(
            CajuAudioSourceDescriptor(clip: clip, bus: subSfx, isLooping: true)
        )
        let s2 = try engine.createSource(
            CajuAudioSourceDescriptor(clip: clip, bus: subSfx, isLooping: true)
        )
        try engine.play(s1)
        try engine.play(s2)

        // Cada fonte: 0.4 * 0.5 * 0.5 = 0.1; duas fontes somadas ~0.2 em cada canal.
        let mixed = try engine.renderFrames(frameCount: 256)
        let tailSample = abs(mixed[mixed.count - 1])
        #expect(tailSample > 0.15 && tailSample < 0.25)

        try engine.pauseBus(masterSfx)
        let muted = try engine.renderFrames(frameCount: 128)
        #expect(muted.allSatisfy { $0 == 0 })

        try engine.resumeBus(masterSfx)
        let resumed = try engine.renderFrames(frameCount: 128)
        #expect(resumed.contains { abs($0) > 0.15 })

        // Destruir bus pai antes das fontes não causa UAF.
        try engine.destroyBus(masterSfx)
        #expect(
            throws: CajuAudioError.invalidHandle(index: masterSfx.index, generation: masterSfx.generation)
        ) {
            try engine.setBusVolume(1.0, for: masterSfx)
        }
        _ = try engine.renderFrames(frameCount: 64)
        try engine.destroySource(s1)
        try engine.destroySource(s2)
        try engine.destroyBus(subSfx)
    }

    @Test func wavDecodingInMemoryAndClipLifetimeSafety() throws {
        let engine = try CajuAudioEngine(
            configuration: CajuAudioConfiguration(backend: .offline, sampleRate: 48_000, channels: 2)
        )
        defer { engine.shutdown() }

        let pcm = [Int16](repeating: 16_384, count: 512)
        let wav = makeWavBytes(sampleRate: 48_000, channels: 1, samplesInt16: pcm)
        let clip = try engine.createClip(encodedBytes: wav)
        let info = try engine.clipInfo(for: clip)
        #expect(info.channels == 1)
        #expect(info.sampleRate == 48_000)
        #expect(info.frameCount == 512)

        let source = try engine.createSource(CajuAudioSourceDescriptor(clip: clip, isLooping: true))
        try engine.play(source)

        // Destruir clipe com fonte ativa invalida o handle mas mantém o buffer vivo até a fonte morrer.
        try engine.destroyClip(clip)
        #expect(throws: CajuAudioError.invalidHandle(index: clip.index, generation: clip.generation)) {
            _ = try engine.clipInfo(for: clip)
        }
        let frames = try engine.renderFrames(frameCount: 128)
        #expect(frames.contains { abs($0) > 0.1 })

        try engine.destroySource(source)
        #expect(throws: CajuAudioError.invalidHandle(index: source.index, generation: source.generation)) {
            try engine.play(source)
        }
    }

    @Test func rejectsHostileAndInvalidInputsWithTypedErrors() throws {
        #expect(throws: CajuAudioError.invalidConfiguration(.invalidSampleRate)) {
            _ = try CajuAudioEngine(configuration: CajuAudioConfiguration(backend: .null, sampleRate: 0))
        }
        #expect(throws: CajuAudioError.invalidConfiguration(.invalidChannelCount)) {
            _ = try CajuAudioEngine(configuration: CajuAudioConfiguration(backend: .offline, channels: 0))
        }
        #expect(throws: CajuAudioError.invalidConfiguration(.invalidListenerCount)) {
            _ = try CajuAudioEngine(configuration: CajuAudioConfiguration(backend: .null, listenerCount: 8))
        }

        let engine = try CajuAudioEngine(
            configuration: CajuAudioConfiguration(backend: .offline, sampleRate: 48_000, channels: 2)
        )
        defer { engine.shutdown() }

        #expect(throws: CajuAudioError.invalidConfiguration(.emptyBuffer)) {
            _ = try engine.createClip(pcmFloat32: [Float](), channels: 1, sampleRate: 48_000)
        }
        #expect(throws: CajuAudioError.invalidConfiguration(.sampleCountMismatch)) {
            _ = try engine.createClip(pcmFloat32: [0.1, 0.2, 0.3], channels: 2, sampleRate: 48_000)
        }
        #expect(throws: CajuAudioError.invalidConfiguration(.emptyBuffer)) {
            _ = try engine.createClip(encodedBytes: [UInt8]())
        }

        let corruptWav: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x01, 0x00]
        var decodeFailed = false
        do {
            _ = try engine.createClip(encodedBytes: corruptWav)
        } catch {
            decodeFailed = true
        }
        #expect(decodeFailed)

        #expect(throws: CajuAudioError.invalidConfiguration(.invalidVolume)) {
            try engine.setMasterVolume(-0.5)
        }
        #expect(throws: CajuAudioError.invalidConfiguration(.nonFiniteValue)) {
            try engine.setMasterVolume(.nan)
        }

        let clip = try engine.createClip(pcmFloat32: [0.2, 0.2], channels: 1, sampleRate: 48_000)
        #expect(throws: CajuAudioError.invalidConfiguration(.invalidPan)) {
            _ = try engine.createSource(
                CajuAudioSourceDescriptor(clip: clip, spatialMode: .direct2D(pan: 1.5))
            )
        }
        #expect(throws: CajuAudioError.invalidConfiguration(.invalidPitch)) {
            _ = try engine.createSource(
                CajuAudioSourceDescriptor(clip: clip, pitch: 0)
            )
        }
        #expect(throws: CajuAudioError.invalidConfiguration(.invalidDistanceRange)) {
            _ = try engine.createSource(
                CajuAudioSourceDescriptor(
                    clip: clip,
                    spatialMode: .planar2D(
                        attenuation: CajuAudioAttenuation(minDistance: 20, maxDistance: 10)
                    )
                )
            )
        }
        #expect(throws: CajuAudioError.invalidHandle(index: 0, generation: 0)) {
            try engine.play(.null)
        }
    }

    @Test func generationalHandlesInvalidateStaleReferences() throws {
        let engine = try CajuAudioEngine(
            configuration: CajuAudioConfiguration(backend: .offline, sampleRate: 48_000, channels: 2)
        )
        defer { engine.shutdown() }

        let clip1 = try engine.createClip(pcmFloat32: [0.1, 0.2], channels: 1, sampleRate: 48_000)
        try engine.destroyClip(clip1)
        let clip2 = try engine.createClip(pcmFloat32: [0.3, 0.4], channels: 1, sampleRate: 48_000)
        #expect(clip1.index == clip2.index)
        #expect(clip2.generation != clip1.generation)
        #expect(throws: CajuAudioError.invalidHandle(index: clip1.index, generation: clip1.generation)) {
            _ = try engine.clipInfo(for: clip1)
        }

        let bus1 = try engine.createBus()
        try engine.destroyBus(bus1)
        let bus2 = try engine.createBus()
        #expect(bus1.index == bus2.index)
        #expect(bus2.generation != bus1.generation)
        #expect(throws: CajuAudioError.invalidHandle(index: bus1.index, generation: bus1.generation)) {
            try engine.setBusVolume(0.5, for: bus1)
        }

        let src1 = try engine.createSource(CajuAudioSourceDescriptor(clip: clip2, bus: bus2))
        try engine.destroySource(src1)
        let src2 = try engine.createSource(CajuAudioSourceDescriptor(clip: clip2, bus: bus2))
        #expect(src1.index == src2.index)
        #expect(src2.generation != src1.generation)
        #expect(throws: CajuAudioError.invalidHandle(index: src1.index, generation: src1.generation)) {
            try engine.play(src1)
        }
    }
}
