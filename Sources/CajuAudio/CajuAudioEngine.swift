internal import CMiniaudio
import CajuMath

/// Engine de áudio do Caju construída sobre `miniaudio` (`CMiniaudio`).
///
/// Gerencia o dispositivo (ou modo `.null`/`.offline`), clipes decodificados em memória, buses de
/// mixagem hierárquicos, fontes 2D/3D, ouvintes e transições de ciclo de vida (`pause`/`resume`).
/// Assim como `CajuWorld` (`CajuCore`), deve ser operada a partir da thread principal / Game Thread;
/// o *callback* de áudio roda em thread própria do backend sem alocação nem referências Swift.
///
/// ```swift
/// let engine = try CajuAudioEngine(configuration: CajuAudioConfiguration(backend: .null))
/// let clip = try engine.createClip(pcmFloat32: [0, 0.5, 0, -0.5], channels: 1, sampleRate: 48_000)
/// let source = try engine.createSource(CajuAudioSourceDescriptor(clip: clip))
/// try engine.play(source)
/// try engine.pause()
/// try engine.resume()
/// engine.shutdown()
/// ```
public final class CajuAudioEngine {
    private final class ClipRecord {
        var samples: UnsafeMutablePointer<Float>?
        let sampleCount: Int
        let frameCount: UInt64
        let channels: UInt32
        let sampleRate: UInt32
        var activeSourceCount: Int = 0
        var isDestroyed: Bool = false

        init(
            samples: UnsafeMutablePointer<Float>,
            sampleCount: Int,
            frameCount: UInt64,
            channels: UInt32,
            sampleRate: UInt32
        ) {
            self.samples = samples
            self.sampleCount = sampleCount
            self.frameCount = frameCount
            self.channels = channels
            self.sampleRate = sampleRate
        }

        func releaseMemoryIfUnused() {
            if isDestroyed && activeSourceCount == 0, let ptr = samples {
                ptr.deallocate()
                samples = nil
            }
        }

        deinit {
            if let ptr = samples {
                ptr.deallocate()
                samples = nil
            }
        }
    }

    private final class BusRecord {
        var group: UnsafeMutablePointer<ma_sound_group>?
        var parent: BusRecord?
        var activeAttachments: Int = 0
        var isDestroyed: Bool = false

        init(group: UnsafeMutablePointer<ma_sound_group>, parent: BusRecord?) {
            self.group = group
            self.parent = parent
        }

        func uninitIfUnused() {
            if isDestroyed && activeAttachments == 0, let ptr = group {
                ma_sound_group_uninit(ptr)
                ptr.deallocate()
                group = nil
                if let parent {
                    parent.activeAttachments -= 1
                    parent.uninitIfUnused()
                    self.parent = nil
                }
            }
        }
    }

    private final class SourceRecord {
        var sound: UnsafeMutablePointer<ma_sound>?
        var buffer: UnsafeMutablePointer<ma_audio_buffer>?
        let clip: ClipRecord
        var bus: BusRecord?
        var baseVolume: Float
        var spatialMode: CajuAudioSpatialMode

        init(
            sound: UnsafeMutablePointer<ma_sound>,
            buffer: UnsafeMutablePointer<ma_audio_buffer>,
            clip: ClipRecord,
            bus: BusRecord?,
            baseVolume: Float,
            spatialMode: CajuAudioSpatialMode
        ) {
            self.sound = sound
            self.buffer = buffer
            self.clip = clip
            self.bus = bus
            self.baseVolume = baseVolume
            self.spatialMode = spatialMode
        }

        func uninitAndFree() {
            if let soundPtr = sound {
                ma_sound_uninit(soundPtr)
                soundPtr.deallocate()
                sound = nil
            }
            if let bufferPtr = buffer {
                ma_audio_buffer_uninit(bufferPtr)
                bufferPtr.deallocate()
                buffer = nil
            }
            clip.activeSourceCount -= 1
            clip.releaseMemoryIfUnused()
            if let bus {
                bus.activeAttachments -= 1
                bus.uninitIfUnused()
                self.bus = nil
            }
        }
    }

    /// Configuração utilizada na criação da engine.
    public let configuration: CajuAudioConfiguration
    /// Taxa de amostragem efetiva em Hz.
    public let sampleRate: UInt32
    /// Quantidade efetiva de canais de saída.
    public let channels: UInt32
    /// Quantidade de ouvintes configurados.
    public let listenerCount: UInt32

    private var contextPtr: UnsafeMutablePointer<ma_context>?
    private var enginePtr: UnsafeMutablePointer<ma_engine>?

    private var clips = CajuAudioHandlePool<CajuAudioClipTag, ClipRecord>()
    private var buses = CajuAudioHandlePool<CajuAudioBusTag, BusRecord>()
    private var sources = CajuAudioHandlePool<CajuAudioSourceTag, SourceRecord>()
    // Mantém lista de fontes ativas para limpeza determinística e atualização de fontes 2D.
    private var liveSources: [SourceRecord] = []
    private var liveBuses: [BusRecord] = []
    private var liveClips: [ClipRecord] = []

    private var listeners: [CajuAudioListener]
    public private(set) var lifecycleState: CajuAudioLifecycleState
    public private(set) var isShutdown: Bool = false

    /// Indica se a engine está pausada (dispositivo parado ou modo offline em pausa).
    public var isPaused: Bool { lifecycleState != .running }

    /// Quantidade total de quadros PCM processados pelo grafo até o momento.
    public var playedFrames: UInt64 {
        guard !isShutdown, let enginePtr else { return 0 }
        return ma_engine_get_time_in_pcm_frames(enginePtr)
    }

    /// Volume mestre linear (`0` = silêncio, `1` = unitário).
    public var masterVolume: Float {
        guard !isShutdown, let enginePtr else { return 0 }
        return ma_engine_get_volume(enginePtr)
    }

    /// Resumo de diagnóstico da engine.
    public var diagnostics: CajuAudioDiagnostics {
        CajuAudioDiagnostics(
            backend: configuration.backend,
            sampleRate: sampleRate,
            channels: channels,
            activeClips: clips.count,
            activeBuses: buses.count,
            activeSources: sources.count,
            playedFrames: playedFrames,
            isPaused: isPaused,
            isShutdown: isShutdown
        )
    }

    /// Inicializa a engine de áudio com a configuração fornecida.
    public init(configuration: CajuAudioConfiguration = CajuAudioConfiguration()) throws(CajuAudioError) {
        try Self.validateConfiguration(configuration)
        self.configuration = configuration

        var allocatedContext: UnsafeMutablePointer<ma_context>?
        if configuration.backend == .null {
            let ctx = UnsafeMutablePointer<ma_context>.allocate(capacity: 1)
            ctx.initialize(to: ma_context())
            var nullBackend = ma_backend_null
            let ctxResult = ma_context_init(&nullBackend, 1, nil, ctx)
            if ctxResult != MA_SUCCESS {
                ctx.deallocate()
                throw CajuAudioMiniaudioMap.mapError(ctxResult)
            }
            allocatedContext = ctx
        }

        let eng = UnsafeMutablePointer<ma_engine>.allocate(capacity: 1)
        eng.initialize(to: ma_engine())

        var engineConfig = ma_engine_config_init()
        engineConfig.listenerCount = configuration.listenerCount
        engineConfig.channels = configuration.channels
        engineConfig.sampleRate = configuration.sampleRate
        engineConfig.periodSizeInFrames = configuration.periodSizeInFrames

        switch configuration.backend {
        case .automatic:
            engineConfig.noDevice = 0
            engineConfig.noAutoStart = configuration.startImmediately ? 0 : 1
            engineConfig.dataCallback = cajuAudioDataCallback
        case .null:
            engineConfig.pContext = allocatedContext
            engineConfig.noDevice = 0
            engineConfig.noAutoStart = configuration.startImmediately ? 0 : 1
            engineConfig.dataCallback = cajuAudioDataCallback
        case .offline:
            engineConfig.noDevice = 1
            engineConfig.noAutoStart = 1
        }

        let initResult = ma_engine_init(&engineConfig, eng)
        if initResult != MA_SUCCESS {
            eng.deallocate()
            if let ctx = allocatedContext {
                _ = ma_context_uninit(ctx)
                ctx.deallocate()
            }
            throw CajuAudioMiniaudioMap.mapError(initResult)
        }

        self.contextPtr = allocatedContext
        self.enginePtr = eng
        self.sampleRate = ma_engine_get_sample_rate(eng)
        self.channels = ma_engine_get_channels(eng)
        self.listenerCount = ma_engine_get_listener_count(eng)
        self.listeners = Array(
            repeating: CajuAudioListener(),
            count: Int(max(1, self.listenerCount))
        )
        self.lifecycleState = configuration.startImmediately ? .running : .paused

        for index in 0..<self.listeners.count {
            applyListenerToMiniaudio(self.listeners[index], at: UInt32(index), engine: eng)
        }
    }

    deinit {
        shutdown()
    }

    /// Encerra a engine de áudio, para o dispositivo e libera todos os recursos alocados.
    ///
    /// É idempotente: chamadas repetidas não têm efeito. Após o encerramento, qualquer operação
    /// na engine falha com `CajuAudioError.alreadyShutdown`.
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        lifecycleState = .stopped

        if let enginePtr {
            if configuration.backend != .offline {
                _ = ma_engine_stop(enginePtr)
            }

            // Desinicializa fontes antes de buses e clipes para garantir desacoplamento do grafo.
            for source in liveSources {
                source.uninitAndFree()
            }
            liveSources.removeAll(keepingCapacity: false)
            sources.removeAll()

            // Desinicializa buses em ordem reversa (filhos antes dos pais).
            for bus in liveBuses.reversed() {
                if let ptr = bus.group {
                    ma_sound_group_uninit(ptr)
                    ptr.deallocate()
                    bus.group = nil
                }
                bus.parent = nil
                bus.activeAttachments = 0
            }
            liveBuses.removeAll(keepingCapacity: false)
            buses.removeAll()

            for clip in liveClips {
                if let ptr = clip.samples {
                    ptr.deallocate()
                    clip.samples = nil
                }
            }
            liveClips.removeAll(keepingCapacity: false)
            clips.removeAll()

            ma_engine_uninit(enginePtr)
            enginePtr.deallocate()
            self.enginePtr = nil
        }

        if let contextPtr {
            _ = ma_context_uninit(contextPtr)
            contextPtr.deallocate()
            self.contextPtr = nil
        }
    }

    // MARK: Ciclo de vida e volume mestre

    /// Pausa a reprodução do dispositivo de áudio (idempotente).
    public func pause() throws(CajuAudioError) {
        let enginePtr = try requireEngine()
        guard lifecycleState != .paused else { return }
        if configuration.backend != .offline {
            try CajuAudioMiniaudioMap.check(ma_engine_stop(enginePtr))
        }
        lifecycleState = .paused
    }

    /// Retoma a reprodução do dispositivo de áudio (idempotente).
    public func resume() throws(CajuAudioError) {
        let enginePtr = try requireEngine()
        guard lifecycleState != .running else { return }
        if configuration.backend != .offline {
            try CajuAudioMiniaudioMap.check(ma_engine_start(enginePtr))
        }
        lifecycleState = .running
    }

    /// Aplica um evento de ciclo de vida à engine, pausando em segundo plano/inatividade e
    /// retomando ao voltar ao primeiro plano ativo.
    @discardableResult
    public func handleLifecycle(_ event: CajuAudioLifecycleEvent) throws(CajuAudioError)
        -> CajuAudioLifecycleState
    {
        if isShutdown {
            if event == .willTerminate {
                return .stopped
            }
            throw .alreadyShutdown
        }
        switch event {
        case .willResignActive, .didEnterBackground:
            try pause()
        case .didBecomeActive:
            try resume()
        case .willEnterForeground, .lowMemory:
            break
        case .willTerminate:
            shutdown()
        }
        return lifecycleState
    }

    /// Ajusta o volume mestre linear da engine (`>= 0`).
    public func setMasterVolume(_ volume: Float) throws(CajuAudioError) {
        let enginePtr = try requireEngine()
        try Self.validateVolume(volume)
        try CajuAudioMiniaudioMap.check(ma_engine_set_volume(enginePtr, volume))
    }

    // MARK: Renderização offline (testes determinísticos)

    /// Puxa e mistura `buffer.count / Int(channels)` quadros PCM no modo `.offline`.
    ///
    /// Quando pausada, preenche `buffer` com silêncio sem avançar o grafo.
    @discardableResult
    public func renderFrames(into buffer: UnsafeMutableBufferPointer<Float>) throws(CajuAudioError) -> UInt64
    {
        let enginePtr = try requireEngine()
        guard configuration.backend == .offline else {
            throw .invalidConfiguration(.unsupportedInDeviceMode)
        }
        let ch = Int(channels)
        guard ch > 0, !buffer.isEmpty, buffer.count % ch == 0, let base = buffer.baseAddress else {
            throw .invalidConfiguration(.sampleCountMismatch)
        }
        let requestedFrames = UInt64(buffer.count / ch)
        if lifecycleState != .running {
            buffer.initialize(repeating: 0)
            return requestedFrames
        }
        var framesRead: UInt64 = 0
        try CajuAudioMiniaudioMap.check(
            ma_engine_read_pcm_frames(enginePtr, base, requestedFrames, &framesRead)
        )
        return framesRead
    }

    /// Versão de conveniência para testes que retorna um array intercalado `Float32` no modo `.offline`.
    public func renderFrames(frameCount: Int) throws(CajuAudioError) -> [Float] {
        _ = try requireEngine()
        guard configuration.backend == .offline else {
            throw .invalidConfiguration(.unsupportedInDeviceMode)
        }
        guard frameCount > 0 else {
            throw .invalidConfiguration(.emptyBuffer)
        }
        let (totalSamples, overflow) = frameCount.multipliedReportingOverflow(by: Int(channels))
        guard !overflow, totalSamples > 0 else {
            throw .outOfMemory
        }
        var output = [Float](repeating: 0, count: totalSamples)
        try output.withUnsafeMutableBufferPointer { ptr throws(CajuAudioError) in
            _ = try renderFrames(into: ptr)
        }
        return output
    }

    // MARK: Clipes

    /// Cria um clipe a partir de amostras `Float32` intercaladas em memória.
    public func createClip(
        pcmFloat32 samples: UnsafeBufferPointer<Float>,
        channels clipChannels: UInt32,
        sampleRate clipSampleRate: UInt32
    ) throws(CajuAudioError) -> CajuAudioClipHandle {
        _ = try requireEngine()
        guard clipChannels > 0, clipChannels <= 32 else {
            throw .invalidConfiguration(.invalidChannelCount)
        }
        guard clipSampleRate > 0 else {
            throw .invalidConfiguration(.invalidSampleRate)
        }
        guard !samples.isEmpty, let srcBase = samples.baseAddress else {
            throw .invalidConfiguration(.emptyBuffer)
        }
        let ch = Int(clipChannels)
        guard samples.count % ch == 0 else {
            throw .invalidConfiguration(.sampleCountMismatch)
        }
        let frameCount = UInt64(samples.count / ch)

        let rawSamples = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
        rawSamples.initialize(from: srcBase, count: samples.count)

        let record = ClipRecord(
            samples: rawSamples,
            sampleCount: samples.count,
            frameCount: frameCount,
            channels: clipChannels,
            sampleRate: clipSampleRate
        )
        do {
            let handle = try clips.insert(record)
            liveClips.append(record)
            return handle
        } catch {
            rawSamples.deallocate()
            record.samples = nil
            throw error
        }
    }

    /// Cria um clipe copiando um array de amostras `Float32` intercaladas.
    public func createClip(
        pcmFloat32 samples: [Float],
        channels clipChannels: UInt32,
        sampleRate clipSampleRate: UInt32
    ) throws(CajuAudioError) -> CajuAudioClipHandle {
        try samples.withUnsafeBufferPointer { ptr throws(CajuAudioError) in
            try createClip(pcmFloat32: ptr, channels: clipChannels, sampleRate: clipSampleRate)
        }
    }

    /// Decodifica um arquivo de áudio em memória (WAV, FLAC ou MP3) para PCM `Float32`.
    public func createClip(
        encodedBytes: UnsafeRawBufferPointer,
        targetChannels: UInt32 = 0,
        targetSampleRate: UInt32 = 0
    ) throws(CajuAudioError) -> CajuAudioClipHandle {
        _ = try requireEngine()
        guard !encodedBytes.isEmpty, let rawBase = encodedBytes.baseAddress else {
            throw .invalidConfiguration(.emptyBuffer)
        }
        if targetChannels > 32 {
            throw .invalidConfiguration(.invalidChannelCount)
        }

        var decoderConfig = ma_decoder_config_init(ma_format_f32, targetChannels, targetSampleRate)
        var frameCount: ma_uint64 = 0
        var decodedPtr: UnsafeMutableRawPointer?

        let decodeResult = ma_decode_memory(
            rawBase,
            encodedBytes.count,
            &decoderConfig,
            &frameCount,
            &decodedPtr
        )
        if decodeResult != MA_SUCCESS {
            if let decodedPtr {
                ma_free(decodedPtr, nil)
            }
            throw CajuAudioMiniaudioMap.mapError(decodeResult)
        }

        guard let decodedPtr else {
            throw .invalidData
        }
        defer { ma_free(decodedPtr, nil) }

        let decodedChannels = decoderConfig.channels
        let decodedSampleRate = decoderConfig.sampleRate
        guard decodedChannels > 0, decodedSampleRate > 0, frameCount > 0 else {
            throw .invalidData
        }

        let (totalSamplesU64, overflow) = frameCount.multipliedReportingOverflow(by: UInt64(decodedChannels))
        guard !overflow, totalSamplesU64 <= UInt64(Int.max) else {
            throw .outOfMemory
        }
        let floatPtr = decodedPtr.assumingMemoryBound(to: Float.self)
        let buffer = UnsafeBufferPointer(start: floatPtr, count: Int(totalSamplesU64))
        return try createClip(
            pcmFloat32: buffer,
            channels: decodedChannels,
            sampleRate: decodedSampleRate
        )
    }

    /// Decodifica bytes codificados (WAV, FLAC ou MP3) de um array `[UInt8]`.
    public func createClip(
        encodedBytes: [UInt8],
        targetChannels: UInt32 = 0,
        targetSampleRate: UInt32 = 0
    ) throws(CajuAudioError) -> CajuAudioClipHandle {
        let result: Result<CajuAudioClipHandle, CajuAudioError> = encodedBytes.withUnsafeBytes { raw in
            do throws(CajuAudioError) {
                return .success(
                    try createClip(
                        encodedBytes: raw,
                        targetChannels: targetChannels,
                        targetSampleRate: targetSampleRate
                    )
                )
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// Retorna os metadados de um clipe ativo.
    public func clipInfo(for handle: CajuAudioClipHandle) throws(CajuAudioError) -> CajuAudioClipInfo {
        _ = try requireEngine()
        let record = try clips.require(handle)
        return CajuAudioClipInfo(
            channels: record.channels,
            sampleRate: record.sampleRate,
            frameCount: record.frameCount
        )
    }

    /// Destrói um clipe. Se fontes ainda estiverem ligadas a ele, o buffer PCM é liberado assim
    /// que a última fonte for destruída.
    public func destroyClip(_ handle: CajuAudioClipHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        guard let record = clips.remove(handle) else {
            throw .invalidHandle(index: handle.index, generation: handle.generation)
        }
        record.isDestroyed = true
        record.releaseMemoryIfUnused()
        liveClips.removeAll { $0 === record }
    }

    // MARK: Buses de mixagem

    /// Cria um bus de mixagem que pode encaminhar fontes para o endpoint ou para outro bus pai.
    public func createBus(_ descriptor: CajuAudioBusDescriptor = CajuAudioBusDescriptor())
        throws(CajuAudioError) -> CajuAudioBusHandle
    {
        let enginePtr = try requireEngine()
        try Self.validateVolume(descriptor.volume)
        try Self.validatePan(descriptor.pan)
        try Self.validatePitch(descriptor.pitch)

        var parentRecord: BusRecord?
        if let parentHandle = descriptor.parent {
            parentRecord = try buses.require(parentHandle)
        }

        let groupPtr = UnsafeMutablePointer<ma_sound_group>.allocate(capacity: 1)
        groupPtr.initialize(to: ma_sound_group())

        let initResult = ma_sound_group_init(enginePtr, 0, parentRecord?.group, groupPtr)
        if initResult != MA_SUCCESS {
            groupPtr.deallocate()
            throw CajuAudioMiniaudioMap.mapError(initResult)
        }

        ma_sound_group_set_volume(groupPtr, descriptor.volume)
        ma_sound_group_set_pan(groupPtr, descriptor.pan)
        ma_sound_group_set_pitch(groupPtr, descriptor.pitch)
        ma_sound_group_set_spatialization_enabled(groupPtr, 0)

        let record = BusRecord(group: groupPtr, parent: parentRecord)
        do {
            let handle = try buses.insert(record)
            parentRecord?.activeAttachments += 1
            liveBuses.append(record)
            return handle
        } catch {
            ma_sound_group_uninit(groupPtr)
            groupPtr.deallocate()
            throw error
        }
    }

    /// Ajusta o volume linear de um bus (`>= 0`).
    public func setBusVolume(_ volume: Float, for bus: CajuAudioBusHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        try Self.validateVolume(volume)
        let record = try buses.require(bus)
        guard let group = record.group else { throw .invalidState }
        ma_sound_group_set_volume(group, volume)
    }

    /// Ajusta o *pan* estéreo de um bus (`[-1, 1]`).
    public func setBusPan(_ pan: Float, for bus: CajuAudioBusHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        try Self.validatePan(pan)
        let record = try buses.require(bus)
        guard let group = record.group else { throw .invalidState }
        ma_sound_group_set_pan(group, pan)
    }

    /// Ajusta o *pitch* de um bus (`> 0`).
    public func setBusPitch(_ pitch: Float, for bus: CajuAudioBusHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        try Self.validatePitch(pitch)
        let record = try buses.require(bus)
        guard let group = record.group else { throw .invalidState }
        ma_sound_group_set_pitch(group, pitch)
    }

    /// Pausa todas as fontes ligadas a um bus.
    public func pauseBus(_ bus: CajuAudioBusHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        let record = try buses.require(bus)
        guard let group = record.group else { throw .invalidState }
        try CajuAudioMiniaudioMap.check(ma_sound_group_stop(group))
    }

    /// Retoma a reprodução de um bus pausado.
    public func resumeBus(_ bus: CajuAudioBusHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        let record = try buses.require(bus)
        guard let group = record.group else { throw .invalidState }
        try CajuAudioMiniaudioMap.check(ma_sound_group_start(group))
    }

    /// Remove um bus de mixagem. Caso ainda possua fontes ou sub-buses acoplados, o nó é liberado
    /// quando o último filho for destruído.
    public func destroyBus(_ bus: CajuAudioBusHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        guard let record = buses.remove(bus) else {
            throw .invalidHandle(index: bus.index, generation: bus.generation)
        }
        record.isDestroyed = true
        record.uninitIfUnused()
        if record.group == nil {
            liveBuses.removeAll { $0 === record }
        }
    }

    // MARK: Ouvintes

    /// Atualiza os parâmetros de um ouvinte 3D e recalcula fontes 2D ligadas ao ouvinte `0`.
    public func setListener(_ listener: CajuAudioListener, at index: UInt32 = 0) throws(CajuAudioError) {
        let enginePtr = try requireEngine()
        guard index < listenerCount, Int(index) < listeners.count else {
            throw .invalidConfiguration(.invalidListenerCount)
        }
        try Self.validateListener(listener)
        listeners[Int(index)] = listener
        applyListenerToMiniaudio(listener, at: index, engine: enginePtr)

        if index == 0 {
            refreshPlanar2DSources()
        }
    }

    /// Retorna o estado atual de um ouvinte configurado.
    public func listener(at index: UInt32 = 0) throws(CajuAudioError) -> CajuAudioListener {
        _ = try requireEngine()
        guard index < listenerCount, Int(index) < listeners.count else {
            throw .invalidConfiguration(.invalidListenerCount)
        }
        return listeners[Int(index)]
    }

    // MARK: Fontes sonoras

    /// Cria uma instância de fonte sonora 2D ou 3D a partir de um clipe carregado.
    public func createSource(_ descriptor: CajuAudioSourceDescriptor)
        throws(CajuAudioError) -> CajuAudioSourceHandle
    {
        let enginePtr = try requireEngine()
        try Self.validateVolume(descriptor.volume)
        try Self.validatePitch(descriptor.pitch)
        try Self.validateSpatialMode(descriptor.spatialMode, listenerCount: listenerCount)

        let clipRecord = try clips.require(descriptor.clip)
        guard let samplePtr = clipRecord.samples else {
            throw .invalidState
        }

        var busRecord: BusRecord?
        if let busHandle = descriptor.bus {
            busRecord = try buses.require(busHandle)
        }

        let bufferPtr = UnsafeMutablePointer<ma_audio_buffer>.allocate(capacity: 1)
        bufferPtr.initialize(to: ma_audio_buffer())
        var bufferConfig = ma_audio_buffer_config_init(
            ma_format_f32,
            clipRecord.channels,
            clipRecord.frameCount,
            samplePtr,
            nil
        )
        bufferConfig.sampleRate = clipRecord.sampleRate

        let bufResult = ma_audio_buffer_init(&bufferConfig, bufferPtr)
        if bufResult != MA_SUCCESS {
            bufferPtr.deallocate()
            throw CajuAudioMiniaudioMap.mapError(bufResult)
        }

        let soundPtr = UnsafeMutablePointer<ma_sound>.allocate(capacity: 1)
        soundPtr.initialize(to: ma_sound())
        let sndResult = ma_sound_init_from_data_source(
            enginePtr,
            UnsafeMutableRawPointer(bufferPtr),
            0,
            busRecord?.group,
            soundPtr
        )
        if sndResult != MA_SUCCESS {
            ma_audio_buffer_uninit(bufferPtr)
            bufferPtr.deallocate()
            soundPtr.deallocate()
            throw CajuAudioMiniaudioMap.mapError(sndResult)
        }

        ma_sound_set_pitch(soundPtr, descriptor.pitch)
        ma_sound_set_looping(soundPtr, descriptor.isLooping ? 1 : 0)

        let record = SourceRecord(
            sound: soundPtr,
            buffer: bufferPtr,
            clip: clipRecord,
            bus: busRecord,
            baseVolume: descriptor.volume,
            spatialMode: descriptor.spatialMode
        )

        do {
            let handle = try sources.insert(record)
            clipRecord.activeSourceCount += 1
            busRecord?.activeAttachments += 1
            liveSources.append(record)
            applySpatialMode(descriptor.spatialMode, baseVolume: descriptor.volume, to: soundPtr)
            return handle
        } catch {
            ma_sound_uninit(soundPtr)
            soundPtr.deallocate()
            ma_audio_buffer_uninit(bufferPtr)
            bufferPtr.deallocate()
            throw error
        }
    }

    /// Inicia ou retoma a reprodução de uma fonte sonora.
    public func play(_ source: CajuAudioSourceHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        try CajuAudioMiniaudioMap.check(ma_sound_start(sound))
    }

    /// Pausa/interrompe a reprodução de uma fonte sonora preservando o cursor.
    public func stop(_ source: CajuAudioSourceHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        try CajuAudioMiniaudioMap.check(ma_sound_stop(sound))
    }

    /// Reposiciona o cursor da fonte para o início (quadro `0`).
    public func rewind(_ source: CajuAudioSourceHandle) throws(CajuAudioError) {
        try seek(source, toFrame: 0)
    }

    /// Reposiciona o cursor da fonte para o quadro PCM informado.
    public func seek(_ source: CajuAudioSourceHandle, toFrame frame: UInt64) throws(CajuAudioError) {
        _ = try requireEngine()
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        guard frame <= record.clip.frameCount else {
            throw .invalidConfiguration(.sampleCountMismatch)
        }
        try CajuAudioMiniaudioMap.check(ma_sound_seek_to_pcm_frame(sound, frame))
    }

    /// Indica se a fonte está atualmente tocando.
    public func isPlaying(_ source: CajuAudioSourceHandle) throws(CajuAudioError) -> Bool {
        _ = try requireEngine()
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        return ma_sound_is_playing(sound) != 0
    }

    /// Indica se a fonte atingiu o fim do clipe.
    public func isAtEnd(_ source: CajuAudioSourceHandle) throws(CajuAudioError) -> Bool {
        _ = try requireEngine()
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        return ma_sound_at_end(sound) != 0
    }

    /// Atualiza o volume linear base da fonte (`>= 0`).
    public func setVolume(_ volume: Float, for source: CajuAudioSourceHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        try Self.validateVolume(volume)
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        record.baseVolume = volume
        applySpatialMode(record.spatialMode, baseVolume: volume, to: sound)
    }

    /// Atualiza o *pitch* da fonte (`> 0`).
    public func setPitch(_ pitch: Float, for source: CajuAudioSourceHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        try Self.validatePitch(pitch)
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        ma_sound_set_pitch(sound, pitch)
    }

    /// Configura repetição contínua da fonte.
    public func setLooping(_ isLooping: Bool, for source: CajuAudioSourceHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        ma_sound_set_looping(sound, isLooping ? 1 : 0)
    }

    /// Atualiza o modo espacial (2D direto, 2D planar ou 3D) de uma fonte ativa.
    public func setSpatialMode(_ mode: CajuAudioSpatialMode, for source: CajuAudioSourceHandle)
        throws(CajuAudioError)
    {
        _ = try requireEngine()
        try Self.validateSpatialMode(mode, listenerCount: listenerCount)
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        record.spatialMode = mode
        applySpatialMode(mode, baseVolume: record.baseVolume, to: sound)
    }

    /// Atualiza a posição 2D de uma fonte `.planar2D` ou converte `.direct2D` para `.planar2D`.
    public func setPosition2D(_ position: CajuVec2, for source: CajuAudioSourceHandle)
        throws(CajuAudioError)
    {
        _ = try requireEngine()
        try Self.validateVec2(position)
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        let newMode: CajuAudioSpatialMode
        switch record.spatialMode {
        case .planar2D(_, let attenuation):
            newMode = .planar2D(position: position, attenuation: attenuation)
        case .direct2D, .spatial3D:
            newMode = .planar2D(position: position, attenuation: .default)
        }
        record.spatialMode = newMode
        applySpatialMode(newMode, baseVolume: record.baseVolume, to: sound)
    }

    /// Atualiza posição (e opcionalmente velocidade) de uma fonte 3D.
    public func setPosition3D(
        _ position: CajuVec3,
        velocity: CajuVec3? = nil,
        for source: CajuAudioSourceHandle
    ) throws(CajuAudioError) {
        _ = try requireEngine()
        try Self.validateVec3(position)
        if let velocity {
            try Self.validateVec3(velocity)
        }
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }

        switch record.spatialMode {
        case .spatial3D(
            _,
            let direction,
            let currentVelocity,
            let positioning,
            let attenuation,
            let cone,
            let dopplerFactor,
            let directionalAttenuationFactor,
            let pinnedListenerIndex
        ):
            let updatedVelocity = velocity ?? currentVelocity
            record.spatialMode = .spatial3D(
                position: position,
                direction: direction,
                velocity: updatedVelocity,
                positioning: positioning,
                attenuation: attenuation,
                cone: cone,
                dopplerFactor: dopplerFactor,
                directionalAttenuationFactor: directionalAttenuationFactor,
                pinnedListenerIndex: pinnedListenerIndex
            )
            ma_sound_set_position(sound, position.x, position.y, position.z)
            if let velocity {
                ma_sound_set_velocity(sound, velocity.x, velocity.y, velocity.z)
            }
        case .direct2D, .planar2D:
            let mode: CajuAudioSpatialMode = .spatial3D(
                position: position,
                velocity: velocity ?? .zero
            )
            record.spatialMode = mode
            applySpatialMode(mode, baseVolume: record.baseVolume, to: sound)
        }
    }

    /// Aplica *fade* linear de volume na fonte em milissegundos.
    public func setFade(
        for source: CajuAudioSourceHandle,
        from startVolume: Float,
        to endVolume: Float,
        durationMilliseconds: UInt64
    ) throws(CajuAudioError) {
        _ = try requireEngine()
        try Self.validateVolume(startVolume)
        try Self.validateVolume(endVolume)
        let record = try sources.require(source)
        guard let sound = record.sound else { throw .invalidState }
        ma_sound_set_fade_in_milliseconds(sound, startVolume, endVolume, durationMilliseconds)
    }

    /// Para, desacopla e libera uma fonte sonora.
    public func destroySource(_ source: CajuAudioSourceHandle) throws(CajuAudioError) {
        _ = try requireEngine()
        guard let record = sources.remove(source) else {
            throw .invalidHandle(index: source.index, generation: source.generation)
        }
        record.uninitAndFree()
        liveSources.removeAll { $0 === record }
    }

    // MARK: Auxiliares internos

    private func requireEngine() throws(CajuAudioError) -> UnsafeMutablePointer<ma_engine> {
        guard !isShutdown, let enginePtr else {
            throw .alreadyShutdown
        }
        return enginePtr
    }

    private func applyListenerToMiniaudio(
        _ listener: CajuAudioListener,
        at index: UInt32,
        engine: UnsafeMutablePointer<ma_engine>
    ) {
        ma_engine_listener_set_enabled(engine, index, listener.isEnabled ? 1 : 0)
        ma_engine_listener_set_position(
            engine, index, listener.position.x, listener.position.y, listener.position.z)
        ma_engine_listener_set_direction(
            engine, index, listener.forward.x, listener.forward.y, listener.forward.z)
        ma_engine_listener_set_world_up(engine, index, listener.up.x, listener.up.y, listener.up.z)
        ma_engine_listener_set_velocity(
            engine, index, listener.velocity.x, listener.velocity.y, listener.velocity.z)
        if let cone = listener.cone {
            ma_engine_listener_set_cone(
                engine,
                index,
                cone.innerAngleRadians,
                cone.outerAngleRadians,
                cone.outerGain
            )
        } else {
            ma_engine_listener_set_cone(engine, index, 2 * .pi, 2 * .pi, 1)
        }
    }

    private func applySpatialMode(
        _ mode: CajuAudioSpatialMode,
        baseVolume: Float,
        to sound: UnsafeMutablePointer<ma_sound>
    ) {
        switch mode {
        case .direct2D(let pan):
            ma_sound_set_spatialization_enabled(sound, 0)
            ma_sound_set_volume(sound, baseVolume)
            ma_sound_set_pan(sound, pan)

        case .planar2D(let position, let attenuation):
            ma_sound_set_spatialization_enabled(sound, 0)
            let primaryListener = listeners[0]
            let right3D = primaryListener.forward.cross(primaryListener.up)
            let right2D = right3D.xy.normalized() ?? .unitX
            let evaluated = CajuAudioSpatialMath.evaluate2D(
                sourcePosition: position,
                listenerPosition: primaryListener.position.xy,
                listenerRight: right2D,
                attenuation: attenuation,
                baseVolume: baseVolume
            )
            ma_sound_set_volume(sound, evaluated.volume)
            ma_sound_set_pan(sound, evaluated.pan)

        case .spatial3D(
            let position,
            let direction,
            let velocity,
            let positioning,
            let attenuation,
            let cone,
            let dopplerFactor,
            let directionalAttenuationFactor,
            let pinnedListenerIndex
        ):
            ma_sound_set_spatialization_enabled(sound, 1)
            ma_sound_set_volume(sound, baseVolume)
            ma_sound_set_pan(sound, 0)
            ma_sound_set_position(sound, position.x, position.y, position.z)
            ma_sound_set_direction(sound, direction.x, direction.y, direction.z)
            ma_sound_set_velocity(sound, velocity.x, velocity.y, velocity.z)
            ma_sound_set_positioning(sound, CajuAudioMiniaudioMap.positioning(positioning))
            ma_sound_set_attenuation_model(sound, CajuAudioMiniaudioMap.attenuationModel(attenuation.model))
            ma_sound_set_min_distance(sound, attenuation.minDistance)
            ma_sound_set_max_distance(sound, attenuation.maxDistance)
            ma_sound_set_rolloff(sound, attenuation.rolloff)
            ma_sound_set_min_gain(sound, attenuation.minGain)
            ma_sound_set_max_gain(sound, attenuation.maxGain)
            ma_sound_set_doppler_factor(sound, dopplerFactor)
            ma_sound_set_directional_attenuation_factor(sound, directionalAttenuationFactor)
            if let pinnedListenerIndex {
                ma_sound_set_pinned_listener_index(sound, pinnedListenerIndex)
            }
            if let cone {
                ma_sound_set_cone(
                    sound,
                    cone.innerAngleRadians,
                    cone.outerAngleRadians,
                    cone.outerGain
                )
            } else {
                ma_sound_set_cone(sound, 2 * .pi, 2 * .pi, 1)
            }
        }
    }

    private func refreshPlanar2DSources() {
        for record in liveSources {
            if case .planar2D = record.spatialMode, let sound = record.sound {
                applySpatialMode(record.spatialMode, baseVolume: record.baseVolume, to: sound)
            }
        }
    }

    // MARK: Validação de entrada

    private static func validateConfiguration(_ config: CajuAudioConfiguration) throws(CajuAudioError) {
        if config.listenerCount == 0 || config.listenerCount > CajuAudioConfiguration.maxListeners {
            throw .invalidConfiguration(.invalidListenerCount)
        }
        switch config.backend {
        case .automatic:
            if config.channels > 32 {
                throw .invalidConfiguration(.invalidChannelCount)
            }
        case .null, .offline:
            if config.sampleRate == 0 {
                throw .invalidConfiguration(.invalidSampleRate)
            }
            if config.channels == 0 || config.channels > 32 {
                throw .invalidConfiguration(.invalidChannelCount)
            }
        }
    }

    private static func validateVolume(_ volume: Float) throws(CajuAudioError) {
        guard volume.isFinite else { throw .invalidConfiguration(.nonFiniteValue) }
        guard volume >= 0 else { throw .invalidConfiguration(.invalidVolume) }
    }

    private static func validatePitch(_ pitch: Float) throws(CajuAudioError) {
        guard pitch.isFinite else { throw .invalidConfiguration(.nonFiniteValue) }
        guard pitch > 0 else { throw .invalidConfiguration(.invalidPitch) }
    }

    private static func validatePan(_ pan: Float) throws(CajuAudioError) {
        guard pan.isFinite else { throw .invalidConfiguration(.nonFiniteValue) }
        guard pan >= -1, pan <= 1 else { throw .invalidConfiguration(.invalidPan) }
    }

    private static func validateVec2(_ v: CajuVec2) throws(CajuAudioError) {
        guard v.isFinite else { throw .invalidConfiguration(.nonFiniteValue) }
    }

    private static func validateVec3(_ v: CajuVec3) throws(CajuAudioError) {
        guard v.isFinite else { throw .invalidConfiguration(.nonFiniteValue) }
    }

    private static func validateCone(_ cone: CajuAudioCone) throws(CajuAudioError) {
        guard cone.innerAngleRadians.isFinite, cone.outerAngleRadians.isFinite, cone.outerGain.isFinite
        else {
            throw .invalidConfiguration(.nonFiniteValue)
        }
        guard cone.innerAngleRadians >= 0,
            cone.outerAngleRadians >= cone.innerAngleRadians,
            cone.outerAngleRadians <= 2 * .pi,
            cone.outerGain >= 0,
            cone.outerGain <= 1
        else {
            throw .invalidConfiguration(.invalidConeAngles)
        }
    }

    private static func validateAttenuation(_ attenuation: CajuAudioAttenuation) throws(CajuAudioError) {
        guard attenuation.minDistance.isFinite, attenuation.maxDistance.isFinite,
            attenuation.rolloff.isFinite, attenuation.minGain.isFinite, attenuation.maxGain.isFinite
        else {
            throw .invalidConfiguration(.nonFiniteValue)
        }
        guard attenuation.minDistance >= 0, attenuation.maxDistance >= attenuation.minDistance else {
            throw .invalidConfiguration(.invalidDistanceRange)
        }
        guard attenuation.rolloff >= 0 else {
            throw .invalidConfiguration(.invalidRolloff)
        }
        guard attenuation.minGain >= 0, attenuation.maxGain >= attenuation.minGain else {
            throw .invalidConfiguration(.invalidVolume)
        }
    }

    private static func validateListener(_ listener: CajuAudioListener) throws(CajuAudioError) {
        try validateVec3(listener.position)
        try validateVec3(listener.forward)
        try validateVec3(listener.up)
        try validateVec3(listener.velocity)
        if let cone = listener.cone {
            try validateCone(cone)
        }
    }

    private static func validateSpatialMode(_ mode: CajuAudioSpatialMode, listenerCount: UInt32)
        throws(CajuAudioError)
    {
        switch mode {
        case .direct2D(let pan):
            try validatePan(pan)
        case .planar2D(let position, let attenuation):
            try validateVec2(position)
            try validateAttenuation(attenuation)
        case .spatial3D(
            let position,
            let direction,
            let velocity,
            _,
            let attenuation,
            let cone,
            let dopplerFactor,
            let directionalAttenuationFactor,
            let pinnedListenerIndex
        ):
            try validateVec3(position)
            try validateVec3(direction)
            try validateVec3(velocity)
            try validateAttenuation(attenuation)
            if let cone {
                try validateCone(cone)
            }
            guard dopplerFactor.isFinite, dopplerFactor >= 0,
                directionalAttenuationFactor.isFinite, directionalAttenuationFactor >= 0
            else {
                throw .invalidConfiguration(.nonFiniteValue)
            }
            if let pinnedListenerIndex, pinnedListenerIndex >= listenerCount {
                throw .invalidConfiguration(.invalidListenerCount)
            }
        }
    }
}
