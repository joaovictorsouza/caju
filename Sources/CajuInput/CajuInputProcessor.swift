import CajuCore
import CajuPlatform

/// Processador de entrada que consome eventos brutos de toque/pointer e emite gestos em uma fila
/// em anel de capacidade fixa, sem alocação após a criação.
///
/// Coordena `CajuPointerTable` e as máquinas de estado `CajuTapRecognizer`,
/// `CajuLongPressRecognizer`, `CajuPanRecognizer` e `CajuPinchRecognizer`, mantendo invariantes
/// consistentes mesmo sob eventos duplicados, fora de ordem ou cancelados.
///
/// ```swift
/// var processor = CajuInputProcessor()
/// let messages = CajuMessageQueue<CajuGestureEvent>(capacity: 64)
/// processor.process(event)
/// processor.advance(to: frameTime)
/// processor.flush(into: messages)
/// messages.swap()
/// ```
public struct CajuInputProcessor: Sendable {
    public var configuration: CajuGestureConfiguration {
        didSet {
            tap.configuration = configuration
            longPress.configuration = configuration
            pan.configuration = configuration
            pinch.configuration = configuration
        }
    }

    public private(set) var pointers: CajuPointerTable
    public private(set) var tap: CajuTapRecognizer
    public private(set) var longPress: CajuLongPressRecognizer
    public private(set) var pan: CajuPanRecognizer
    public private(set) var pinch: CajuPinchRecognizer
    public private(set) var queue: CajuGestureQueue
    /// Total de eventos brutos descartados (posição inválida, ponteiro desconhecido ou tabela cheia).
    public private(set) var ignoredEventCount: Int = 0

    public init(
        configuration: CajuGestureConfiguration = CajuGestureConfiguration(),
        queueCapacity: Int = 64,
        maxPointers: Int = 16
    ) {
        self.configuration = configuration
        self.pointers = CajuPointerTable(capacity: maxPointers)
        self.tap = CajuTapRecognizer(configuration: configuration)
        self.longPress = CajuLongPressRecognizer(configuration: configuration)
        self.pan = CajuPanRecognizer(configuration: configuration)
        self.pinch = CajuPinchRecognizer(configuration: configuration)
        self.queue = CajuGestureQueue(capacity: queueCapacity)
    }

    /// Quantidade de ponteiros atualmente pressionados.
    @inlinable public var activePointerCount: Int { pointers.count }

    /// Processa um evento bruto de toque ou ponteiro unificado sem alocar em heap.
    public mutating func process(_ event: CajuPointerEvent) {
        switch pointers.apply(event) {
        case .ignored:
            ignoredEventCount += 1
        case .restarted(let previous, _):
            let cancelEvent = CajuPointerEvent(
                pointerID: previous.pointerID,
                kind: previous.kind,
                phase: .cancelled,
                position: previous.position,
                buttons: [],
                timestamp: event.timestamp
            )
            dispatchRecognizers(for: cancelEvent)
            dispatchRecognizers(for: event)
        case .began, .moved, .ended, .cancelled:
            dispatchRecognizers(for: event)
        }
    }

    /// Converte e processa um `CajuTouchEvent` da camada `CajuPlatform` (em pixels) usando `scale`.
    public mutating func process(_ touch: CajuTouchEvent, scale: Float, timestamp: CajuTimestamp) {
        process(CajuPointerEvent(touch: touch, scale: scale, timestamp: timestamp))
    }

    /// Avança o relógio injetado dos reconhecedores temporais (ex.: *long press*) sem alocar.
    public mutating func advance(to timestamp: CajuTimestamp) {
        if let longPressBegan = longPress.advance(to: timestamp) {
            tap.invalidate()
            queue.push(.longPress(longPressBegan))
        }
    }

    /// Retira e devolve o próximo gesto reconhecido da fila em anel.
    public mutating func popGesture() -> CajuGestureEvent? {
        queue.pop()
    }

    /// Consome todos os gestos pendentes na fila em ordem FIFO, sem alocar.
    public mutating func drainGestures(_ body: (CajuGestureEvent) -> Void) {
        queue.drain(body)
    }

    /// Despacha todos os gestos pendentes para uma `CajuMessageQueue` do ECS, sem alocar.
    @discardableResult
    public mutating func flush(into messageQueue: CajuMessageQueue<CajuGestureEvent>) -> Int {
        queue.flush(into: messageQueue)
    }

    /// Cancela todos os ponteiros e gestos contínuos ativos (ex.: ao ir para segundo plano).
    public mutating func cancelAll(at timestamp: CajuTimestamp) {
        if let pinchCancelled = pinch.cancel(at: timestamp) {
            queue.push(.pinch(pinchCancelled))
        }
        if let panCancelled = pan.cancel(at: timestamp) {
            queue.push(.pan(panCancelled))
        }
        if let longPressCancelled = longPress.cancel(at: timestamp) {
            queue.push(.longPress(longPressCancelled))
        }
        pointers.clear()
        tap.reset()
        longPress.reset()
        pan.reset()
        pinch.reset()
    }

    /// Reinicia o processador e descarta eventos pendentes na fila mantendo capacidades alocadas.
    public mutating func reset() {
        pointers.clear()
        tap.reset()
        longPress.reset()
        pan.reset()
        pinch.reset()
        queue.clear()
        ignoredEventCount = 0
    }

    private mutating func dispatchRecognizers(for event: CajuPointerEvent) {
        if let pinchGesture = pinch.process(event) {
            queue.push(.pinch(pinchGesture))
        }

        if let panGesture = pan.process(event) {
            if !configuration.allowPanDuringPinch && pointers.count >= 2 && panGesture.phase != .ended
                && panGesture.phase != .cancelled
            {
                if let cancelled = pan.cancel(at: event.timestamp) {
                    queue.push(.pan(cancelled))
                }
            } else {
                queue.push(.pan(panGesture))
            }
        }
        if !configuration.allowPanDuringPinch && pointers.count >= 2 {
            if let cancelled = pan.cancel(at: event.timestamp) {
                queue.push(.pan(cancelled))
            }
        }

        if event.phase == .ended {
            if let longPressBegan = longPress.advanceIfWithinSlop(
                position: event.position,
                at: event.timestamp
            ) {
                tap.invalidate()
                queue.push(.longPress(longPressBegan))
            }
        }
        if let longPressGesture = longPress.process(event) {
            if longPressGesture.phase == .began {
                tap.invalidate()
            }
            queue.push(.longPress(longPressGesture))
        }

        if pan.state == .active || longPress.state == .active || pinch.state == .active {
            tap.invalidate()
        }
        if let tapGesture = tap.process(event) {
            queue.push(.tap(tapGesture))
        }
    }
}
