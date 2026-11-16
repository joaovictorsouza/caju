import CajuMath

#if canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    import Android
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    import Musl
#endif

@usableFromInline
enum CajuAudioLibm {
    #if canImport(Glibc)
        @inlinable static func powf(_ x: Float, _ y: Float) -> Float { Glibc.powf(x, y) }
        @inlinable static func cosf(_ x: Float) -> Float { Glibc.cosf(x) }
    #elseif canImport(Android)
        @inlinable static func powf(_ x: Float, _ y: Float) -> Float { Android.powf(x, y) }
        @inlinable static func cosf(_ x: Float) -> Float { Android.cosf(x) }
    #elseif canImport(Darwin)
        @inlinable static func powf(_ x: Float, _ y: Float) -> Float { Darwin.powf(x, y) }
        @inlinable static func cosf(_ x: Float) -> Float { Darwin.cosf(x) }
    #elseif canImport(Musl)
        @inlinable static func powf(_ x: Float, _ y: Float) -> Float { Musl.powf(x, y) }
        @inlinable static func cosf(_ x: Float) -> Float { Musl.cosf(x) }
    #endif
}

/// Cálculos puros de atenuação por distância, atenuação angular e *pan* estéreo sobre `CajuMath`.
///
/// Todas as funções são livres de alocação e determinísticas, usadas pelas fontes 2D da engine e
/// disponíveis para avaliação analítica em jogos e testes.
public enum CajuAudioSpatialMath: Sendable {
    /// Calcula o ganho de atenuação por distância limitado por `[minGain, maxGain]`.
    ///
    /// Acompanha as curvas padrão do `miniaudio` (`none`, `inverse`, `linear`, `exponential`).
    @inlinable
    public static func attenuationGain(distance: Float, attenuation: CajuAudioAttenuation) -> Float {
        guard distance.isFinite, attenuation.minDistance.isFinite, attenuation.maxDistance.isFinite,
            attenuation.rolloff.isFinite, attenuation.minGain.isFinite, attenuation.maxGain.isFinite
        else {
            return 0
        }

        let minDist = Swift.max(0, attenuation.minDistance)
        let maxDist = Swift.max(minDist, attenuation.maxDistance)
        let rolloff = Swift.max(0, attenuation.rolloff)
        let minGain = Swift.max(0, attenuation.minGain)
        let maxGain = Swift.max(minGain, attenuation.maxGain)

        let rawGain: Float
        switch attenuation.model {
        case .none:
            rawGain = 1
        case .inverse:
            if minDist >= maxDist || minDist <= 0 {
                rawGain = 1
            } else {
                let d = CajuScalar.clamp(distance, min: minDist, max: maxDist)
                let denom = minDist + rolloff * (d - minDist)
                rawGain = denom > 0 ? minDist / denom : 1
            }
        case .linear:
            if minDist >= maxDist {
                rawGain = 1
            } else {
                let d = CajuScalar.clamp(distance, min: minDist, max: maxDist)
                rawGain = 1 - rolloff * (d - minDist) / (maxDist - minDist)
            }
        case .exponential:
            if minDist >= maxDist || minDist <= 0 {
                rawGain = 1
            } else {
                let d = CajuScalar.clamp(distance, min: minDist, max: maxDist)
                rawGain = CajuAudioLibm.powf(d / minDist, -rolloff)
            }
        }

        return CajuScalar.clamp(rawGain, min: minGain, max: maxGain)
    }

    /// Calcula o *pan* estéreo em `[-1, 1]` para uma fonte 2D em relação ao ouvinte.
    ///
    /// `-1` desloca totalmente para a esquerda, `0` centraliza e `+1` desloca para a direita.
    /// Quando `panSpreadRadius > 0`, fontes dentro desse raio têm o *pan* suavizado até `0` no centro.
    @inlinable
    public static func stereoPan2D(
        sourcePosition: CajuVec2,
        listenerPosition: CajuVec2,
        listenerRight: CajuVec2 = .unitX,
        panSpreadRadius: Float = 0
    ) -> Float {
        let delta = sourcePosition - listenerPosition
        let distance = delta.length
        guard distance.isFinite, distance > 1e-6,
            let right = listenerRight.normalized()
        else {
            return 0
        }
        let direction = delta / distance
        let projection = CajuScalar.clamp(direction.dot(right), min: -1, max: 1)
        if panSpreadRadius.isFinite, panSpreadRadius > 0, distance < panSpreadRadius {
            return projection * (distance / panSpreadRadius)
        }
        return projection
    }

    /// Calcula o *pan* estéreo em `[-1, 1]` para uma fonte 3D usando `forward × up` do ouvinte.
    @inlinable
    public static func stereoPan3D(sourcePosition: CajuVec3, listener: CajuAudioListener) -> Float {
        let delta = sourcePosition - listener.position
        let distance = delta.length
        guard distance.isFinite, distance > 1e-6 else { return 0 }
        let forward = listener.forward.normalized() ?? CajuVec3(0, 0, -1)
        let up = listener.up.normalized() ?? .unitY
        let right = forward.cross(up).normalized() ?? .unitX
        let direction = delta / distance
        return CajuScalar.clamp(direction.dot(right), min: -1, max: 1)
    }

    /// Calcula o fator de atenuação angular `[outerGain, 1]` de um cone direcional.
    @inlinable
    public static func angularGain(
        directionToTarget: CajuVec3,
        emitterForward: CajuVec3,
        cone: CajuAudioCone
    ) -> Float {
        guard cone.innerAngleRadians.isFinite, cone.outerAngleRadians.isFinite, cone.outerGain.isFinite else {
            return 1
        }
        if cone.innerAngleRadians >= 2 * .pi {
            return 1
        }
        guard let dir = directionToTarget.normalized(),
            let forward = emitterForward.normalized()
        else {
            return 1
        }
        let cutoffInner = CajuAudioLibm.cosf(cone.innerAngleRadians * 0.5)
        let cutoffOuter = CajuAudioLibm.cosf(cone.outerAngleRadians * 0.5)
        let alignment = dir.dot(forward)
        if alignment >= cutoffInner {
            return 1
        }
        if alignment <= cutoffOuter {
            return CajuScalar.clamp(cone.outerGain, min: 0, max: 1)
        }
        let span = cutoffInner - cutoffOuter
        guard span > 1e-6 else { return 1 }
        let t = CajuScalar.saturate((alignment - cutoffOuter) / span)
        return CajuScalar.lerp(CajuScalar.clamp(cone.outerGain, min: 0, max: 1), 1, t: t)
    }

    /// Avalia simultaneamente o volume efetivo e o *pan* estéreo de uma fonte 2D.
    @inlinable
    public static func evaluate2D(
        sourcePosition: CajuVec2,
        listenerPosition: CajuVec2,
        listenerRight: CajuVec2 = .unitX,
        attenuation: CajuAudioAttenuation = .default,
        baseVolume: Float = 1
    ) -> (volume: Float, pan: Float) {
        let distance = sourcePosition.distance(to: listenerPosition)
        let gain = attenuationGain(distance: distance, attenuation: attenuation)
        let pan = stereoPan2D(
            sourcePosition: sourcePosition,
            listenerPosition: listenerPosition,
            listenerRight: listenerRight
        )
        let safeVolume = baseVolume.isFinite ? Swift.max(0, baseVolume) : 0
        return (safeVolume * gain, pan)
    }

    /// Avalia simultaneamente o volume efetivo e o *pan* estéreo de uma fonte 3D.
    @inlinable
    public static func evaluate3D(
        sourcePosition: CajuVec3,
        listener: CajuAudioListener,
        attenuation: CajuAudioAttenuation = .default,
        baseVolume: Float = 1
    ) -> (volume: Float, pan: Float) {
        let distance = sourcePosition.distance(to: listener.position)
        let gain = attenuationGain(distance: distance, attenuation: attenuation)
        let pan = stereoPan3D(sourcePosition: sourcePosition, listener: listener)
        let safeVolume = baseVolume.isFinite ? Swift.max(0, baseVolume) : 0
        return (safeVolume * gain, pan)
    }
}
