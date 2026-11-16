import CajuCore
import CajuMath
import CajuPlatform

/// Fase de um gesto contínuo (long press, pan, pinch).
public enum CajuGesturePhase: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case began
    case changed
    case ended
    case cancelled
}

/// Evento emitido quando um toque curto dentro da tolerância é reconhecido.
public struct CajuTapGesture: BitwiseCopyable, Sendable, Equatable {
    /// Posição em pontos lógicos onde o toque terminou.
    public var position: CajuVec2
    /// Contagem de toques consecutivos dentro do intervalo e tolerância (`1` = toque simples).
    public var tapCount: UInt16
    public var pointerKind: CajuPointerKind
    public var timestampNanoseconds: UInt64

    @inlinable public var timestamp: CajuTimestamp {
        get { CajuTimestamp(nanoseconds: timestampNanoseconds) }
        set { timestampNanoseconds = newValue.nanoseconds }
    }

    @inlinable public init(
        position: CajuVec2,
        tapCount: UInt16 = 1,
        pointerKind: CajuPointerKind = .touch,
        timestamp: CajuTimestamp
    ) {
        self.position = position
        self.tapCount = max(1, tapCount)
        self.pointerKind = pointerKind
        self.timestampNanoseconds = timestamp.nanoseconds
    }
}

/// Evento emitido pelo reconhecedor de pressão longa (*long press*).
public struct CajuLongPressGesture: BitwiseCopyable, Sendable, Equatable {
    public var phase: CajuGesturePhase
    public var position: CajuVec2
    /// Duração acumulada desde o início do toque, em segundos.
    public var durationSeconds: Double
    public var pointerKind: CajuPointerKind
    public var timestampNanoseconds: UInt64

    @inlinable public var timestamp: CajuTimestamp {
        get { CajuTimestamp(nanoseconds: timestampNanoseconds) }
        set { timestampNanoseconds = newValue.nanoseconds }
    }

    @inlinable public init(
        phase: CajuGesturePhase,
        position: CajuVec2,
        durationSeconds: Double,
        pointerKind: CajuPointerKind = .touch,
        timestamp: CajuTimestamp
    ) {
        self.phase = phase
        self.position = position
        self.durationSeconds = durationSeconds
        self.pointerKind = pointerKind
        self.timestampNanoseconds = timestamp.nanoseconds
    }
}

/// Evento emitido pelo reconhecedor de arraste (*pan*).
public struct CajuPanGesture: BitwiseCopyable, Sendable, Equatable {
    public var phase: CajuGesturePhase
    public var startPosition: CajuVec2
    public var position: CajuVec2
    /// Deslocamento acumulado desde `startPosition`, em pontos.
    public var translation: CajuVec2
    /// Deslocamento incremental desde o último evento de pan, em pontos.
    public var delta: CajuVec2
    /// Velocidade instantânea estimada em pontos por segundo.
    public var velocity: CajuVec2
    public var pointerKind: CajuPointerKind
    public var timestampNanoseconds: UInt64

    @inlinable public var timestamp: CajuTimestamp {
        get { CajuTimestamp(nanoseconds: timestampNanoseconds) }
        set { timestampNanoseconds = newValue.nanoseconds }
    }

    @inlinable public init(
        phase: CajuGesturePhase,
        startPosition: CajuVec2,
        position: CajuVec2,
        translation: CajuVec2,
        delta: CajuVec2,
        velocity: CajuVec2,
        pointerKind: CajuPointerKind = .touch,
        timestamp: CajuTimestamp
    ) {
        self.phase = phase
        self.startPosition = startPosition
        self.position = position
        self.translation = translation
        self.delta = delta
        self.velocity = velocity
        self.pointerKind = pointerKind
        self.timestampNanoseconds = timestamp.nanoseconds
    }
}

/// Evento emitido pelo reconhecedor de pinça com dois dedos (*pinch*).
public struct CajuPinchGesture: BitwiseCopyable, Sendable, Equatable {
    public var phase: CajuGesturePhase
    /// Ponto médio entre os dois dedos, em pontos lógicos.
    public var center: CajuVec2
    /// Fator de escala acumulado desde a distância inicial (`1.0` = sem variação).
    public var scale: Float
    /// Razão incremental desde o último evento emitido (`1.0` = sem variação).
    public var deltaScale: Float
    /// Distância atual entre os dois dedos, em pontos.
    public var span: Float
    public var timestampNanoseconds: UInt64

    @inlinable public var timestamp: CajuTimestamp {
        get { CajuTimestamp(nanoseconds: timestampNanoseconds) }
        set { timestampNanoseconds = newValue.nanoseconds }
    }

    @inlinable public init(
        phase: CajuGesturePhase,
        center: CajuVec2,
        scale: Float,
        deltaScale: Float,
        span: Float,
        timestamp: CajuTimestamp
    ) {
        self.phase = phase
        self.center = center
        self.scale = scale
        self.deltaScale = deltaScale
        self.span = span
        self.timestampNanoseconds = timestamp.nanoseconds
    }
}

/// Mensagem unificada de gesto emitida por `CajuInputProcessor`.
///
/// Conforma a `BitwiseCopyable` e `Sendable`: pode ser despachada diretamente em
/// `CajuCore.CajuMessageQueue<CajuGestureEvent>` sem alocação no caminho quente.
public enum CajuGestureEvent: BitwiseCopyable, Sendable, Equatable {
    case tap(CajuTapGesture)
    case longPress(CajuLongPressGesture)
    case pan(CajuPanGesture)
    case pinch(CajuPinchGesture)

    @inlinable public var timestamp: CajuTimestamp {
        switch self {
        case .tap(let g): g.timestamp
        case .longPress(let g): g.timestamp
        case .pan(let g): g.timestamp
        case .pinch(let g): g.timestamp
        }
    }
}

/// Fila em anel de capacidade fixa para eventos de gesto, sem alocação após o `init`.
///
/// Segue o estilo de `CajuEventQueue` (`CajuPlatform`): uso em thread única, FIFO estrito em O(1).
/// Quando cheia, `push(_:)` rejeita o novo evento, retorna `false` e incrementa `droppedCount`.
public struct CajuGestureQueue: Sendable, Equatable {
    private var storage: ContiguousArray<CajuGestureEvent?>
    private var head = 0
    public private(set) var count = 0
    /// Eventos descartados por fila cheia (deve ser 0 em operação normal).
    public private(set) var droppedCount = 0

    public init(capacity: Int = 64) {
        storage = ContiguousArray(repeating: nil, count: max(capacity, 1))
    }

    public var capacity: Int { storage.count }
    public var isEmpty: Bool { count == 0 }

    /// Enfileira um gesto; retorna `false` se a fila estiver cheia.
    @discardableResult
    public mutating func push(_ event: CajuGestureEvent) -> Bool {
        guard count < storage.count else {
            droppedCount += 1
            return false
        }
        storage[(head + count) % storage.count] = event
        count += 1
        return true
    }

    /// Remove e devolve o evento mais antigo, ou `nil` se vazia.
    public mutating func pop() -> CajuGestureEvent? {
        guard count > 0 else { return nil }
        let event = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return event
    }

    /// Consulta o próximo evento sem removê-lo.
    public func peek() -> CajuGestureEvent? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    /// Consome todos os eventos pendentes em ordem FIFO, sem alocar.
    public mutating func drain(_ body: (CajuGestureEvent) -> Void) {
        while let event = pop() {
            body(event)
        }
    }

    /// Despacha todos os eventos pendentes para uma `CajuMessageQueue` do ECS, sem alocar.
    @discardableResult
    public mutating func flush(into messageQueue: CajuMessageQueue<CajuGestureEvent>) -> Int {
        var sent = 0
        while let event = pop() {
            if messageQueue.send(event) {
                sent += 1
            }
        }
        return sent
    }

    /// Limpa todos os eventos pendentes mantendo a capacidade pré-alocada.
    public mutating func clear() {
        while pop() != nil {}
    }
}
