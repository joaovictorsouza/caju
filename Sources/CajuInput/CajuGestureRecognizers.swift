import CajuMath
import CajuPlatform

/// Limiares e políticas configuráveis dos reconhecedores de gestos.
///
/// Valores inválidos (negativos ou não finitos) são normalizados para padrões seguros no `init`.
public struct CajuGestureConfiguration: BitwiseCopyable, Sendable, Equatable {
    /// Deslocamento máximo em pontos para um toque ainda contar como *tap*.
    public var tapSlop: Float
    /// Duração máxima em segundos entre *began* e *ended* para contar como *tap*.
    public var tapMaximumDuration: Double
    /// Janela máxima em segundos entre toques consecutivos para incrementar `tapCount`.
    public var multiTapInterval: Double
    /// Distância máxima em pontos entre toques consecutivos para incrementar `tapCount`.
    public var multiTapSlop: Float
    /// Duração mínima em segundos segurando dentro da tolerância para disparar *long press*.
    public var longPressDuration: Double
    /// Deslocamento máximo em pontos permitido enquanto aguarda o *long press*.
    public var longPressSlop: Float
    /// Distância mínima em pontos para iniciar um *pan*.
    public var panThreshold: Float
    /// Variação mínima na distância entre dois dedos (em pontos) para iniciar um *pinch*.
    public var pinchThreshold: Float
    /// Distância mínima considerada entre dois dedos (em pontos) para evitar divisão por zero.
    public var pinchMinimumSpan: Float
    /// Quando `false` (padrão), dois ou mais ponteiros ativos suprimem o *pan* para evitar conflito com *pinch*.
    public var allowPanDuringPinch: Bool

    public init(
        tapSlop: Float = 10,
        tapMaximumDuration: Double = 0.35,
        multiTapInterval: Double = 0.30,
        multiTapSlop: Float = 24,
        longPressDuration: Double = 0.5,
        longPressSlop: Float = 10,
        panThreshold: Float = 10,
        pinchThreshold: Float = 4,
        pinchMinimumSpan: Float = 1,
        allowPanDuringPinch: Bool = false
    ) {
        self.tapSlop = (tapSlop >= 0 && tapSlop.isFinite) ? tapSlop : 10
        self.tapMaximumDuration =
            (tapMaximumDuration > 0 && tapMaximumDuration.isFinite) ? tapMaximumDuration : 0.35
        self.multiTapInterval = (multiTapInterval >= 0 && multiTapInterval.isFinite) ? multiTapInterval : 0.30
        self.multiTapSlop = (multiTapSlop >= 0 && multiTapSlop.isFinite) ? multiTapSlop : 24
        self.longPressDuration =
            (longPressDuration > 0 && longPressDuration.isFinite) ? longPressDuration : 0.5
        self.longPressSlop = (longPressSlop >= 0 && longPressSlop.isFinite) ? longPressSlop : 10
        self.panThreshold = (panThreshold >= 0 && panThreshold.isFinite) ? panThreshold : 10
        self.pinchThreshold = (pinchThreshold >= 0 && pinchThreshold.isFinite) ? pinchThreshold : 4
        self.pinchMinimumSpan =
            (pinchMinimumSpan > 0 && pinchMinimumSpan.isFinite) ? pinchMinimumSpan : 1
        self.allowPanDuringPinch = allowPanDuringPinch
    }
}

/// Máquina de estados pura para reconhecimento de toque rápido (*tap*) com suporte a múltiplos toques.
public struct CajuTapRecognizer: BitwiseCopyable, Sendable, Equatable {
    public enum State: UInt8, BitwiseCopyable, Sendable, Equatable {
        case idle
        case possible
        case failed
    }

    public var configuration: CajuGestureConfiguration
    public private(set) var state: State = .idle

    private var activePointers = CajuInlinePointerIDSet()
    private var candidatePointerID: CajuPointerID = 0
    private var pointerKind: CajuPointerKind = .touch
    private var startPosition: CajuVec2 = .zero
    private var startTimestampNanoseconds: UInt64 = 0

    private var hasLastTap = false
    private var lastTapPosition: CajuVec2 = .zero
    private var lastTapTimestampNanoseconds: UInt64 = 0
    private var lastTapCount: UInt16 = 0

    public init(configuration: CajuGestureConfiguration = CajuGestureConfiguration()) {
        self.configuration = configuration
    }

    /// Alimenta a máquina de estados com um evento bruto de ponteiro.
    public mutating func process(_ event: CajuPointerEvent) -> CajuTapGesture? {
        guard event.position.isFinite else { return nil }

        switch event.phase {
        case .began:
            if activePointers.contains(event.pointerID) {
                if activePointers.count == 1 {
                    beginCandidate(from: event)
                } else {
                    state = .failed
                }
                return nil
            }
            guard activePointers.insert(event.pointerID) else {
                state = .failed
                return nil
            }
            if state == .idle && activePointers.count == 1 {
                beginCandidate(from: event)
            } else {
                state = .failed
            }
            return nil

        case .moved:
            guard activePointers.contains(event.pointerID) else { return nil }
            if state == .possible && event.pointerID == candidatePointerID {
                let distance = event.position.distance(to: startPosition)
                if !distance.isFinite || distance > configuration.tapSlop {
                    state = .failed
                }
            }
            return nil

        case .ended:
            guard activePointers.remove(event.pointerID) else { return nil }
            var recognized: CajuTapGesture?
            if state == .possible && event.pointerID == candidatePointerID {
                let elapsed = event.timestamp.seconds(
                    since: CajuTimestamp(nanoseconds: startTimestampNanoseconds)
                )
                let distance = event.position.distance(to: startPosition)
                if distance.isFinite && distance <= configuration.tapSlop
                    && elapsed <= configuration.tapMaximumDuration
                {
                    let tapCount = nextTapCount(at: event.position, timestamp: event.timestamp)
                    recognized = CajuTapGesture(
                        position: event.position,
                        tapCount: tapCount,
                        pointerKind: pointerKind,
                        timestamp: event.timestamp
                    )
                }
            }
            if activePointers.isEmpty {
                state = .idle
            } else if event.pointerID == candidatePointerID {
                state = .failed
            }
            return recognized

        case .cancelled:
            guard activePointers.remove(event.pointerID) else { return nil }
            if activePointers.isEmpty {
                state = .idle
            } else if event.pointerID == candidatePointerID {
                state = .failed
            }
            return nil
        }
    }

    /// Invalida o candidato atual (ex.: quando *long press* ou *pan* assumem o gesto).
    public mutating func invalidate() {
        if state == .possible {
            state = .failed
        }
    }

    /// Reinicia completamente o reconhecedor, incluindo histórico de multi-tap.
    public mutating func reset() {
        activePointers.removeAll()
        state = .idle
        hasLastTap = false
        lastTapCount = 0
    }

    private mutating func beginCandidate(from event: CajuPointerEvent) {
        state = .possible
        candidatePointerID = event.pointerID
        pointerKind = event.kind
        startPosition = event.position
        startTimestampNanoseconds = event.timestampNanoseconds
    }

    private mutating func nextTapCount(at position: CajuVec2, timestamp: CajuTimestamp) -> UInt16 {
        let count: UInt16
        if hasLastTap {
            let interval = timestamp.seconds(since: CajuTimestamp(nanoseconds: lastTapTimestampNanoseconds))
            let distance = position.distance(to: lastTapPosition)
            if interval <= configuration.multiTapInterval && distance.isFinite
                && distance <= configuration.multiTapSlop
            {
                count = lastTapCount < UInt16.max ? lastTapCount + 1 : UInt16.max
            } else {
                count = 1
            }
        } else {
            count = 1
        }
        hasLastTap = true
        lastTapPosition = position
        lastTapTimestampNanoseconds = timestamp.nanoseconds
        lastTapCount = count
        return count
    }
}

/// Máquina de estados pura para reconhecimento de pressão longa (*long press*) com tempo injetado.
///
/// Chame `advance(to:)` periodicamente com o relógio da simulação/quadro para disparar `.began`
/// quando `longPressDuration` for atingido mesmo sem eventos de movimento.
public struct CajuLongPressRecognizer: BitwiseCopyable, Sendable, Equatable {
    public enum State: UInt8, BitwiseCopyable, Sendable, Equatable {
        case idle
        case possible
        case active
        case failed
    }

    public var configuration: CajuGestureConfiguration
    public private(set) var state: State = .idle

    private var activePointers = CajuInlinePointerIDSet()
    private var candidatePointerID: CajuPointerID = 0
    private var pointerKind: CajuPointerKind = .touch
    private var startPosition: CajuVec2 = .zero
    private var currentPosition: CajuVec2 = .zero
    private var startTimestampNanoseconds: UInt64 = 0

    public init(configuration: CajuGestureConfiguration = CajuGestureConfiguration()) {
        self.configuration = configuration
    }

    /// Alimenta a máquina de estados com um evento bruto de ponteiro.
    public mutating func process(_ event: CajuPointerEvent) -> CajuLongPressGesture? {
        guard event.position.isFinite else { return nil }

        switch event.phase {
        case .began:
            if activePointers.contains(event.pointerID) {
                if state == .active {
                    guard event.pointerID == candidatePointerID else { return nil }
                    let cancelled = makeGesture(phase: .cancelled, at: event.timestamp)
                    if activePointers.count == 1 {
                        beginCandidate(from: event)
                    } else {
                        state = .failed
                    }
                    return cancelled
                }
                if state == .possible && activePointers.count == 1 {
                    beginCandidate(from: event)
                } else {
                    state = .failed
                }
                return nil
            }
            guard activePointers.insert(event.pointerID) else {
                return cancel(at: event.timestamp)
            }
            if state == .idle && activePointers.count == 1 {
                beginCandidate(from: event)
            } else if state == .possible {
                state = .failed
            }
            return nil

        case .moved:
            guard activePointers.contains(event.pointerID) else { return nil }
            guard event.pointerID == candidatePointerID else { return nil }
            currentPosition = event.position
            switch state {
            case .possible:
                let distance = event.position.distance(to: startPosition)
                if !distance.isFinite || distance > configuration.longPressSlop {
                    state = .failed
                    return nil
                }
                return advance(to: event.timestamp)
            case .active:
                return makeGesture(phase: .changed, at: event.timestamp)
            case .idle, .failed:
                return nil
            }

        case .ended:
            guard activePointers.remove(event.pointerID) else { return nil }
            if state == .active && event.pointerID == candidatePointerID {
                currentPosition = event.position
                let ended = makeGesture(phase: .ended, at: event.timestamp)
                state = activePointers.isEmpty ? .idle : .failed
                return ended
            }
            if activePointers.isEmpty {
                state = .idle
            } else if event.pointerID == candidatePointerID {
                state = .failed
            }
            return nil

        case .cancelled:
            guard activePointers.remove(event.pointerID) else { return nil }
            if state == .active && event.pointerID == candidatePointerID {
                let cancelled = makeGesture(phase: .cancelled, at: event.timestamp)
                state = activePointers.isEmpty ? .idle : .failed
                return cancelled
            }
            if activePointers.isEmpty {
                state = .idle
            } else if event.pointerID == candidatePointerID {
                state = .failed
            }
            return nil
        }
    }

    /// Avança o relógio injetado e dispara `.began` se a duração configurada tiver sido alcançada.
    public mutating func advance(to timestamp: CajuTimestamp) -> CajuLongPressGesture? {
        guard state == .possible else { return nil }
        let elapsed = timestamp.seconds(since: CajuTimestamp(nanoseconds: startTimestampNanoseconds))
        guard elapsed >= configuration.longPressDuration else { return nil }
        state = .active
        return CajuLongPressGesture(
            phase: .began,
            position: currentPosition,
            durationSeconds: elapsed,
            pointerKind: pointerKind,
            timestamp: timestamp
        )
    }

    /// Avança o relógio injetado apenas se `position` permanecer dentro de `longPressSlop`.
    @usableFromInline
    mutating func advanceIfWithinSlop(position: CajuVec2, at timestamp: CajuTimestamp)
        -> CajuLongPressGesture?
    {
        guard state == .possible, position.isFinite else { return nil }
        let distance = position.distance(to: startPosition)
        guard distance.isFinite && distance <= configuration.longPressSlop else {
            state = .failed
            return nil
        }
        currentPosition = position
        return advance(to: timestamp)
    }

    /// Cancela o gesto em andamento (emite `.cancelled` apenas se já estava `.active`).
    public mutating func cancel(at timestamp: CajuTimestamp) -> CajuLongPressGesture? {
        if state == .active {
            let cancelled = makeGesture(phase: .cancelled, at: timestamp)
            state = activePointers.isEmpty ? .idle : .failed
            return cancelled
        }
        if state == .possible {
            state = activePointers.isEmpty ? .idle : .failed
        }
        return nil
    }

    /// Verifica se o ponteiro candidato atual continua dentro do raio permitido.
    @inlinable public var isTrackingPossibleCandidate: Bool { state == .possible }

    public mutating func reset() {
        activePointers.removeAll()
        state = .idle
    }

    private mutating func beginCandidate(from event: CajuPointerEvent) {
        state = .possible
        candidatePointerID = event.pointerID
        pointerKind = event.kind
        startPosition = event.position
        currentPosition = event.position
        startTimestampNanoseconds = event.timestampNanoseconds
    }

    private func makeGesture(phase: CajuGesturePhase, at timestamp: CajuTimestamp) -> CajuLongPressGesture {
        let elapsed = timestamp.seconds(since: CajuTimestamp(nanoseconds: startTimestampNanoseconds))
        return CajuLongPressGesture(
            phase: phase,
            position: currentPosition,
            durationSeconds: elapsed,
            pointerKind: pointerKind,
            timestamp: timestamp
        )
    }
}

/// Máquina de estados pura para reconhecimento de arraste (*pan*) de um ponteiro.
public struct CajuPanRecognizer: BitwiseCopyable, Sendable, Equatable {
    public enum State: UInt8, BitwiseCopyable, Sendable, Equatable {
        case idle
        case possible
        case active
        case failed
    }

    public var configuration: CajuGestureConfiguration
    public private(set) var state: State = .idle

    private var activePointers = CajuInlinePointerIDSet()
    private var primaryPointerID: CajuPointerID = 0
    private var pointerKind: CajuPointerKind = .touch
    private var startPosition: CajuVec2 = .zero
    private var lastPosition: CajuVec2 = .zero
    private var lastTimestampNanoseconds: UInt64 = 0

    public init(configuration: CajuGestureConfiguration = CajuGestureConfiguration()) {
        self.configuration = configuration
    }

    /// Alimenta a máquina de estados com um evento bruto de ponteiro.
    public mutating func process(_ event: CajuPointerEvent) -> CajuPanGesture? {
        guard event.position.isFinite else { return nil }

        switch event.phase {
        case .began:
            if activePointers.contains(event.pointerID) {
                if state == .active && event.pointerID == primaryPointerID {
                    let cancelled = makeCancelledGesture(at: event.timestamp)
                    if activePointers.count == 1 {
                        beginCandidate(from: event)
                    } else {
                        state = .failed
                    }
                    return cancelled
                }
                if state == .possible && event.pointerID == primaryPointerID {
                    beginCandidate(from: event)
                }
                return nil
            }
            guard activePointers.insert(event.pointerID) else { return nil }
            if state == .idle && activePointers.count == 1 {
                beginCandidate(from: event)
            }
            return nil

        case .moved:
            guard activePointers.contains(event.pointerID) else { return nil }
            guard event.pointerID == primaryPointerID else { return nil }
            switch state {
            case .possible:
                let distance = event.position.distance(to: startPosition)
                guard distance.isFinite && distance >= configuration.panThreshold else { return nil }
                state = .active
                return advanceMotion(phase: .began, to: event.position, at: event.timestamp)
            case .active:
                return advanceMotion(phase: .changed, to: event.position, at: event.timestamp)
            case .idle, .failed:
                return nil
            }

        case .ended:
            guard activePointers.remove(event.pointerID) else { return nil }
            if state == .active && event.pointerID == primaryPointerID {
                let ended = advanceMotion(phase: .ended, to: event.position, at: event.timestamp)
                state = activePointers.isEmpty ? .idle : .failed
                return ended
            }
            if activePointers.isEmpty {
                state = .idle
            } else if event.pointerID == primaryPointerID {
                state = .failed
            }
            return nil

        case .cancelled:
            guard activePointers.remove(event.pointerID) else { return nil }
            if state == .active && event.pointerID == primaryPointerID {
                let cancelled = makeCancelledGesture(at: event.timestamp)
                state = activePointers.isEmpty ? .idle : .failed
                return cancelled
            }
            if activePointers.isEmpty {
                state = .idle
            } else if event.pointerID == primaryPointerID {
                state = .failed
            }
            return nil
        }
    }

    /// Cancela o pan se estiver ativo ou falha se estava pendente (ex.: ao iniciar um *pinch*).
    public mutating func cancel(at timestamp: CajuTimestamp) -> CajuPanGesture? {
        if state == .active {
            let cancelled = makeCancelledGesture(at: timestamp)
            state = activePointers.isEmpty ? .idle : .failed
            return cancelled
        }
        if state == .possible {
            state = activePointers.isEmpty ? .idle : .failed
        }
        return nil
    }

    public mutating func reset() {
        activePointers.removeAll()
        state = .idle
    }

    private mutating func beginCandidate(from event: CajuPointerEvent) {
        state = .possible
        primaryPointerID = event.pointerID
        pointerKind = event.kind
        startPosition = event.position
        lastPosition = event.position
        lastTimestampNanoseconds = event.timestampNanoseconds
    }

    private mutating func advanceMotion(
        phase: CajuGesturePhase,
        to position: CajuVec2,
        at timestamp: CajuTimestamp
    ) -> CajuPanGesture {
        let delta = position - lastPosition
        let translation = position - startPosition
        let velocity = safeVelocity(delta: delta, from: lastTimestampNanoseconds, to: timestamp.nanoseconds)
        lastPosition = position
        if timestamp.nanoseconds > lastTimestampNanoseconds {
            lastTimestampNanoseconds = timestamp.nanoseconds
        }
        return CajuPanGesture(
            phase: phase,
            startPosition: startPosition,
            position: position,
            translation: translation.isFinite ? translation : .zero,
            delta: delta.isFinite ? delta : .zero,
            velocity: velocity,
            pointerKind: pointerKind,
            timestamp: timestamp
        )
    }

    private func makeCancelledGesture(at timestamp: CajuTimestamp) -> CajuPanGesture {
        let translation = lastPosition - startPosition
        return CajuPanGesture(
            phase: .cancelled,
            startPosition: startPosition,
            position: lastPosition,
            translation: translation.isFinite ? translation : .zero,
            delta: .zero,
            velocity: .zero,
            pointerKind: pointerKind,
            timestamp: timestamp
        )
    }

    private func safeVelocity(delta: CajuVec2, from startNs: UInt64, to endNs: UInt64) -> CajuVec2 {
        guard endNs > startNs else { return .zero }
        let dt = Double(endNs - startNs) / 1_000_000_000.0
        guard dt > 1e-6 && dt.isFinite else { return .zero }
        let v = delta / Float(dt)
        return v.isFinite ? v : .zero
    }
}

/// Máquina de estados pura para reconhecimento de pinça com dois dedos (*pinch*).
///
/// Mantém os dois ponteiros do gesto e ignora ponteiros extras (3º+ dedo) sem perder consistência.
/// O fator `scale` é calculado em relação à distância inicial quando o segundo dedo toca a tela
/// (limitada por `pinchMinimumSpan` para impedir divisão por zero).
public struct CajuPinchRecognizer: BitwiseCopyable, Sendable, Equatable {
    public enum State: UInt8, BitwiseCopyable, Sendable, Equatable {
        case idle
        case waitingForSecondPointer
        case possible
        case active
    }

    private struct TrackedSlot: BitwiseCopyable, Sendable, Equatable {
        var occupied = false
        var pointerID: CajuPointerID = 0
        var position: CajuVec2 = .zero
    }

    public var configuration: CajuGestureConfiguration
    public private(set) var state: State = .idle

    private var first = TrackedSlot()
    private var second = TrackedSlot()
    private var extraPointers = CajuInlinePointerIDSet()
    private var initialRawSpan: Float = 0
    private var initialSafeSpan: Float = 1
    private var previousSafeSpan: Float = 1

    public init(configuration: CajuGestureConfiguration = CajuGestureConfiguration()) {
        self.configuration = configuration
    }

    /// Alimenta a máquina de estados com um evento bruto de ponteiro.
    public mutating func process(_ event: CajuPointerEvent) -> CajuPinchGesture? {
        guard event.position.isFinite else { return nil }

        switch event.phase {
        case .began:
            if first.occupied && first.pointerID == event.pointerID {
                return handleDuplicateBegan(updatingFirst: true, event: event)
            }
            if second.occupied && second.pointerID == event.pointerID {
                return handleDuplicateBegan(updatingFirst: false, event: event)
            }
            if extraPointers.contains(event.pointerID) {
                return nil
            }

            if !first.occupied {
                first = TrackedSlot(occupied: true, pointerID: event.pointerID, position: event.position)
                state = .waitingForSecondPointer
                return nil
            }
            if !second.occupied {
                second = TrackedSlot(occupied: true, pointerID: event.pointerID, position: event.position)
                initializePinchSpan()
                state = .possible
                return nil
            }
            _ = extraPointers.insert(event.pointerID)
            return nil

        case .moved:
            if first.occupied && first.pointerID == event.pointerID {
                first.position = event.position
            } else if second.occupied && second.pointerID == event.pointerID {
                second.position = event.position
            } else {
                return nil
            }

            guard state == .possible || state == .active else { return nil }
            guard let metrics = currentMetrics() else { return nil }

            if state == .possible {
                guard abs(metrics.rawSpan - initialRawSpan) >= configuration.pinchThreshold else {
                    return nil
                }
                state = .active
                let deltaScale = metrics.safeSpan / previousSafeSpan
                previousSafeSpan = metrics.safeSpan
                return CajuPinchGesture(
                    phase: .began,
                    center: metrics.center,
                    scale: metrics.safeSpan / initialSafeSpan,
                    deltaScale: deltaScale.isFinite ? deltaScale : 1,
                    span: metrics.rawSpan,
                    timestamp: event.timestamp
                )
            }

            let deltaScale = metrics.safeSpan / previousSafeSpan
            previousSafeSpan = metrics.safeSpan
            return CajuPinchGesture(
                phase: .changed,
                center: metrics.center,
                scale: metrics.safeSpan / initialSafeSpan,
                deltaScale: deltaScale.isFinite ? deltaScale : 1,
                span: metrics.rawSpan,
                timestamp: event.timestamp
            )

        case .ended:
            if extraPointers.remove(event.pointerID) {
                return nil
            }
            return finishPointer(
                event.pointerID, finalPosition: event.position, phase: .ended, at: event.timestamp)

        case .cancelled:
            if extraPointers.remove(event.pointerID) {
                return nil
            }
            return finishPointer(
                event.pointerID,
                finalPosition: nil,
                phase: .cancelled,
                at: event.timestamp
            )
        }
    }

    /// Cancela o pinch se estiver ativo (mantendo o rastreamento de ponteiros ainda pressionados).
    public mutating func cancel(at timestamp: CajuTimestamp) -> CajuPinchGesture? {
        guard state == .active, let metrics = currentMetrics() else { return nil }
        state = .possible
        initializePinchSpan()
        return CajuPinchGesture(
            phase: .cancelled,
            center: metrics.center,
            scale: metrics.safeSpan / initialSafeSpan,
            deltaScale: 1,
            span: metrics.rawSpan,
            timestamp: timestamp
        )
    }

    public mutating func reset() {
        first = TrackedSlot()
        second = TrackedSlot()
        extraPointers.removeAll()
        state = .idle
        initialRawSpan = 0
        initialSafeSpan = max(1, configuration.pinchMinimumSpan)
        previousSafeSpan = initialSafeSpan
    }

    private mutating func handleDuplicateBegan(
        updatingFirst: Bool,
        event: CajuPointerEvent
    ) -> CajuPinchGesture? {
        var cancelled: CajuPinchGesture?
        if state == .active, let metrics = currentMetrics() {
            cancelled = CajuPinchGesture(
                phase: .cancelled,
                center: metrics.center,
                scale: metrics.safeSpan / initialSafeSpan,
                deltaScale: 1,
                span: metrics.rawSpan,
                timestamp: event.timestamp
            )
        }
        if updatingFirst {
            first.position = event.position
        } else {
            second.position = event.position
        }
        if first.occupied && second.occupied {
            initializePinchSpan()
            state = .possible
        } else {
            state = .waitingForSecondPointer
        }
        return cancelled
    }

    private mutating func finishPointer(
        _ pointerID: CajuPointerID,
        finalPosition: CajuVec2?,
        phase: CajuGesturePhase,
        at timestamp: CajuTimestamp
    ) -> CajuPinchGesture? {
        let matchedFirst = first.occupied && first.pointerID == pointerID
        let matchedSecond = second.occupied && second.pointerID == pointerID
        guard matchedFirst || matchedSecond else { return nil }

        if let finalPosition {
            if matchedFirst { first.position = finalPosition }
            if matchedSecond { second.position = finalPosition }
        }

        var emitted: CajuPinchGesture?
        if state == .active, let metrics = currentMetrics() {
            let deltaScale = metrics.safeSpan / previousSafeSpan
            emitted = CajuPinchGesture(
                phase: phase,
                center: metrics.center,
                scale: metrics.safeSpan / initialSafeSpan,
                deltaScale: (phase == .ended && deltaScale.isFinite) ? deltaScale : 1,
                span: metrics.rawSpan,
                timestamp: timestamp
            )
        }

        if matchedFirst {
            first = second
            second = TrackedSlot()
        } else {
            second = TrackedSlot()
        }
        state = first.occupied ? .waitingForSecondPointer : .idle
        return emitted
    }

    private mutating func initializePinchSpan() {
        let raw = first.position.distance(to: second.position)
        let safeRaw = raw.isFinite ? raw : 0
        let minSpan = max(0.001, configuration.pinchMinimumSpan)
        initialRawSpan = safeRaw
        initialSafeSpan = max(safeRaw, minSpan)
        previousSafeSpan = initialSafeSpan
    }

    private func currentMetrics() -> (center: CajuVec2, rawSpan: Float, safeSpan: Float)? {
        guard first.occupied && second.occupied else { return nil }
        let center = (first.position + second.position) * 0.5
        let raw = first.position.distance(to: second.position)
        guard center.isFinite && raw.isFinite else { return nil }
        let minSpan = max(0.001, configuration.pinchMinimumSpan)
        return (center, raw, max(raw, minSpan))
    }
}
