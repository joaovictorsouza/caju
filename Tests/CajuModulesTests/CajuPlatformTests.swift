import CajuPlatform
import Testing

// `#expect` não aceita chamadas mutantes na expressão: estes auxiliares recebem o valor já avaliado.
private func expectEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a == b, sourceLocation: sourceLocation)
}
private func expectTrue(_ a: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a, sourceLocation: sourceLocation)
}

private struct RecordingApp: CajuApplication {
    var events: [CajuPlatformEvent] = []
    var ticks: [CajuFrameTick] = []
    mutating func handle(_ event: CajuPlatformEvent) { events.append(event) }
    mutating func update(_ tick: CajuFrameTick) { ticks.append(tick) }
}

private let surface = CajuPlatformSurface(kind: .headless, nativeHandle: 1, pixelWidth: 100, pixelHeight: 50)
private func t(_ ms: Int) -> CajuTimestamp { CajuTimestamp(nanoseconds: UInt64(ms) * 1_000_000) }

@Suite("CajuPlatform: ciclo de vida")
struct CajuLifecycleTests {
    @Test func transitions() {
        var state = CajuLifecycleState.inactive
        expectEqual(state.apply(.didBecomeActive), .init(from: .inactive, to: .active))
        expectEqual(state.apply(.didBecomeActive), nil)  // duplicado
        expectEqual(state.apply(.willResignActive)?.to, .inactive)
        let toBackground = state.apply(.didEnterBackground)
        #expect(toBackground?.enteredBackground == true)
        #expect(!state.holdsSurface)
        expectEqual(state.apply(.didEnterBackground), nil)
        let back = state.apply(.willEnterForeground)
        #expect(back?.leftBackground == true)
        expectEqual(state.apply(.lowMemory), nil)
        expectEqual(state.apply(.willTerminate)?.to, .terminated)
        expectEqual(state.apply(.didBecomeActive), nil)  // terminado é final
    }

    @Test func androidMayResumeWithoutWillEnterForeground() {
        var state = CajuLifecycleState.background
        expectEqual(state.apply(.didBecomeActive)?.leftBackground, true)
        #expect(state == .active)
    }
}

@Suite("CajuPlatform: fila e laço principal")
struct CajuMainLoopTests {
    @Test func queueIsFifoAndNeverDropsLifecycle() {
        var q = CajuEventQueue(capacity: 3)
        q.push(.surfaceChanged(surface))
        q.push(.lifecycle(.didBecomeActive))
        q.push(.lifecycle(.willResignActive))
        expectTrue(q.push(.lifecycle(.didEnterBackground)))  // cheia: descarta o surfaceChanged antigo
        #expect(q.droppedCount == 1)
        expectEqual(q.pop(), .lifecycle(.didBecomeActive))
        expectEqual(q.pop(), .lifecycle(.willResignActive))
        expectEqual(q.pop(), .lifecycle(.didEnterBackground))
        expectEqual(q.pop(), nil)
        var full = CajuEventQueue(capacity: 1)
        full.push(.lifecycle(.didBecomeActive))
        expectTrue(!full.push(.lifecycle(.willResignActive)))  // nunca perde ciclo de vida: recusa o novo
        #expect(full.droppedCount == 1)
    }

    @Test func rendersOnlyWhenActiveWithSurfaceAndFirstDeltaIsZero() {
        var loop = CajuMainLoop(app: RecordingApp())
        expectEqual(loop.tick(at: t(0)), .skipped(.notActive))
        loop.post(.lifecycle(.didBecomeActive))
        expectEqual(loop.tick(at: t(16)), .skipped(.noSurface))
        loop.post(.surfaceCreated(surface))
        expectEqual(loop.tick(at: t(32)), .rendered(frameIndex: 0))
        expectEqual(loop.tick(at: t(48)), .rendered(frameIndex: 1))
        #expect(loop.app.ticks[0].deltaSeconds == 0)
        #expect(abs(loop.app.ticks[1].deltaSeconds - 0.016) < 1e-9)
    }

    @Test func deltaIsClampedAndResetAfterBackground() {
        var loop = CajuMainLoop(app: RecordingApp(), maximumDelta: 0.05)
        loop.post(.lifecycle(.didBecomeActive))
        loop.post(.surfaceCreated(surface))
        loop.tick(at: t(0))
        loop.tick(at: t(1000))
        #expect(loop.app.ticks[1].deltaSeconds == 0.05)  // pausa longa limitada

        loop.post(.lifecycle(.didEnterBackground))
        loop.post(.surfaceDestroyed)
        expectEqual(loop.tick(at: t(5000)), .skipped(.notActive))
        #expect(loop.surface == nil)
        loop.post(.lifecycle(.willEnterForeground))
        loop.post(.lifecycle(.didBecomeActive))
        loop.post(.surfaceCreated(surface))
        expectEqual(loop.tick(at: t(9000)), .rendered(frameIndex: 2))
        #expect(loop.app.ticks[2].deltaSeconds == 0)  // sem salto de tempo depois de voltar
    }

    @Test func fiftyBackgroundResumeCycles() {
        var loop = CajuMainLoop(app: RecordingApp())
        var now = 0
        loop.post(.lifecycle(.didBecomeActive))
        loop.post(.surfaceCreated(surface))
        for _ in 0..<50 {
            now += 16
            loop.tick(at: t(now))
            loop.post(.lifecycle(.willResignActive))
            loop.post(.lifecycle(.didEnterBackground))
            loop.post(.surfaceDestroyed)
            now += 16
            expectEqual(loop.tick(at: t(now)), .skipped(.notActive))
            loop.post(.lifecycle(.willEnterForeground))
            loop.post(.lifecycle(.didBecomeActive))
            loop.post(.surfaceCreated(surface))
        }
        now += 16
        loop.tick(at: t(now))
        #expect(loop.frameCount == 51)
        #expect(loop.lifecycle == .active)
        #expect(loop.queue.droppedCount == 0)
        #expect(loop.app.ticks.allSatisfy { $0.deltaSeconds <= 0.1 })
    }

    @Test func onDemandRendersOnlyAfterRequest() {
        var loop = CajuMainLoop(app: RecordingApp(), renderPolicy: .onDemand)
        loop.post(.lifecycle(.didBecomeActive))
        loop.post(.surfaceCreated(surface))
        expectEqual(loop.tick(at: t(0)), .rendered(frameIndex: 0))
        expectEqual(loop.tick(at: t(16)), .skipped(.idle))
        loop.requestRedraw()
        expectEqual(loop.tick(at: t(32)), .rendered(frameIndex: 1))
    }

    @Test func terminationStopsEverything() {
        var loop = CajuMainLoop(app: RecordingApp())
        loop.post(.lifecycle(.didBecomeActive))
        loop.post(.surfaceCreated(surface))
        loop.post(.lifecycle(.willTerminate))
        expectEqual(loop.tick(at: t(0)), .skipped(.terminated))
        #expect(loop.app.events.count == 3)
    }
}
