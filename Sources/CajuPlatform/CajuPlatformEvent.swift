/// Evento entregue pela plataforma ao aplicativo, sempre na thread do laço principal (iOS/macOS: thread
/// principal; Android: Game Thread, ADR 0008).
public enum CajuPlatformEvent: Sendable, Equatable {
    case lifecycle(CajuLifecycleEvent)
    /// A superfície passou a existir (primeira vez ou depois de uma destruição).
    case surfaceCreated(CajuPlatformSurface)
    /// Tamanho, escala ou área segura mudaram (rotação, redimensionar janela).
    case surfaceChanged(CajuPlatformSurface)
    /// A superfície foi destruída: pare de apresentar nela antes de retornar do evento.
    case surfaceDestroyed
}

/// Fila de eventos de capacidade fixa (anel), sem alocação depois da criação.
///
/// Uso de uma thread só. Plataformas que recebem eventos de outra thread (Android) fazem a passagem
/// por fila própria e o laço chama `CajuMainLoop.post` na thread de jogo.
public struct CajuEventQueue: Sendable {
    private var storage: [CajuPlatformEvent?]
    private var head = 0
    public private(set) var count = 0
    /// Eventos descartados por fila cheia (deve ser 0; aparece em diagnóstico).
    public private(set) var droppedCount = 0

    public init(capacity: Int = 64) {
        storage = [CajuPlatformEvent?](repeating: nil, count: max(capacity, 1))
    }

    public var capacity: Int { storage.count }
    public var isEmpty: Bool { count == 0 }

    /// Enfileira; se a fila está cheia, descarta o evento mais antigo que não seja de ciclo de vida
    /// (nunca perde `lifecycle`/`surface*`), ou, na falta, o novo `surfaceChanged`.
    @discardableResult
    public mutating func push(_ event: CajuPlatformEvent) -> Bool {
        if count == storage.count {
            guard dropOldestDroppable() else {
                droppedCount += 1
                return false
            }
        }
        storage[(head + count) % storage.count] = event
        count += 1
        return true
    }

    public mutating func pop() -> CajuPlatformEvent? {
        guard count > 0 else { return nil }
        let event = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return event
    }

    private mutating func dropOldestDroppable() -> Bool {
        for offset in 0..<count {
            let i = (head + offset) % storage.count
            if case .surfaceChanged = storage[i] {
                // Remove deslocando os seguintes uma posição para trás.
                var j = offset
                while j + 1 < count {
                    storage[(head + j) % storage.count] = storage[(head + j + 1) % storage.count]
                    j += 1
                }
                storage[(head + count - 1) % storage.count] = nil
                count -= 1
                droppedCount += 1
                return true
            }
        }
        return false
    }
}
