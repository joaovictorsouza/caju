import CajuMath

/// Backend usado pela `CajuAudioEngine`.
public enum CajuAudioBackend: UInt8, Sendable, Equatable {
    /// Seleciona automaticamente o backend nativo da plataforma (CoreAudio no Apple, AAudio/OpenSL ES no Android).
    case automatic
    /// Dispositivo nulo do `miniaudio`: executa a thread e o *callback* de áudio sem hardware (ideal para CI/testes).
    case null
    /// Modo sem dispositivo: a mistura é puxada deterministicamente por `renderFrames`.
    case offline
}

/// Configuração de inicialização da `CajuAudioEngine`.
///
/// ```swift
/// let config = CajuAudioConfiguration(backend: .null, sampleRate: 48_000, channels: 2)
/// let engine = try CajuAudioEngine(configuration: config)
/// ```
public struct CajuAudioConfiguration: Sendable, Equatable {
    /// Taxa de amostragem padrão (Hz).
    public static let defaultSampleRate: UInt32 = 48_000
    /// Quantidade máxima de ouvintes suportada pelo `miniaudio` (`MA_ENGINE_MAX_LISTENERS`).
    public static let maxListeners: UInt32 = 4

    /// Backend de saída.
    public var backend: CajuAudioBackend
    /// Taxa de amostragem em Hz (`0` permitido apenas em `.automatic` para usar a taxa nativa).
    public var sampleRate: UInt32
    /// Quantidade de canais de saída (`0` permitido apenas em `.automatic` para usar os canais nativos).
    public var channels: UInt32
    /// Quantidade de ouvintes simultâneos (`1...4`).
    public var listenerCount: UInt32
    /// Tamanho do período em quadros PCM (`0` usa o padrão do backend).
    public var periodSizeInFrames: UInt32
    /// Se `true`, inicia o dispositivo imediatamente na criação; se `false`, inicia em `.paused`.
    public var startImmediately: Bool

    public init(
        backend: CajuAudioBackend = .automatic,
        sampleRate: UInt32 = defaultSampleRate,
        channels: UInt32 = 2,
        listenerCount: UInt32 = 1,
        periodSizeInFrames: UInt32 = 0,
        startImmediately: Bool = true
    ) {
        self.backend = backend
        self.sampleRate = sampleRate
        self.channels = channels
        self.listenerCount = listenerCount
        self.periodSizeInFrames = periodSizeInFrames
        self.startImmediately = startImmediately
    }
}

/// Modelo de atenuação por distância.
public enum CajuAudioAttenuationModel: UInt8, Sendable, Equatable {
    /// Sem atenuação por distância.
    case none
    /// Atenuação inversa limitada (equivalente a `AL_INVERSE_DISTANCE_CLAMPED`).
    case inverse
    /// Atenuação linear entre `minDistance` e `maxDistance`.
    case linear
    /// Atenuação exponencial.
    case exponential
}

/// Referencial das coordenadas de uma fonte 3D.
public enum CajuAudioPositioning: UInt8, Sendable, Equatable {
    /// Coordenadas no espaço do mundo.
    case absolute
    /// Coordenadas relativas ao ouvinte.
    case relative
}

/// Cone direcional de emissão (fonte) ou captação (ouvinte).
public struct CajuAudioCone: Sendable, Equatable {
    /// Ângulo total do cone interno em radianos (sem atenuação angular).
    public var innerAngleRadians: Float
    /// Ângulo total do cone externo em radianos (a partir daqui aplica `outerGain`).
    public var outerAngleRadians: Float
    /// Ganho aplicado fora do cone externo (`[0, 1]`).
    public var outerGain: Float

    public init(innerAngleRadians: Float, outerAngleRadians: Float, outerGain: Float) {
        self.innerAngleRadians = innerAngleRadians
        self.outerAngleRadians = outerAngleRadians
        self.outerGain = outerGain
    }
}

/// Parâmetros de atenuação por distância para fontes espaciais 2D e 3D.
public struct CajuAudioAttenuation: Sendable, Equatable {
    public var model: CajuAudioAttenuationModel
    public var minDistance: Float
    public var maxDistance: Float
    public var rolloff: Float
    public var minGain: Float
    public var maxGain: Float

    public init(
        model: CajuAudioAttenuationModel = .inverse,
        minDistance: Float = 1,
        maxDistance: Float = 100,
        rolloff: Float = 1,
        minGain: Float = 0,
        maxGain: Float = 1
    ) {
        self.model = model
        self.minDistance = minDistance
        self.maxDistance = maxDistance
        self.rolloff = rolloff
        self.minGain = minGain
        self.maxGain = maxGain
    }

    public static let `default` = CajuAudioAttenuation()
}

/// Estado de um ouvinte no espaço 3D (convenção de mão direita: +X direita, +Y cima, -Z frente).
public struct CajuAudioListener: Sendable, Equatable {
    public var position: CajuVec3
    public var forward: CajuVec3
    public var up: CajuVec3
    public var velocity: CajuVec3
    public var cone: CajuAudioCone?
    public var isEnabled: Bool

    public init(
        position: CajuVec3 = .zero,
        forward: CajuVec3 = CajuVec3(0, 0, -1),
        up: CajuVec3 = .unitY,
        velocity: CajuVec3 = .zero,
        cone: CajuAudioCone? = nil,
        isEnabled: Bool = true
    ) {
        self.position = position
        self.forward = forward
        self.up = up
        self.velocity = velocity
        self.cone = cone
        self.isEnabled = isEnabled
    }

    /// Constrói um ouvinte derivando `forward` (`(0, 0, -1)`) e `up` (`(0, 1, 0)`) de `orientation`.
    public init(
        position: CajuVec3,
        orientation: CajuQuat,
        velocity: CajuVec3 = .zero,
        cone: CajuAudioCone? = nil,
        isEnabled: Bool = true
    ) {
        self.position = position
        self.forward = orientation.rotate(CajuVec3(0, 0, -1))
        self.up = orientation.rotate(.unitY)
        self.velocity = velocity
        self.cone = cone
        self.isEnabled = isEnabled
    }
}

/// Modo de espacialização de uma fonte sonora.
public enum CajuAudioSpatialMode: Sendable, Equatable {
    /// Fonte 2D direta sem atenuação espacial, apenas *pan* estéreo em `[-1, 1]`.
    case direct2D(pan: Float = 0)
    /// Fonte 2D no plano XY com atenuação por distância e *pan* estéreo calculados via `CajuMath`.
    case planar2D(position: CajuVec2 = .zero, attenuation: CajuAudioAttenuation = .default)
    /// Fonte 3D espacializada pelo grafo do `miniaudio` usando vetores `CajuVec3`.
    case spatial3D(
        position: CajuVec3 = .zero,
        direction: CajuVec3 = CajuVec3(0, 0, -1),
        velocity: CajuVec3 = .zero,
        positioning: CajuAudioPositioning = .absolute,
        attenuation: CajuAudioAttenuation = .default,
        cone: CajuAudioCone? = nil,
        dopplerFactor: Float = 1,
        directionalAttenuationFactor: Float = 1,
        pinnedListenerIndex: UInt32? = nil
    )
}

/// Descritor para criação de um bus de mixagem.
public struct CajuAudioBusDescriptor: Sendable, Equatable {
    public var volume: Float
    public var pan: Float
    public var pitch: Float
    public var parent: CajuAudioBusHandle?

    public init(
        volume: Float = 1,
        pan: Float = 0,
        pitch: Float = 1,
        parent: CajuAudioBusHandle? = nil
    ) {
        self.volume = volume
        self.pan = pan
        self.pitch = pitch
        self.parent = parent
    }
}

/// Descritor para criação de uma fonte sonora.
public struct CajuAudioSourceDescriptor: Sendable, Equatable {
    public var clip: CajuAudioClipHandle
    public var bus: CajuAudioBusHandle?
    public var volume: Float
    public var pitch: Float
    public var isLooping: Bool
    public var spatialMode: CajuAudioSpatialMode

    public init(
        clip: CajuAudioClipHandle,
        bus: CajuAudioBusHandle? = nil,
        volume: Float = 1,
        pitch: Float = 1,
        isLooping: Bool = false,
        spatialMode: CajuAudioSpatialMode = .direct2D()
    ) {
        self.clip = clip
        self.bus = bus
        self.volume = volume
        self.pitch = pitch
        self.isLooping = isLooping
        self.spatialMode = spatialMode
    }
}

/// Eventos de ciclo de vida consumidos pela `CajuAudioEngine`.
///
/// Espelha os casos de `CajuLifecycleEvent` (`CajuPlatform`) para evitar dependência direta no
/// manifesto sem alterar camadas (ADR 0015).
public enum CajuAudioLifecycleEvent: UInt8, Sendable, Hashable {
    case didBecomeActive
    case willResignActive
    case didEnterBackground
    case willEnterForeground
    case lowMemory
    case willTerminate
}

/// Estado de execução da engine de áudio frente ao ciclo de vida.
public enum CajuAudioLifecycleState: UInt8, Sendable, Hashable {
    case running
    case paused
    case stopped
}

/// Metadados imutáveis de um clipe carregado.
public struct CajuAudioClipInfo: Sendable, Equatable {
    public let channels: UInt32
    public let sampleRate: UInt32
    public let frameCount: UInt64

    public init(channels: UInt32, sampleRate: UInt32, frameCount: UInt64) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.frameCount = frameCount
    }

    /// Duração do clipe em segundos.
    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / Double(sampleRate)
    }
}

/// Diagnóstico instantâneo da `CajuAudioEngine` para telemetria e testes.
public struct CajuAudioDiagnostics: Sendable, Equatable {
    public let backend: CajuAudioBackend
    public let sampleRate: UInt32
    public let channels: UInt32
    public let activeClips: Int
    public let activeBuses: Int
    public let activeSources: Int
    public let playedFrames: UInt64
    public let isPaused: Bool
    public let isShutdown: Bool
}
