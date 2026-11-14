/// Instante monotônico em nanossegundos (`CACurrentMediaTime`, `CLOCK_MONOTONIC`).
public struct CajuTimestamp: Sendable, Hashable, Comparable {
    public var nanoseconds: UInt64
    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    public init(seconds: Double) { self.nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000) }
    public static func < (a: Self, b: Self) -> Bool { a.nanoseconds < b.nanoseconds }

    /// Segundos desde `earlier` (0 se `earlier` é posterior).
    public func seconds(since earlier: CajuTimestamp) -> Double {
        nanoseconds > earlier.nanoseconds ? Double(nanoseconds - earlier.nanoseconds) / 1_000_000_000 : 0
    }
}

/// Dados de um quadro entregues ao aplicativo.
public struct CajuFrameTick: Sendable, Equatable {
    /// Contador de quadros renderizados (começa em 0; não conta quadros pulados).
    public var frameIndex: UInt64
    public var timestamp: CajuTimestamp
    /// Segundos desde o quadro anterior, limitado por `CajuMainLoop.maximumDelta`; **0** no primeiro
    /// quadro e no primeiro depois de voltar do segundo plano (sem "salto" de tempo).
    public var deltaSeconds: Double
    public var surface: CajuPlatformSurface
}

/// Política de produção de quadros.
public enum CajuRenderPolicy: Sendable, Equatable {
    /// Um quadro por *tick* da plataforma (jogos).
    case continuous
    /// Só renderiza depois de `requestRedraw()` ou de eventos; economiza bateria (UI estática).
    case onDemand
}

/// Aplicativo da engine, visto pela plataforma. O laço o chama sempre na mesma thread.
public protocol CajuApplication {
    /// Recebe os eventos de plataforma na ordem de chegada, antes do quadro do mesmo *tick*.
    mutating func handle(_ event: CajuPlatformEvent)
    /// Simula e renderiza um quadro. Só é chamado com a aplicação ativa e com superfície.
    mutating func update(_ tick: CajuFrameTick)
}

/// Motivo de um *tick* não ter produzido quadro.
public enum CajuSkipReason: Sendable, Equatable {
    case notActive
    case noSurface
    case idle
    case terminated
}

public enum CajuTickOutcome: Sendable, Equatable {
    case rendered(frameIndex: UInt64)
    case skipped(CajuSkipReason)
}

/// Laço principal independente de plataforma: consome eventos, mantém o estado de ciclo de vida e a
/// superfície, e chama `CajuApplication.update` a cada *tick* da plataforma (display link, Choreographer).
///
/// É um tipo de valor puro, sem relógio nem threads próprios: testes headless dirigem `tick(at:)` com
/// tempo manual e simulam centenas de ciclos de background/resume (gate do ADR 0006).
public struct CajuMainLoop<App: CajuApplication> {
    public private(set) var app: App
    public private(set) var lifecycle: CajuLifecycleState = .inactive
    public private(set) var surface: CajuPlatformSurface?
    public private(set) var frameCount: UInt64 = 0
    public var renderPolicy: CajuRenderPolicy
    /// Teto para `deltaSeconds` (protege a simulação de pausas longas do depurador).
    public var maximumDelta: Double
    public private(set) var queue: CajuEventQueue

    private var lastTimestamp: CajuTimestamp?
    private var redrawRequested = true

    public init(
        app: App, renderPolicy: CajuRenderPolicy = .continuous, maximumDelta: Double = 0.1,
        eventCapacity: Int = 64
    ) {
        self.app = app
        self.renderPolicy = renderPolicy
        self.maximumDelta = maximumDelta
        self.queue = CajuEventQueue(capacity: eventCapacity)
    }

    /// Enfileira um evento da plataforma (chame na thread do laço).
    @discardableResult
    public mutating func post(_ event: CajuPlatformEvent) -> Bool { queue.push(event) }

    /// Pede um quadro no modo `.onDemand`.
    public mutating func requestRedraw() { redrawRequested = true }

    /// Processa os eventos pendentes e, se couber, produz um quadro.
    @discardableResult
    public mutating func tick(at timestamp: CajuTimestamp) -> CajuTickOutcome {
        while let event = queue.pop() { process(event) }

        guard lifecycle != .terminated else { return .skipped(.terminated) }
        guard lifecycle.isRunning else { return .skipped(.notActive) }
        guard let surface else { return .skipped(.noSurface) }
        if renderPolicy == .onDemand, !redrawRequested { return .skipped(.idle) }
        redrawRequested = false

        var delta = 0.0
        if let last = lastTimestamp { delta = min(timestamp.seconds(since: last), maximumDelta) }
        lastTimestamp = timestamp
        let tick = CajuFrameTick(
            frameIndex: frameCount, timestamp: timestamp, deltaSeconds: delta, surface: surface)
        app.update(tick)
        frameCount += 1
        return .rendered(frameIndex: tick.frameIndex)
    }

    private mutating func process(_ event: CajuPlatformEvent) {
        switch event {
        case .lifecycle(let e):
            if let transition = lifecycle.apply(e) {
                // Parar de ser "ativo" interrompe o relógio: o próximo quadro começa com delta 0.
                if !transition.to.isRunning { lastTimestamp = nil }
                if !transition.to.holdsSurface { surface = nil }
                redrawRequested = true
            }
        case .surfaceCreated(let s), .surfaceChanged(let s):
            surface = s
            redrawRequested = true
        case .surfaceDestroyed:
            surface = nil
        }
        app.handle(event)
    }
}

/// Lado da plataforma: o que cada host (UIKit, AppKit, Activity) implementa para rodar um aplicativo.
///
/// A implementação cria a janela/superfície, traduz as notificações nativas em `CajuPlatformEvent`
/// e dirige um `CajuMainLoop` com o relógio nativo (display link no Apple; Game Thread no Android).
public protocol CajuPlatformHost: AnyObject {
    /// Superfície atual, ou `nil` sem janela/em segundo plano.
    var surface: CajuPlatformSurface? { get }
    var renderPolicy: CajuRenderPolicy { get set }

    /// Pede um quadro (modo `.onDemand`); seguro de qualquer contexto de execução da plataforma.
    func requestRedraw()

    /// Taxa de quadros preferida (0 = máxima da tela).
    func setPreferredFramesPerSecond(_ fps: Int)

    /// Cria a janela e roda o laço até o app terminar; o aplicativo é movido para a thread do laço.
    func run<App: CajuApplication>(_ app: sending App, window: CajuWindowConfiguration)
}
