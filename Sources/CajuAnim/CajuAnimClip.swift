import CajuMath
import CajuScene

/// Modo de interpolação entre *keyframes* consecutivos de um canal.
public enum CajuAnimInterpolation: UInt8, Sendable, Equatable, Hashable {
    /// Interpolação linear (`lerp` para `CajuVec3`, `slerp` pelo menor arco para `CajuQuat`).
    case linear
    /// Degrau constante (mantém o valor do *keyframe* inicial do segmento até o próximo).
    case step
}

/// Canal de animação de translação ou escala (`CajuVec3`) associado a uma junta.
public struct CajuAnimVec3Channel: Sendable, Equatable {
    /// Índice da junta alvo no esqueleto (`0..<CajuPoseArena.maxJointCount`).
    public let jointIndex: UInt16
    /// Modo de interpolação entre *keyframes*.
    public let interpolation: CajuAnimInterpolation
    /// Instantes dos *keyframes* em segundos (não negativos, finitos, ordem não decrescente).
    public let times: ContiguousArray<Float>
    /// Valores em cada *keyframe* (mesmo tamanho de `times`, finitos).
    public let values: ContiguousArray<CajuVec3>

    /// Cria e valida um canal de `CajuVec3`.
    public init(
        jointIndex: Int,
        interpolation: CajuAnimInterpolation = .linear,
        times: [Float],
        values: [CajuVec3]
    ) throws(CajuAnimError) {
        guard jointIndex >= 0 && jointIndex < Int(CajuPoseArena.maxJointCount) else {
            throw .invalidChannelTarget(
                jointIndex: UInt16(truncatingIfNeeded: max(0, jointIndex)),
                maxJointCount: Int(CajuPoseArena.maxJointCount)
            )
        }
        guard !times.isEmpty, times.count == values.count else {
            throw .invalidKeyframeCount(times: times.count, values: values.count)
        }
        var prevTime: Float = -Float.greatestFiniteMagnitude
        for (i, t) in times.enumerated() {
            guard t.isFinite, t >= 0, t >= prevTime else {
                throw .invalidKeyframeOrder(jointIndex: UInt16(jointIndex), keyframeIndex: i)
            }
            prevTime = t
        }
        for v in values where !v.isFinite {
            throw .nonFiniteValue
        }
        self.jointIndex = UInt16(jointIndex)
        self.interpolation = interpolation
        self.times = ContiguousArray(times)
        self.values = ContiguousArray(values)
    }

    /// Amostra o canal no instante `time` (em segundos) sem alocações.
    @inlinable
    public func sample(at time: Float) -> CajuVec3 {
        let count = times.count
        guard time.isFinite else { return values[0] }
        if count == 1 || time <= times[0] {
            return values[0]
        }
        if time >= times[count - 1] {
            return values[count - 1]
        }
        var low = 0
        var high = count - 1
        while low + 1 < high {
            let mid = (low + high) >> 1
            if times[mid] <= time {
                low = mid
            } else {
                high = mid
            }
        }
        if interpolation == .step {
            return values[low]
        }
        let t0 = times[low]
        let t1 = times[high]
        let span = t1 - t0
        guard span > 0 else { return values[low] }
        let alpha = CajuScalar.saturate((time - t0) / span)
        return CajuVec3.lerp(values[low], values[high], t: alpha)
    }
}

/// Canal de animação de rotação (`CajuQuat`) associado a uma junta.
///
/// Todos os quaternions armazenados são normalizados na construção do canal; a interpolação
/// `.linear` utiliza `CajuQuat.slerp` pelo menor arco, garantindo saída unitária.
public struct CajuAnimQuatChannel: Sendable, Equatable {
    /// Índice da junta alvo no esqueleto (`0..<CajuPoseArena.maxJointCount`).
    public let jointIndex: UInt16
    /// Modo de interpolação entre *keyframes*.
    public let interpolation: CajuAnimInterpolation
    /// Instantes dos *keyframes* em segundos (não negativos, finitos, ordem não decrescente).
    public let times: ContiguousArray<Float>
    /// Quaternions unitários em cada *keyframe* (normalizados na construção).
    public let values: ContiguousArray<CajuQuat>

    /// Cria e valida um canal de `CajuQuat`, normalizando cada quaternion de entrada.
    public init(
        jointIndex: Int,
        interpolation: CajuAnimInterpolation = .linear,
        times: [Float],
        values: [CajuQuat]
    ) throws(CajuAnimError) {
        guard jointIndex >= 0 && jointIndex < Int(CajuPoseArena.maxJointCount) else {
            throw .invalidChannelTarget(
                jointIndex: UInt16(truncatingIfNeeded: max(0, jointIndex)),
                maxJointCount: Int(CajuPoseArena.maxJointCount)
            )
        }
        guard !times.isEmpty, times.count == values.count else {
            throw .invalidKeyframeCount(times: times.count, values: values.count)
        }
        var prevTime: Float = -Float.greatestFiniteMagnitude
        for (i, t) in times.enumerated() {
            guard t.isFinite, t >= 0, t >= prevTime else {
                throw .invalidKeyframeOrder(jointIndex: UInt16(jointIndex), keyframeIndex: i)
            }
            prevTime = t
        }
        var normalized: ContiguousArray<CajuQuat> = []
        normalized.reserveCapacity(values.count)
        for q in values {
            guard q.isFinite, let unit = q.normalized() else {
                throw .nonFiniteValue
            }
            normalized.append(unit)
        }
        self.jointIndex = UInt16(jointIndex)
        self.interpolation = interpolation
        self.times = ContiguousArray(times)
        self.values = normalized
    }

    /// Amostra o canal no instante `time` (em segundos) retornando sempre um quaternion unitário.
    @inlinable
    public func sample(at time: Float) -> CajuQuat {
        let count = times.count
        guard time.isFinite else { return values[0] }
        if count == 1 || time <= times[0] {
            return values[0]
        }
        if time >= times[count - 1] {
            return values[count - 1]
        }
        var low = 0
        var high = count - 1
        while low + 1 < high {
            let mid = (low + high) >> 1
            if times[mid] <= time {
                low = mid
            } else {
                high = mid
            }
        }
        if interpolation == .step {
            return values[low]
        }
        let t0 = times[low]
        let t1 = times[high]
        let span = t1 - t0
        guard span > 0 else { return values[low] }
        let alpha = CajuScalar.saturate((time - t0) / span)
        return CajuQuat.slerp(values[low], values[high], t: alpha)
    }
}

/// Descritor ergonômico de canal para construção de clipes de animação em código.
public enum CajuAnimChannel: Sendable, Equatable {
    case translation(
        jointIndex: Int,
        interpolation: CajuAnimInterpolation = .linear,
        times: [Float],
        values: [CajuVec3]
    )
    case rotation(
        jointIndex: Int,
        interpolation: CajuAnimInterpolation = .linear,
        times: [Float],
        values: [CajuQuat]
    )
    case scale(
        jointIndex: Int,
        interpolation: CajuAnimInterpolation = .linear,
        times: [Float],
        values: [CajuVec3]
    )
}

/// Clipe de animação esquelética construível em código (canais de translação, rotação e escala).
///
/// Armazena canais separados em arrays contíguos por tipo para leitura linear na amostragem,
/// sem *switch* nem alocação no caminho quente. Carga via glTF entra depois pela trilha A-1.
///
/// ```swift
/// let clip = try CajuAnimClip(name: "walk", channels: [
///     .translation(jointIndex: 0, times: [0, 1], values: [.zero, CajuVec3(0, 0, 2)])
/// ])
/// ```
public struct CajuAnimClip: Sendable, Equatable {
    /// Nome opcional do clipe (metadado frio, não acessado no caminho quente).
    public let name: String
    /// Duração total do clipe em segundos (`>= 0`).
    public let duration: Float
    /// Canais de translação local por junta.
    public let translationChannels: ContiguousArray<CajuAnimVec3Channel>
    /// Canais de rotação local por junta (`CajuQuat`).
    public let rotationChannels: ContiguousArray<CajuAnimQuatChannel>
    /// Canais de escala local por junta.
    public let scaleChannels: ContiguousArray<CajuAnimVec3Channel>

    /// Cria e valida um clipe a partir dos canais declarados em código.
    ///
    /// Se `duration` for `nil`, usa o maior timestamp encontrado entre os canais (`0` se vazio).
    public init(
        name: String = "",
        duration: Float? = nil,
        channels: [CajuAnimChannel]
    ) throws(CajuAnimError) {
        var tChannels: ContiguousArray<CajuAnimVec3Channel> = []
        var rChannels: ContiguousArray<CajuAnimQuatChannel> = []
        var sChannels: ContiguousArray<CajuAnimVec3Channel> = []
        var maxTime: Float = 0

        for channel in channels {
            switch channel {
            case .translation(let joint, let interp, let times, let values):
                let ch = try CajuAnimVec3Channel(
                    jointIndex: joint,
                    interpolation: interp,
                    times: times,
                    values: values
                )
                if let last = ch.times.last, last > maxTime { maxTime = last }
                tChannels.append(ch)
            case .rotation(let joint, let interp, let times, let values):
                let ch = try CajuAnimQuatChannel(
                    jointIndex: joint,
                    interpolation: interp,
                    times: times,
                    values: values
                )
                if let last = ch.times.last, last > maxTime { maxTime = last }
                rChannels.append(ch)
            case .scale(let joint, let interp, let times, let values):
                let ch = try CajuAnimVec3Channel(
                    jointIndex: joint,
                    interpolation: interp,
                    times: times,
                    values: values
                )
                if let last = ch.times.last, last > maxTime { maxTime = last }
                sChannels.append(ch)
            }
        }

        let finalDuration = duration ?? maxTime
        guard finalDuration.isFinite, finalDuration >= 0 else {
            throw .invalidDuration(finalDuration)
        }

        self.name = name
        self.duration = finalDuration
        self.translationChannels = tChannels
        self.rotationChannels = rChannels
        self.scaleChannels = sChannels
    }

    /// Valida se todos os canais do clipe apontam para juntas válidas de `skeleton`.
    public func validate(for skeleton: CajuSkeleton) throws(CajuAnimError) {
        let count = skeleton.jointCount
        for ch in translationChannels where Int(ch.jointIndex) >= count {
            throw .invalidChannelTarget(jointIndex: ch.jointIndex, maxJointCount: count)
        }
        for ch in rotationChannels where Int(ch.jointIndex) >= count {
            throw .invalidChannelTarget(jointIndex: ch.jointIndex, maxJointCount: count)
        }
        for ch in scaleChannels where Int(ch.jointIndex) >= count {
            throw .invalidChannelTarget(jointIndex: ch.jointIndex, maxJointCount: count)
        }
    }
}
