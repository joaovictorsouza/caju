/// Canal Activity → Game Thread: eventos mais os *handshakes* de destruição.
public final class CajuPlatformChannel: Sendable {
    public let events: CajuEventQueue<CajuPlatformEvent>
    /// Sinalizado pelo laço depois de soltar a janela (`surfaceDestroyed`).
    public let surfaceReleased = CajuHandshake()
    /// Sinalizado pelo laço depois de desanexar a fila de entrada.
    public let inputReleased = CajuHandshake()

    /// - Throws: ``CajuPlatformError/invalidCapacity``.
    public init(eventCapacity: Int = 256) throws(CajuPlatformError) {
        events = try CajuEventQueue(capacity: eventCapacity)
    }
}

/// Implementado pelo jogo/renderizador; todas as chamadas acontecem na Game Thread.
public protocol CajuGameDelegate {
    /// Há janela nova (primeira ou após recriação pelo sistema).
    mutating func surfaceCreated(_ window: CajuNativeWindow)
    /// O sistema mudou o tamanho/orientação da janela atual.
    mutating func surfaceResized()
    /// A janela vai ser tirada: libere tudo que depende dela *antes* de retornar.
    mutating func surfaceDestroyed()
    /// `true` quando há janela e a Activity está em primeiro plano.
    mutating func activeChanged(_ active: Bool)
    /// Um quadro. Só é chamado com `active == true`.
    mutating func drawFrame()
    mutating func touch(_ event: CajuTouchEvent)
}

extension CajuGameDelegate {
    public mutating func surfaceResized() {}
    public mutating func activeChanged(_ active: Bool) {}
    public mutating func touch(_ event: CajuTouchEvent) {}
}

/// Laço da Game Thread: drena eventos, bloqueia quando inativo (sem gastar bateria)
/// e desenha quando ativo.
public enum CajuGameLoop {
    /// Roda até receber ``CajuPlatformEvent/destroyed``.
    public static func run<Delegate: CajuGameDelegate>(
        channel: CajuPlatformChannel,
        delegate: inout Delegate
    ) {
        var resumed = false
        var hasSurface = false
        var active = false
        #if os(Android)
            var input = CajuAndroidInput()
        #endif

        while true {
            let next: CajuPlatformEvent? = active ? channel.events.pop() : channel.events.wait()
            guard let event = next else {
                #if os(Android)
                    input.drain { delegate.touch($0) }
                #endif
                delegate.drawFrame()
                continue
            }
            switch event {
            case .resumed: resumed = true
            case .paused: resumed = false
            case .surfaceCreated(let window):
                hasSurface = true
                delegate.surfaceCreated(window)
            case .surfaceResized: delegate.surfaceResized()
            case .surfaceDestroyed:
                if active {
                    active = false
                    delegate.activeChanged(false)
                }
                hasSurface = false
                delegate.surfaceDestroyed()
                channel.surfaceReleased.signal()
            case .inputQueueCreated(let queue):
                #if os(Android)
                    input.attach(queue)
                #else
                    _ = queue
                #endif
            case .inputQueueDestroyed:
                #if os(Android)
                    input.detach()
                #endif
                channel.inputReleased.signal()
            case .destroyed:
                if active { delegate.activeChanged(false) }
                return
            case .started, .stopped, .focusChanged, .lowMemory: break
            }
            let shouldBeActive = resumed && hasSurface
            if shouldBeActive != active {
                active = shouldBeActive
                delegate.activeChanged(active)
            }
        }
    }
}
