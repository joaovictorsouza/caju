/// Estado de ciclo de vida do aplicativo, comum a iOS, macOS e Android.
public enum CajuLifecycleState: UInt8, Sendable, Hashable {
    /// Em primeiro plano e com foco: roda e renderiza.
    case active
    /// Em primeiro plano sem foco (ex.: central de notificações, diálogo do sistema): não avança a
    /// simulação, mas a superfície continua válida.
    case inactive
    /// Fora da tela: não renderiza, libera a superfície (e a GPU, se pedido) e pausa o relógio.
    case background
    /// Processo encerrando; estado final.
    case terminated

    /// Pode avançar a simulação e renderizar.
    public var isRunning: Bool { self == .active }

    /// O app deve manter a superfície de apresentação (e o *swapchain*) vivos.
    public var holdsSurface: Bool { self == .active || self == .inactive }
}

/// Evento de ciclo de vida emitido pela plataforma.
public enum CajuLifecycleEvent: UInt8, Sendable, Hashable {
    /// iOS `didBecomeActive`; Android `onResume`/foco ganho; macOS `didBecomeActive`.
    case didBecomeActive
    /// iOS `willResignActive`; Android `onPause`/foco perdido.
    case willResignActive
    /// iOS `didEnterBackground`; Android `onStop`.
    case didEnterBackground
    /// iOS `willEnterForeground`; Android `onStart`.
    case willEnterForeground
    /// Aviso de pouca memória: libere caches e transientes (não muda o estado).
    case lowMemory
    /// iOS `willTerminate`; Android `onDestroy`.
    case willTerminate
}

/// Transição de estado resultante de um evento.
public struct CajuLifecycleTransition: Sendable, Equatable {
    public var from: CajuLifecycleState
    public var to: CajuLifecycleState

    public init(from: CajuLifecycleState, to: CajuLifecycleState) {
        self.from = from
        self.to = to
    }

    /// O app acabou de entrar em segundo plano: libere a superfície e pause o relógio.
    public var enteredBackground: Bool { from != .background && to == .background }
    /// O app acabou de sair do segundo plano: recrie a superfície e retome o relógio.
    public var leftBackground: Bool { from == .background && to != .background }
}

extension CajuLifecycleState {
    /// Aplica um evento e devolve a nova transição, ou `nil` se o evento não altera o estado
    /// (duplicado, fora de ordem ou `lowMemory`). Eventos duplicados são normais: UIKit e Android
    /// podem repetir notificações.
    public mutating func apply(_ event: CajuLifecycleEvent) -> CajuLifecycleTransition? {
        let old = self
        let new: CajuLifecycleState
        switch (self, event) {
        case (.terminated, _): return nil
        case (_, .willTerminate): new = .terminated
        case (_, .lowMemory): return nil
        case (.inactive, .didBecomeActive): new = .active
        case (.background, .didBecomeActive): new = .active  // Android pode pular willEnterForeground
        case (.active, .willResignActive): new = .inactive
        case (.active, .didEnterBackground), (.inactive, .didEnterBackground): new = .background
        case (.background, .willEnterForeground): new = .inactive
        default: return nil
        }
        self = new
        return CajuLifecycleTransition(from: old, to: new)
    }
}
