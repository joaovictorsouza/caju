import CajuCore
import CajuInput
import CajuMath
import CajuPlatform
import CajuTesting
import Testing

// `#expect` não aceita chamadas mutantes na expressão: estes auxiliares recebem o valor já avaliado.
private func expectEqual<T: Equatable>(
    _ a: T,
    _ b: T,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(a == b, sourceLocation: sourceLocation)
}

private func expectTrue(_ a: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a, sourceLocation: sourceLocation)
}

private func expectFalse(_ a: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!a, sourceLocation: sourceLocation)
}

private func expectNil<T>(_ a: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a == nil, sourceLocation: sourceLocation)
}

private func t(_ ms: Int) -> CajuTimestamp {
    CajuTimestamp(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
}

private func pointerEvent(
    _ id: CajuPointerID = 1,
    kind: CajuPointerKind = .touch,
    phase: CajuPointerPhase,
    x: Float,
    y: Float,
    buttons: CajuPointerButtonMask = .primary,
    ms: Int
) -> CajuPointerEvent {
    CajuPointerEvent(
        pointerID: id,
        kind: kind,
        phase: phase,
        position: CajuVec2(x, y),
        buttons: buttons,
        timestamp: t(ms)
    )
}

private struct InputTestPositionComponent: CajuComponent, Equatable {
    static let componentID = CajuComponentID(58)
    var x: Float
    var y: Float
    var taps: UInt16
}

/// Verifica a gramática de ciclo de vida de gestos contínuos (`began -> changed* -> ended|cancelled`).
private struct GestureGrammarValidator {
    private(set) var longPressActive = false
    private(set) var panActive = false
    private(set) var pinchActive = false

    mutating func validate(_ event: CajuGestureEvent) -> Bool {
        switch event {
        case .tap(let tap):
            return tap.position.isFinite && tap.tapCount >= 1
        case .longPress(let lp):
            guard lp.position.isFinite && lp.durationSeconds.isFinite && lp.durationSeconds >= 0 else {
                return false
            }
            return advanceState(&longPressActive, phase: lp.phase)
        case .pan(let pan):
            guard
                pan.startPosition.isFinite && pan.position.isFinite && pan.translation.isFinite
                    && pan.delta.isFinite && pan.velocity.isFinite
            else {
                return false
            }
            return advanceState(&panActive, phase: pan.phase)
        case .pinch(let pinch):
            guard
                pinch.center.isFinite && pinch.scale.isFinite && pinch.deltaScale.isFinite
                    && pinch.span.isFinite && pinch.scale > 0 && pinch.deltaScale > 0 && pinch.span >= 0
            else {
                return false
            }
            return advanceState(&pinchActive, phase: pinch.phase)
        }
    }

    private func advanceState(_ active: inout Bool, phase: CajuGesturePhase) -> Bool {
        switch phase {
        case .began:
            if active { return false }
            active = true
            return true
        case .changed:
            return active
        case .ended, .cancelled:
            if !active { return false }
            active = false
            return true
        }
    }
}

@Suite("CajuInput: ponteiro unificado e tabela")
struct CajuPointerTests {
    @Test func convertsAndroidTouchToLogicalPointsAndSanitizesScale() {
        let touch = CajuTouchEvent(phase: .began, pointerID: 7, x: 300, y: 600)
        let pointer = CajuPointerEvent(touch: touch, scale: 3, timestamp: t(100))
        #expect(pointer.pointerID == CajuPointerID(androidPointerID: 7))
        #expect(pointer.kind == .touch)
        #expect(pointer.phase == .began)
        #expect(pointer.position == CajuVec2(100, 200))
        #expect(pointer.buttons == .primary)
        #expect(pointer.timestamp == t(100))

        let invalidScale = CajuPointerEvent(touch: touch, scale: 0, timestamp: t(100))
        #expect(invalidScale.position == CajuVec2(300, 600))
        let nanScale = CajuPointerEvent(touch: touch, scale: .nan, timestamp: t(100))
        #expect(nanScale.position == CajuVec2(300, 600))
    }

    @Test func tableHandlesDuplicatesUnknownsOverflowAndNonFinite() {
        var table = CajuPointerTable(capacity: 2)
        let b1 = table.apply(pointerEvent(1, kind: .mouse, phase: .began, x: 10, y: 20, ms: 10))
        guard case .began(let snap1) = b1 else {
            Issue.record("Esperado .began")
            return
        }
        #expect(snap1.kind == .mouse)
        #expect(table.count == 1)

        // Move de ponteiro desconhecido é ignorado.
        let unknownMove = table.apply(pointerEvent(99, phase: .moved, x: 1, y: 1, ms: 15))
        #expect(unknownMove == .ignored(.unknownPointer))

        // Posição não finita é descartada e contabilizada.
        let badPos = table.apply(pointerEvent(1, phase: .moved, x: .nan, y: 5, ms: 16))
        #expect(badPos == .ignored(.nonFinitePosition))
        #expect(table.droppedCount == 1)

        // Began duplicado no mesmo ID reinicia preservando contagem = 1.
        let dup = table.apply(pointerEvent(1, phase: .began, x: 30, y: 40, ms: 20))
        guard case .restarted(let prev, let curr) = dup else {
            Issue.record("Esperado .restarted")
            return
        }
        #expect(prev.position == CajuVec2(10, 20))
        #expect(curr.position == CajuVec2(30, 40))
        #expect(table.count == 1)

        // Segundo ponteiro ocupa o 2º slot; terceiro estoura capacidade sem crashar.
        _ = table.apply(pointerEvent(2, phase: .began, x: 50, y: 60, ms: 25))
        #expect(table.count == 2)
        let overflow = table.apply(pointerEvent(3, phase: .began, x: 70, y: 80, ms: 30))
        #expect(overflow == .ignored(.capacityExceeded))
        #expect(table.droppedCount == 2)

        // Timestamp retrógrado não regride o último timestamp registrado.
        let backMove = table.apply(pointerEvent(1, phase: .moved, x: 35, y: 45, ms: 5))
        guard case .moved(let movedSnap) = backMove else {
            Issue.record("Esperado .moved")
            return
        }
        #expect(movedSnap.lastTimestamp == t(20))

        _ = table.apply(pointerEvent(1, phase: .ended, x: 35, y: 45, ms: 40))
        _ = table.apply(pointerEvent(2, phase: .cancelled, x: 50, y: 60, ms: 45))
        #expect(table.isEmpty)
    }

    @Test func gestureQueueRingBufferIsFifoAndBounded() {
        var q = CajuGestureQueue(capacity: 3)
        let e1 = CajuGestureEvent.tap(CajuTapGesture(position: CajuVec2(1, 1), timestamp: t(1)))
        let e2 = CajuGestureEvent.tap(CajuTapGesture(position: CajuVec2(2, 2), timestamp: t(2)))
        let e3 = CajuGestureEvent.tap(CajuTapGesture(position: CajuVec2(3, 3), timestamp: t(3)))
        let e4 = CajuGestureEvent.tap(CajuTapGesture(position: CajuVec2(4, 4), timestamp: t(4)))

        expectTrue(q.push(e1))
        expectTrue(q.push(e2))
        expectEqual(q.pop(), e1)
        expectTrue(q.push(e3))
        expectTrue(q.push(e4))
        expectFalse(q.push(e1))  // cheia
        #expect(q.droppedCount == 1)
        #expect(q.capacity == 3)
        #expect(q.count == 3)

        var drained: [CajuGestureEvent] = []
        q.drain { drained.append($0) }
        #expect(drained == [e2, e3, e4])
        #expect(q.isEmpty)
    }
}

@Suite("CajuInput: reconhecedores de gestos")
struct CajuGestureRecognizersTests {
    @Test func tapRecognizesSingleAndDoubleTapAndRejectsSlopDurationAndCancel() {
        let cfg = CajuGestureConfiguration(
            tapSlop: 8,
            tapMaximumDuration: 0.3,
            multiTapInterval: 0.25,
            multiTapSlop: 20
        )
        var tap = CajuTapRecognizer(configuration: cfg)

        // Tap simples + double tap
        expectNil(tap.process(pointerEvent(1, phase: .began, x: 100, y: 100, ms: 0)))
        #expect(tap.state == .possible)
        expectNil(tap.process(pointerEvent(1, phase: .moved, x: 104, y: 103, ms: 50)))
        let first = tap.process(pointerEvent(1, phase: .ended, x: 105, y: 104, ms: 100))
        #expect(first?.tapCount == 1)
        #expect(tap.state == .idle)

        _ = tap.process(pointerEvent(2, phase: .began, x: 110, y: 108, ms: 200))
        let second = tap.process(pointerEvent(2, phase: .ended, x: 111, y: 108, ms: 280))
        #expect(second?.tapCount == 2)

        // Excede tapSlop
        _ = tap.process(pointerEvent(3, phase: .began, x: 0, y: 0, ms: 1000))
        _ = tap.process(pointerEvent(3, phase: .moved, x: 20, y: 0, ms: 1020))
        #expect(tap.state == .failed)
        let slopFail = tap.process(pointerEvent(3, phase: .ended, x: 20, y: 0, ms: 1050))
        #expect(slopFail == nil)
        #expect(tap.state == .idle)

        // Excede duração máxima
        _ = tap.process(pointerEvent(4, phase: .began, x: 0, y: 0, ms: 2000))
        let durationFail = tap.process(pointerEvent(4, phase: .ended, x: 0, y: 0, ms: 2400))
        #expect(durationFail == nil)

        // Cancelamento não emite tap
        _ = tap.process(pointerEvent(5, phase: .began, x: 0, y: 0, ms: 3000))
        let cancelled = tap.process(pointerEvent(5, phase: .cancelled, x: 0, y: 0, ms: 3020))
        #expect(cancelled == nil)
        #expect(tap.state == .idle)
    }

    @Test func longPressUsesInjectedTimeAndTracksLifecycle() {
        let cfg = CajuGestureConfiguration(longPressDuration: 0.4, longPressSlop: 6)
        var lp = CajuLongPressRecognizer(configuration: cfg)

        _ = lp.process(pointerEvent(1, phase: .began, x: 50, y: 60, ms: 100))
        expectNil(lp.advance(to: t(450)))
        #expect(lp.state == .possible)

        let began = lp.advance(to: t(500))
        #expect(began?.phase == .began)
        #expect(lp.state == .active)
        #expect(abs((began?.durationSeconds ?? 0) - 0.4) < 1e-6)

        let changed = lp.process(pointerEvent(1, phase: .moved, x: 52, y: 61, ms: 600))
        #expect(changed?.phase == .changed)
        #expect(changed?.position == CajuVec2(52, 61))

        let ended = lp.process(pointerEvent(1, phase: .ended, x: 52, y: 61, ms: 700))
        #expect(ended?.phase == .ended)
        #expect(lp.state == .idle)

        // Movimento além do slop antes da duração falha
        _ = lp.process(pointerEvent(2, phase: .began, x: 0, y: 0, ms: 1000))
        _ = lp.process(pointerEvent(2, phase: .moved, x: 15, y: 0, ms: 1100))
        #expect(lp.state == .failed)
        expectNil(lp.advance(to: t(1600)))
        _ = lp.process(pointerEvent(2, phase: .ended, x: 15, y: 0, ms: 1650))
        #expect(lp.state == .idle)
    }

    @Test func panThresholdDeltaVelocityAndZeroDeltaTimeSafety() {
        let cfg = CajuGestureConfiguration(panThreshold: 10)
        var pan = CajuPanRecognizer(configuration: cfg)

        _ = pan.process(pointerEvent(1, kind: .stylus, phase: .began, x: 0, y: 0, ms: 0))
        // Abaixo do limiar: não inicia
        expectNil(pan.process(pointerEvent(1, kind: .stylus, phase: .moved, x: 8, y: 0, ms: 16)))
        #expect(pan.state == .possible)

        // Cruza o limiar
        let began = pan.process(pointerEvent(1, kind: .stylus, phase: .moved, x: 12, y: 0, ms: 32))
        #expect(began?.phase == .began)
        #expect(began?.translation == CajuVec2(12, 0))
        #expect(began?.delta == CajuVec2(12, 0))
        #expect(began?.pointerKind == .stylus)

        // dt == 0 não gera NaN/Infinity em velocidade
        let sameTime = pan.process(pointerEvent(1, kind: .stylus, phase: .moved, x: 22, y: 0, ms: 32))
        #expect(sameTime?.phase == .changed)
        #expect(sameTime?.velocity == .zero)
        #expect(sameTime?.delta == CajuVec2(10, 0))
        #expect(sameTime?.translation == CajuVec2(22, 0))

        // Velocidade com dt = 0.1s e delta = (30, 40) -> (300, 400)
        let moved = pan.process(pointerEvent(1, kind: .stylus, phase: .moved, x: 52, y: 40, ms: 132))
        #expect(abs((moved?.velocity.x ?? 0) - 300) < 1e-2)
        #expect(abs((moved?.velocity.y ?? 0) - 400) < 1e-2)

        let ended = pan.process(pointerEvent(1, kind: .stylus, phase: .ended, x: 52, y: 40, ms: 150))
        #expect(ended?.phase == .ended)
        #expect(pan.state == .idle)
    }

    @Test func pinchTracksScaleCenterAndZeroSpanSafety() {
        let cfg = CajuGestureConfiguration(pinchThreshold: 5, pinchMinimumSpan: 2)
        var pinch = CajuPinchRecognizer(configuration: cfg)

        expectNil(pinch.process(pointerEvent(1, phase: .began, x: 100, y: 100, ms: 0)))
        #expect(pinch.state == .waitingForSecondPointer)
        expectNil(pinch.process(pointerEvent(2, phase: .began, x: 200, y: 100, ms: 10)))
        #expect(pinch.state == .possible)

        // Variação < 5pt: ainda possível
        expectNil(pinch.process(pointerEvent(2, phase: .moved, x: 203, y: 100, ms: 20)))

        // Afasta para span 150 (variação 50 >= 5): began com scale = 1.5
        let began = pinch.process(pointerEvent(2, phase: .moved, x: 250, y: 100, ms: 30))
        #expect(began?.phase == .began)
        #expect(abs((began?.scale ?? 0) - 1.5) < 1e-4)
        #expect(began?.center == CajuVec2(175, 100))

        // Move dedo 1 e 3º dedo extra é ignorado
        expectNil(pinch.process(pointerEvent(3, phase: .began, x: 0, y: 0, ms: 35)))
        let changed = pinch.process(pointerEvent(1, phase: .moved, x: 50, y: 100, ms: 40))
        #expect(changed?.phase == .changed)
        #expect(abs((changed?.scale ?? 0) - 2.0) < 1e-4)
        #expect(changed?.center == CajuVec2(150, 100))

        expectNil(pinch.process(pointerEvent(3, phase: .ended, x: 0, y: 0, ms: 45)))
        let ended = pinch.process(pointerEvent(2, phase: .ended, x: 250, y: 100, ms: 50))
        #expect(ended?.phase == .ended)
        #expect(pinch.state == .waitingForSecondPointer)
        _ = pinch.process(pointerEvent(1, phase: .ended, x: 50, y: 100, ms: 60))
        #expect(pinch.state == .idle)

        // Dedos sobrepostos (span = 0) não geram NaN/Inf
        _ = pinch.process(pointerEvent(10, phase: .began, x: 50, y: 50, ms: 100))
        _ = pinch.process(pointerEvent(11, phase: .began, x: 50, y: 50, ms: 105))
        let spread = pinch.process(pointerEvent(11, phase: .moved, x: 60, y: 50, ms: 115))
        #expect(spread?.phase == .began)
        #expect(spread?.scale.isFinite == true)
        #expect(abs((spread?.scale ?? 0) - 5.0) < 1e-4)  // 10 / minSpan(2) = 5
    }

    @Test func duplicateBeganOnSecondaryAndActiveRecognizersKeepsBalancedGrammar() {
        var lp = CajuLongPressRecognizer(configuration: CajuGestureConfiguration(longPressDuration: 0.2))
        _ = lp.process(pointerEvent(1, phase: .began, x: 10, y: 10, ms: 0))
        let lpBegan = lp.advance(to: t(250))
        #expect(lpBegan?.phase == .began)
        _ = lp.process(pointerEvent(2, phase: .began, x: 50, y: 50, ms: 260))
        // Regressão: began duplicado no ponteiro secundário (2) não pode derrubar o estado ativo sem .cancelled.
        expectNil(lp.process(pointerEvent(2, phase: .began, x: 55, y: 55, ms: 270)))
        #expect(lp.state == .active)
        let lpEnded = lp.process(pointerEvent(1, phase: .ended, x: 10, y: 10, ms: 300))
        #expect(lpEnded?.phase == .ended)
        expectNil(lp.process(pointerEvent(2, phase: .ended, x: 55, y: 55, ms: 310)))
        #expect(lp.state == .idle)

        // Duplicate began no ponteiro ativo do pan emite .cancelled antes de reiniciar.
        var pan = CajuPanRecognizer(configuration: CajuGestureConfiguration(panThreshold: 5))
        _ = pan.process(pointerEvent(1, phase: .began, x: 0, y: 0, ms: 0))
        let panBegan = pan.process(pointerEvent(1, phase: .moved, x: 20, y: 0, ms: 10))
        #expect(panBegan?.phase == .began)
        let panCancelled = pan.process(pointerEvent(1, phase: .began, x: 100, y: 100, ms: 20))
        #expect(panCancelled?.phase == .cancelled)
        #expect(pan.state == .possible)

        // Duplicate began no pinch ativo emite .cancelled antes de reiniciar.
        var pinch = CajuPinchRecognizer(configuration: CajuGestureConfiguration(pinchThreshold: 4))
        _ = pinch.process(pointerEvent(1, phase: .began, x: 0, y: 0, ms: 0))
        _ = pinch.process(pointerEvent(2, phase: .began, x: 100, y: 0, ms: 10))
        let pinchBegan = pinch.process(pointerEvent(2, phase: .moved, x: 120, y: 0, ms: 20))
        #expect(pinchBegan?.phase == .began)
        let pinchCancelled = pinch.process(pointerEvent(2, phase: .began, x: 120, y: 0, ms: 30))
        #expect(pinchCancelled?.phase == .cancelled)
        #expect(pinch.state == .possible)
    }

    @Test func configurationSanitizesInvalidThresholds() {
        let cfg = CajuGestureConfiguration(
            tapSlop: -5,
            tapMaximumDuration: 0,
            multiTapInterval: .nan,
            multiTapSlop: .infinity,
            longPressDuration: -1,
            longPressSlop: .nan,
            panThreshold: -2,
            pinchThreshold: .infinity,
            pinchMinimumSpan: 0
        )
        #expect(cfg.tapSlop == 10)
        #expect(cfg.tapMaximumDuration == 0.35)
        #expect(cfg.multiTapInterval == 0.30)
        #expect(cfg.multiTapSlop == 24)
        #expect(cfg.longPressDuration == 0.5)
        #expect(cfg.longPressSlop == 10)
        #expect(cfg.panThreshold == 10)
        #expect(cfg.pinchThreshold == 4)
        #expect(cfg.pinchMinimumSpan == 1)
    }
}

@Suite("CajuInput: processador e integração ECS")
struct CajuInputProcessorTests {
    @Test func processorSuppressesPanDuringPinchAndHandlesBackgroundCancel() {
        var processor = CajuInputProcessor()
        // Pan inicia com 1 dedo
        processor.process(pointerEvent(1, phase: .began, x: 0, y: 0, ms: 0))
        processor.process(pointerEvent(1, phase: .moved, x: 20, y: 0, ms: 16))
        // 2º dedo chega: suprime pan (.cancelled) e inicia pinch quando afasta
        processor.process(pointerEvent(2, phase: .began, x: 100, y: 0, ms: 32))
        processor.process(pointerEvent(2, phase: .moved, x: 140, y: 0, ms: 48))
        // App entra em segundo plano: cancela tudo
        processor.cancelAll(at: t(64))

        var events: [CajuGestureEvent] = []
        processor.drainGestures { events.append($0) }
        #expect(events.count == 4)
        if case .pan(let p0) = events[0] {
            #expect(p0.phase == .began)
        } else {
            Issue.record("Esperado pan began")
        }
        if case .pan(let p1) = events[1] {
            #expect(p1.phase == .cancelled)
        } else {
            Issue.record("Esperado pan cancelled")
        }
        if case .pinch(let z0) = events[2] {
            #expect(z0.phase == .began)
        } else {
            Issue.record("Esperado pinch began")
        }
        if case .pinch(let z1) = events[3] {
            #expect(z1.phase == .cancelled)
        } else {
            Issue.record("Esperado pinch cancelled")
        }
        #expect(processor.activePointerCount == 0)
    }

    @Test func dispatchesGesturesIntoCajuCoreECSScheduler() throws {
        let world = CajuWorld()
        let entity = try world.spawn(InputTestPositionComponent(x: 0, y: 0, taps: 0))

        let gestureMessages = CajuGestureMessageQueue(capacity: 32)
        let pointerMessages = CajuPointerMessageQueue(capacity: 32)
        #expect(pointerMessages.send(pointerEvent(1, phase: .began, x: 10, y: 20, ms: 0)))
        pointerMessages.swap()
        #expect(pointerMessages.readCount == 1)

        var processor = CajuInputProcessor()
        let scheduler = CajuScheduler(world: world)
        try scheduler.add(
            CajuSystemDescriptor(
                name: "apply-input",
                stage: .update,
                writes: CajuComponentMask(InputTestPositionComponent.componentID)
            ) { ctx throws(CajuAccessError) in
                try ctx.forEach(CajuWrite<InputTestPositionComponent>.self) { comp in
                    gestureMessages.forEachMessage { msg in
                        switch msg {
                        case .tap(let tap):
                            comp.value.taps += tap.tapCount
                        case .pan(let pan):
                            comp.value.x += pan.delta.x
                            comp.value.y += pan.delta.y
                        case .longPress, .pinch:
                            break
                        }
                    }
                }
            }
        )
        try scheduler.build()

        // Quadro 1: tap + início e fim de pan
        processor.process(pointerEvent(1, phase: .began, x: 10, y: 10, ms: 0))
        processor.process(pointerEvent(1, phase: .ended, x: 12, y: 11, ms: 50))
        processor.process(pointerEvent(2, phase: .began, x: 0, y: 0, ms: 100))
        processor.process(pointerEvent(2, phase: .moved, x: 15, y: 5, ms: 120))
        processor.process(pointerEvent(2, phase: .ended, x: 25, y: 10, ms: 140))

        let flushed = processor.flush(into: gestureMessages)
        #expect(flushed == 3)  // tap + pan.began + pan.ended
        gestureMessages.swap()
        try scheduler.tick(delta: 1.0 / 60.0)

        let updated = world.get(InputTestPositionComponent.self, of: entity)
        #expect(updated?.taps == 1)
        #expect(updated?.x == 25)
        #expect(updated?.y == 10)
    }

    @Test func endAfterLongPressDurationWithoutIntermediateAdvanceStillBalancesLifecycle() {
        var processor = CajuInputProcessor(
            configuration: CajuGestureConfiguration(longPressDuration: 0.5, longPressSlop: 10)
        )
        processor.process(pointerEvent(1, phase: .began, x: 40, y: 40, ms: 0))
        processor.process(pointerEvent(1, phase: .ended, x: 41, y: 40, ms: 600))

        var validator = GestureGrammarValidator()
        var phases: [CajuGesturePhase] = []
        processor.drainGestures { event in
            expectTrue(validator.validate(event))
            if case .longPress(let lp) = event {
                phases.append(lp.phase)
            } else {
                Issue.record("Tap não deve disparar quando long press ativa")
            }
        }
        #expect(phases == [.began, .ended])
    }

    @Test func processorAdaptsCajuTouchEventAndSupportsSimultaneousPanDuringPinch() {
        let cfg = CajuGestureConfiguration(panThreshold: 5, pinchThreshold: 5, allowPanDuringPinch: true)
        var processor = CajuInputProcessor(configuration: cfg, queueCapacity: 32, maxPointers: 4)
        processor.process(CajuTouchEvent(phase: .began, pointerID: 1, x: 0, y: 0), scale: 2, timestamp: t(0))
        processor.process(
            CajuTouchEvent(phase: .began, pointerID: 2, x: 200, y: 0), scale: 2, timestamp: t(10))
        processor.process(
            CajuTouchEvent(phase: .moved, pointerID: 1, x: 40, y: 0), scale: 2, timestamp: t(20))

        var sawPan = false
        var sawPinch = false
        processor.drainGestures { event in
            switch event {
            case .pan: sawPan = true
            case .pinch: sawPinch = true
            case .tap, .longPress: break
            }
        }
        #expect(sawPan && sawPinch)
    }
}

@Suite("CajuInput: fuzz determinístico e caminho quente")
struct CajuInputFuzzTests {
    private func randomPointerEvent(
        rng: inout CajuPCG32,
        nowMs: inout Int,
        maxPointerID: UInt64
    ) -> CajuPointerEvent {
        let dtRoll = rng.nextUInt32() % 100
        if dtRoll < 85 {
            nowMs += Int(rng.nextUInt32() % 120)
        } else if dtRoll < 95 {
            // Mesmo timestamp
        } else {
            // Timestamp retrógrado ocasional para testar proteção
            nowMs = max(0, nowMs - Int(rng.nextUInt32() % 30))
        }

        let id = CajuPointerID(UInt64(rng.nextUInt32()) % maxPointerID)
        let phaseRoll = rng.nextUInt32() % 4
        let phase: CajuPointerPhase =
            switch phaseRoll {
            case 0: .began
            case 1: .moved
            case 2: .ended
            default: .cancelled
            }
        let kindRoll = rng.nextUInt32() % 3
        let kind: CajuPointerKind =
            switch kindRoll {
            case 0: .touch
            case 1: .mouse
            default: .stylus
            }

        let coordRoll = rng.nextUInt32() % 100
        let pos: CajuVec2
        if coordRoll < 94 {
            pos = CajuVec2(rng.nextFloat(in: -500...1500), rng.nextFloat(in: -500...1500))
        } else if coordRoll < 97 {
            pos = CajuVec2(rng.nextFloat(in: -1e12...1e12), rng.nextFloat(in: -1e12...1e12))
        } else {
            pos = CajuVec2(Float.nan, Float.infinity)
        }

        return CajuPointerEvent(
            pointerID: id,
            kind: kind,
            phase: phase,
            position: pos,
            buttons: phase == .ended || phase == .cancelled ? [] : .primary,
            timestamp: t(nowMs)
        )
    }

    @Test func fuzzRecognizersAndProcessorMaintainGrammarAndConsistency() {
        CajuFuzz.run(seed: 0xCA10_1A97, iterations: 400) { rng, _ in
            var processor = CajuInputProcessor(queueCapacity: 128, maxPointers: 8)
            var tap = CajuTapRecognizer()
            var lp = CajuLongPressRecognizer()
            var pan = CajuPanRecognizer()
            var pinch = CajuPinchRecognizer()

            var procGrammar = GestureGrammarValidator()
            var standaloneGrammar = GestureGrammarValidator()
            var nowMs = 0

            for step in 0..<80 {
                let ev = randomPointerEvent(rng: &rng, nowMs: &nowMs, maxPointerID: 12)
                processor.process(ev)
                if step % 3 == 0 {
                    nowMs += Int(rng.nextUInt32() % 200)
                    processor.advance(to: t(nowMs))
                    if let lpBegan = lp.advance(to: t(nowMs)) {
                        expectTrue(standaloneGrammar.validate(.longPress(lpBegan)))
                    }
                }
                if let g = tap.process(ev) { expectTrue(standaloneGrammar.validate(.tap(g))) }
                if let g = lp.process(ev) { expectTrue(standaloneGrammar.validate(.longPress(g))) }
                if let g = pan.process(ev) { expectTrue(standaloneGrammar.validate(.pan(g))) }
                if let g = pinch.process(ev) { expectTrue(standaloneGrammar.validate(.pinch(g))) }

                processor.drainGestures { event in
                    expectTrue(procGrammar.validate(event))
                }
                #expect(processor.activePointerCount >= 0 && processor.activePointerCount <= 8)
            }

            // Cancela todos os ponteiros restantes e verifica fechamento limpo.
            processor.cancelAll(at: t(nowMs + 10))
            processor.drainGestures { event in
                expectTrue(procGrammar.validate(event))
            }
            #expect(processor.activePointerCount == 0)
            #expect(!procGrammar.longPressActive)
            #expect(!procGrammar.panActive)
            #expect(!procGrammar.pinchActive)

            // Cancela todos os possíveis IDs nos reconhecedores isolados também.
            for rawID in UInt64(0)..<12 {
                let cancelEv = pointerEvent(
                    CajuPointerID(rawID),
                    phase: .cancelled,
                    x: 0,
                    y: 0,
                    ms: nowMs + 20
                )
                _ = tap.process(cancelEv)
                if let g = lp.process(cancelEv) { expectTrue(standaloneGrammar.validate(.longPress(g))) }
                if let g = pan.process(cancelEv) { expectTrue(standaloneGrammar.validate(.pan(g))) }
                if let g = pinch.process(cancelEv) { expectTrue(standaloneGrammar.validate(.pinch(g))) }
            }
            #expect(tap.state == .idle)
            #expect(lp.state == .idle)
            #expect(pan.state == .idle)
            #expect(pinch.state == .idle)
            #expect(!standaloneGrammar.longPressActive)
            #expect(!standaloneGrammar.panActive)
            #expect(!standaloneGrammar.pinchActive)
        }
    }

    @Test func hotPathSoakPreservesFixedQueueAndMessageCapacities() {
        var processor = CajuInputProcessor(queueCapacity: 16, maxPointers: 8)
        let messages = CajuGestureMessageQueue(capacity: 16)
        var totalFlushed = 0

        for i in 0..<2_000 {
            let baseMs = i * 50
            processor.process(pointerEvent(1, phase: .began, x: 0, y: 0, ms: baseMs))
            processor.process(pointerEvent(1, phase: .moved, x: 30, y: 10, ms: baseMs + 16))
            processor.process(pointerEvent(1, phase: .ended, x: 40, y: 15, ms: baseMs + 32))
            totalFlushed += processor.flush(into: messages)
            messages.swap()
        }

        #expect(totalFlushed == 4_000)  // 2_000 * (pan.began + pan.ended)
        #expect(processor.queue.capacity == 16)
        #expect(processor.queue.droppedCount == 0)
        #expect(messages.droppedCount == 0)
    }
}
