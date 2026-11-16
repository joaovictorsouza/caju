import CajuCore
import CajuMath
import CajuScene

/// Estado compacto de reprodução de animação para uso em colunas SoA do ECS (`BitwiseCopyable`).
///
/// Componente `CajuCore` de ID `16` (faixa de módulos `16–47`). Suporta tempo, *loop*, velocidade,
/// *crossfade* entre dois clipes, máscara por junta (`CajuJointMask`) e *flag* `isCulled` para
/// pular a amostragem quando a entidade está fora da tela.
public struct CajuAnimPlayback: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(16)

    /// Sentinela que indica ausência de clipe ou esqueleto associado.
    public static let invalidID: UInt32 = .max

    /// Índice do esqueleto no registro `CajuAnimLibrary`.
    public var skeletonID: UInt32
    /// Índice do clipe ativo no registro `CajuAnimLibrary`.
    public var clipID: UInt32
    /// Tempo atual do clipe ativo, em segundos.
    public var time: Float
    /// Multiplicador de velocidade do clipe ativo (`1.0` = tempo real; aceita reverso).
    public var speed: Float
    /// Indica se o clipe ativo reinicia ao atingir `duration` (ou `0` em reverso).
    public var isLooping: Bool
    /// Indica se o tempo está avançando (`false` = pausado).
    public var isPlaying: Bool
    /// *Flag* de *cull* fora da tela: quando `true`, o sistema pula amostragem e escrita na arena.
    public var isCulled: Bool
    /// Máscara de juntas habilitadas para o clipe ativo.
    public var mask: CajuJointMask

    /// Índice do clipe de origem durante um *crossfade* (`invalidID` quando inativo).
    public var previousClipID: UInt32
    /// Tempo atual do clipe de origem no *crossfade*, em segundos.
    public var previousTime: Float
    /// Velocidade do clipe de origem no *crossfade*.
    public var previousSpeed: Float
    /// Modo de *loop* do clipe de origem no *crossfade*.
    public var previousIsLooping: Bool
    /// Máscara de juntas do clipe de origem no *crossfade*.
    public var previousMask: CajuJointMask
    /// Tempo decorrido do *crossfade* atual, em segundos.
    public var crossfadeElapsed: Float
    /// Duração total do *crossfade* atual, em segundos (`0` = sem *crossfade*).
    public var crossfadeDuration: Float

    @inlinable
    public init(
        skeletonID: UInt32 = CajuAnimPlayback.invalidID,
        clipID: UInt32 = CajuAnimPlayback.invalidID,
        time: Float = 0,
        speed: Float = 1,
        isLooping: Bool = true,
        isPlaying: Bool = true,
        isCulled: Bool = false,
        mask: CajuJointMask = .all
    ) {
        self.skeletonID = skeletonID
        self.clipID = clipID
        self.time = time.isFinite ? max(0, time) : 0
        self.speed = speed.isFinite ? speed : 1
        self.isLooping = isLooping
        self.isPlaying = isPlaying
        self.isCulled = isCulled
        self.mask = mask
        self.previousClipID = Self.invalidID
        self.previousTime = 0
        self.previousSpeed = 1
        self.previousIsLooping = true
        self.previousMask = .all
        self.crossfadeElapsed = 0
        self.crossfadeDuration = 0
    }

    /// `true` enquanto há uma transição de *crossfade* em andamento.
    @inlinable
    public var isCrossfading: Bool {
        previousClipID != Self.invalidID && crossfadeDuration > 0 && crossfadeElapsed < crossfadeDuration
    }

    /// Pesos normalizados do *crossfade* `(from: pesoDoAnterior, to: pesoDoAtual)`.
    ///
    /// Sempre não negativos e somam `1`. Fora de *crossfade*, retorna `(0, 1)`.
    @inlinable
    public var crossfadeWeights: (from: Float, to: Float) {
        guard isCrossfading else { return (0, 1) }
        let toWeight = CajuScalar.saturate(crossfadeElapsed / crossfadeDuration)
        return (1 - toWeight, toWeight)
    }

    /// Inicia imediatamente a reprodução de `clipID`, cancelando qualquer *crossfade* ativo.
    @inlinable
    public mutating func play(
        clipID: UInt32,
        speed: Float = 1,
        isLooping: Bool = true,
        startTime: Float = 0,
        mask: CajuJointMask = .all
    ) {
        self.clipID = clipID
        self.time = startTime.isFinite ? max(0, startTime) : 0
        self.speed = speed.isFinite ? speed : 1
        self.isLooping = isLooping
        self.isPlaying = true
        self.mask = mask
        self.previousClipID = Self.invalidID
        self.crossfadeElapsed = 0
        self.crossfadeDuration = 0
    }

    /// Inicia um *crossfade* suave do clipe atual para `nextClipID` ao longo de `duration` segundos.
    ///
    /// Se `duration <= 0` ou não houver clipe atual válido, troca imediatamente (equivalente a `play`).
    @inlinable
    public mutating func crossfade(
        to nextClipID: UInt32,
        duration: Float,
        speed: Float = 1,
        isLooping: Bool = true,
        startTime: Float = 0,
        mask: CajuJointMask = .all
    ) {
        guard clipID != Self.invalidID, duration.isFinite, duration > 0 else {
            play(
                clipID: nextClipID,
                speed: speed,
                isLooping: isLooping,
                startTime: startTime,
                mask: mask
            )
            return
        }
        previousClipID = clipID
        previousTime = time
        previousSpeed = self.speed
        previousIsLooping = self.isLooping
        previousMask = self.mask
        crossfadeElapsed = 0
        crossfadeDuration = duration

        clipID = nextClipID
        time = startTime.isFinite ? max(0, startTime) : 0
        self.speed = speed.isFinite ? speed : 1
        self.isLooping = isLooping
        self.isPlaying = true
        self.mask = mask
    }

    /// Avança o tempo do clipe ativo (e do clipe anterior durante *crossfade*) por `deltaTime` segundos.
    @inlinable
    public mutating func advance(
        by deltaTime: Float,
        currentDuration: Float,
        previousDuration: Float? = nil
    ) {
        guard isPlaying, deltaTime.isFinite, deltaTime > 0 else { return }
        let safeSpeed = speed.isFinite ? speed : 0
        time = Self.wrapOrClampTime(
            time + deltaTime * safeSpeed,
            duration: currentDuration,
            isLooping: isLooping
        )
        guard isCrossfading else { return }
        crossfadeElapsed += deltaTime
        if crossfadeElapsed >= crossfadeDuration {
            previousClipID = Self.invalidID
            crossfadeElapsed = 0
            crossfadeDuration = 0
            return
        }
        if let prevDuration = previousDuration {
            let safePrevSpeed = previousSpeed.isFinite ? previousSpeed : 0
            previousTime = Self.wrapOrClampTime(
                previousTime + deltaTime * safePrevSpeed,
                duration: prevDuration,
                isLooping: previousIsLooping
            )
        }
    }

    /// Indica se um clipe não cíclico chegou ao fim (ou a `0` em reprodução reversa).
    @inlinable
    public func isFinished(duration: Float) -> Bool {
        guard !isLooping else { return false }
        let safeDur = (duration.isFinite && duration > 0) ? duration : 0
        if speed < 0 {
            return time <= 0
        }
        return time >= safeDur
    }

    /// Enrola (`isLooping == true`) ou limita (`isLooping == false`) `time` dentro da duração do clipe.
    @inlinable
    public static func wrapOrClampTime(_ time: Float, duration: Float, isLooping: Bool) -> Float {
        guard time.isFinite, duration.isFinite, duration > 0 else { return 0 }
        if !isLooping {
            return CajuScalar.clamp(time, min: 0, max: duration)
        }
        var wrapped = time.truncatingRemainder(dividingBy: duration)
        if wrapped < 0 {
            wrapped += duration
        }
        if wrapped >= duration {
            wrapped = 0
        }
        return wrapped
    }
}

/// Player de animação autônomo (valor) para uso direto com arrays de clipes fora ou dentro do ECS.
///
/// Gerencia tempo, *loop*, velocidade, *crossfade*, máscara por junta e *flag* de *cull* fora da tela.
///
/// ```swift
/// var player = CajuAnimPlayer(clipIndex: 0)
/// player.advance(by: 1.0 / 60.0, clips: [idleClip, walkClip])
/// try player.sampleAndWrite(
///     skeleton: skeleton, clips: [idleClip, walkClip],
///     into: &pose, arena: arena, scratch: &scratch
/// )
/// ```
public struct CajuAnimPlayer: Sendable, Equatable {
    /// Estado bruto subjacente (compatível com `CajuAnimPlayback` no ECS).
    public var state: CajuAnimPlayback

    public init(
        clipIndex: Int = 0,
        speed: Float = 1,
        isLooping: Bool = true,
        isPlaying: Bool = true,
        isCulled: Bool = false,
        mask: CajuJointMask = .all
    ) {
        let id = clipIndex >= 0 ? UInt32(clipIndex) : CajuAnimPlayback.invalidID
        self.state = CajuAnimPlayback(
            skeletonID: 0,
            clipID: id,
            time: 0,
            speed: speed,
            isLooping: isLooping,
            isPlaying: isPlaying,
            isCulled: isCulled,
            mask: mask
        )
    }

    @inlinable public var clipIndex: Int {
        state.clipID == CajuAnimPlayback.invalidID ? -1 : Int(state.clipID)
    }
    @inlinable public var time: Float {
        get { state.time }
        set { state.time = newValue }
    }
    @inlinable public var speed: Float {
        get { state.speed }
        set { state.speed = newValue }
    }
    @inlinable public var isLooping: Bool {
        get { state.isLooping }
        set { state.isLooping = newValue }
    }
    @inlinable public var isPlaying: Bool {
        get { state.isPlaying }
        set { state.isPlaying = newValue }
    }
    /// *Flag* de *cull* fora da tela: quando `true`, `sampleAndWrite` pula a amostragem.
    @inlinable public var isCulled: Bool {
        get { state.isCulled }
        set { state.isCulled = newValue }
    }
    @inlinable public var mask: CajuJointMask {
        get { state.mask }
        set { state.mask = newValue }
    }
    @inlinable public var isCrossfading: Bool { state.isCrossfading }
    @inlinable public var crossfadeWeights: (from: Float, to: Float) { state.crossfadeWeights }

    /// Inicia imediatamente a reprodução do clipe em `clipIndex`.
    public mutating func play(
        clipIndex: Int,
        speed: Float = 1,
        isLooping: Bool = true,
        startTime: Float = 0,
        mask: CajuJointMask = .all
    ) {
        let id = clipIndex >= 0 ? UInt32(clipIndex) : CajuAnimPlayback.invalidID
        state.play(clipID: id, speed: speed, isLooping: isLooping, startTime: startTime, mask: mask)
    }

    /// Inicia um *crossfade* para o clipe em `clipIndex` ao longo de `duration` segundos.
    public mutating func crossfade(
        to clipIndex: Int,
        duration: Float,
        speed: Float = 1,
        isLooping: Bool = true,
        startTime: Float = 0,
        mask: CajuJointMask = .all
    ) {
        let id = clipIndex >= 0 ? UInt32(clipIndex) : CajuAnimPlayback.invalidID
        state.crossfade(
            to: id,
            duration: duration,
            speed: speed,
            isLooping: isLooping,
            startTime: startTime,
            mask: mask
        )
    }

    /// Avança o relógio do player usando as durações em `clips`.
    public mutating func advance(by deltaTime: Float, clips: [CajuAnimClip]) {
        guard state.clipID != CajuAnimPlayback.invalidID else { return }
        let currIdx = Int(state.clipID)
        guard currIdx >= 0 && currIdx < clips.count else { return }
        var prevDur: Float?
        if state.isCrossfading {
            let prevIdx = Int(state.previousClipID)
            if prevIdx >= 0 && prevIdx < clips.count {
                prevDur = clips[prevIdx].duration
            }
        }
        state.advance(by: deltaTime, currentDuration: clips[currIdx].duration, previousDuration: prevDur)
    }

    /// Amostra o estado atual e escreve a pose em espaço do modelo na `CajuPoseArena`.
    ///
    /// Hook de *cull*: se `state.isCulled` for `true` ou `shouldSample?(self)` retornar `false`,
    /// pula toda a amostragem, mantém a arena intocada e retorna `false`.
    @discardableResult
    public func sampleAndWrite(
        skeleton: CajuSkeleton,
        clips: [CajuAnimClip],
        into pose: inout CajuSkinPose,
        arena: CajuPoseArena,
        scratch: inout CajuAnimScratchBuffer,
        shouldSample: ((CajuAnimPlayer) -> Bool)? = nil
    ) throws(CajuAnimError) -> Bool {
        let allowSample = !state.isCulled && (shouldSample?(self) ?? true)
        if !allowSample { return false }

        let currIdx = Int(state.clipID)
        guard state.clipID != CajuAnimPlayback.invalidID, currIdx >= 0, currIdx < clips.count else {
            throw .clipIndexOutOfBounds(currIdx)
        }
        if state.isCrossfading {
            let prevIdx = Int(state.previousClipID)
            guard prevIdx >= 0, prevIdx < clips.count else {
                throw .clipIndexOutOfBounds(prevIdx)
            }
            let weights = state.crossfadeWeights
            return try CajuAnimSampler.sampleCrossfadeAndWrite(
                fromClip: clips[prevIdx],
                fromTime: state.previousTime,
                fromMask: state.previousMask,
                toClip: clips[currIdx],
                toTime: state.time,
                toMask: state.mask,
                weight: weights.to,
                skeleton: skeleton,
                isCulled: false,
                into: &pose,
                arena: arena,
                scratch: &scratch
            )
        }
        return try CajuAnimSampler.sampleAndWrite(
            clip: clips[currIdx],
            time: state.time,
            skeleton: skeleton,
            mask: state.mask,
            isCulled: false,
            into: &pose,
            arena: arena,
            scratch: &scratch
        )
    }
}

/// Repositório de esqueletos, clipes e *scratch buffer* reutilizável para o sistema ECS de animação.
///
/// Mantém o *scratch buffer* pré-alocado para que `CajuAnim.poseUpdateSystem` execute com zero
/// alocações de *heap* no caminho quente (thread de jogo).
public final class CajuAnimLibrary {
    @usableFromInline var skeletons: ContiguousArray<CajuSkeleton> = []
    @usableFromInline var clips: ContiguousArray<CajuAnimClip> = []
    @usableFromInline var scratch = CajuAnimScratchBuffer()

    /// Quantidade de poses amostradas no último quadro do sistema.
    public private(set) var lastFrameSampledCount: Int = 0
    /// Quantidade de entidades puladas por *cull* no último quadro do sistema.
    public private(set) var lastFrameCulledCount: Int = 0
    /// Quantidade acumulada de erros (IDs inválidos ou estouro/intervalo da arena) no sistema.
    public private(set) var errorCount: Int = 0
    /// Último erro observado durante a atualização em lote no ECS, se houver.
    public private(set) var lastError: CajuAnimError?

    public init() {}

    /// Registra um esqueleto (caminho frio) e retorna seu ID para `CajuAnimPlayback.skeletonID`.
    @discardableResult
    public func registerSkeleton(_ skeleton: CajuSkeleton) -> UInt32 {
        let id = UInt32(skeletons.count)
        skeletons.append(skeleton)
        return id
    }

    /// Registra um clipe (caminho frio) e retorna seu ID para `CajuAnimPlayback.clipID`.
    @discardableResult
    public func registerClip(_ clip: CajuAnimClip) -> UInt32 {
        let id = UInt32(clips.count)
        clips.append(clip)
        return id
    }

    /// Obtém o esqueleto associado a `id`, ou `nil` se inválido.
    @inlinable
    public func skeleton(at id: UInt32) -> CajuSkeleton? {
        guard id != CajuAnimPlayback.invalidID else { return nil }
        let idx = Int(id)
        guard idx >= 0 && idx < skeletons.count else { return nil }
        return skeletons[idx]
    }

    /// Obtém o clipe associado a `id`, ou `nil` se inválido.
    @inlinable
    public func clip(at id: UInt32) -> CajuAnimClip? {
        guard id != CajuAnimPlayback.invalidID else { return nil }
        let idx = Int(id)
        guard idx >= 0 && idx < clips.count else { return nil }
        return clips[idx]
    }

    @usableFromInline
    func resetFrameCounters() {
        lastFrameSampledCount = 0
        lastFrameCulledCount = 0
    }

    @usableFromInline
    func recordSampled() {
        lastFrameSampledCount += 1
    }

    @usableFromInline
    func recordCulled() {
        lastFrameCulledCount += 1
    }

    @usableFromInline
    func recordError(_ error: CajuAnimError) {
        errorCount += 1
        lastError = error
    }
}
