/// Janela nativa opaca (`ANativeWindow*` no Android).
///
/// O ponteiro só vale entre `surfaceCreated` e o fim do tratamento de
/// `surfaceDestroyed` na Game Thread; a Activity espera esse fim (`CajuHandshake`).
public struct CajuNativeWindow: BitwiseCopyable, @unchecked Sendable, Equatable {
    public let raw: UnsafeMutableRawPointer

    public init(raw: UnsafeMutableRawPointer) { self.raw = raw }
}

/// Fila de entrada nativa opaca (`AInputQueue*` no Android).
public struct CajuNativeInputQueue: BitwiseCopyable, @unchecked Sendable, Equatable {
    public let raw: UnsafeMutableRawPointer

    public init(raw: UnsafeMutableRawPointer) { self.raw = raw }
}

/// Eventos de ciclo de vida, superfície e entrada que a Activity (UI thread)
/// envia à Game Thread (ADR 0008). Só tipos triviais: copiar não aloca.
public enum CajuPlatformEvent: BitwiseCopyable, Sendable, Equatable {
    case started
    case resumed
    case paused
    case stopped
    /// A Activity está sendo destruída: a Game Thread deve encerrar o laço.
    case destroyed
    case focusChanged(Bool)
    case lowMemory
    case surfaceCreated(CajuNativeWindow)
    case surfaceResized
    /// A Game Thread deve soltar a superfície e então sinalizar o `CajuHandshake`.
    case surfaceDestroyed
    case inputQueueCreated(CajuNativeInputQueue)
    /// A Game Thread deve desanexar a fila e então sinalizar o `CajuHandshake`.
    case inputQueueDestroyed
}

/// Fase de um toque.
public enum CajuTouchPhase: UInt8, BitwiseCopyable, Sendable {
    case began, moved, ended, cancelled
}

/// Evento de toque em pixels da superfície.
public struct CajuTouchEvent: BitwiseCopyable, Sendable, Equatable {
    public var phase: CajuTouchPhase
    public var pointerID: Int32
    public var x: Float
    public var y: Float

    public init(phase: CajuTouchPhase, pointerID: Int32, x: Float, y: Float) {
        self.phase = phase
        self.pointerID = pointerID
        self.x = x
        self.y = y
    }
}
