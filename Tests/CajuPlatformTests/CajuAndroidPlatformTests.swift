import Testing

@testable import CajuPlatform

@Suite("CajuMailbox")
struct CajuEventQueueTests {
    @Test func rejectsZeroCapacity() {
        #expect(throws: CajuPlatformError.invalidCapacity) {
            _ = try CajuMailbox<CajuAndroidEvent>(capacity: 0)
        }
    }

    @Test func fifoOrderAndWrapAround() throws {
        let queue = try CajuMailbox<Int32>(capacity: 3)
        for round in 0..<10 {
            let base = Int32(round * 3)
            #expect(queue.push(base) && queue.push(base + 1) && queue.push(base + 2))
            #expect(queue.push(99) == false)  // cheia
            #expect(queue.pop() == base)
            #expect(queue.pop() == base + 1)
            #expect(queue.pop() == base + 2)
            #expect(queue.pop() == nil)
        }
    }

    @Test func waitBlocksUntilPushFromAnotherThread() throws {
        let queue = try CajuMailbox<CajuAndroidEvent>(capacity: 8)
        let thread = CajuGameThread(name: "test-producer") { queue.push(.resumed) }
        try thread.start()
        #expect(queue.wait() == .resumed)
        thread.join()
    }
}

@Suite("CajuHandshake")
struct CajuHandshakeTests {
    @Test func timesOutWithoutSignal() {
        #expect(CajuHandshake().wait(timeoutMilliseconds: 20) == false)
    }

    @Test func signalBeforeWaitIsKeptAndConsumed() {
        let handshake = CajuHandshake()
        handshake.signal()
        #expect(handshake.wait(timeoutMilliseconds: 1000))
        #expect(handshake.wait(timeoutMilliseconds: 10) == false)
    }
}

private struct RecordingDelegate: CajuAndroidGameDelegate {
    var log: [String] = []
    var framesLeft = 3
    let channel: CajuAndroidChannel

    mutating func surfaceCreated(_ window: CajuNativeWindow) { log.append("created") }
    mutating func surfaceDestroyed() { log.append("destroyed") }
    mutating func activeChanged(_ active: Bool) { log.append(active ? "active" : "inactive") }
    mutating func drawFrame() {
        log.append("frame")
        framesLeft -= 1
        if framesLeft == 0 { channel.events.push(.surfaceDestroyed) }
    }
}

@Suite("CajuAndroidGameLoop")
struct CajuAndroidGameLoopTests {
    @Test func drawsOnlyWhileResumedWithSurfaceAndAcksDestruction() throws {
        let channel = try CajuAndroidChannel()
        var raw: UInt8 = 0
        try withUnsafeMutablePointer(to: &raw) { pointer in
            let window = CajuNativeWindow(raw: UnsafeMutableRawPointer(pointer))
            channel.events.push(.started)
            channel.events.push(.surfaceCreated(window))
            channel.events.push(.resumed)  // → ativo; 3 quadros; o 3º pede .surfaceDestroyed
            var delegate = RecordingDelegate(channel: channel)
            // Após soltar a superfície o laço bloqueia: este produtor o encerra.
            let finisher = CajuGameThread(name: "test-finisher") {
                channel.surfaceReleased.wait(timeoutMilliseconds: 2000)
                channel.events.push(.destroyed)
            }
            try finisher.start()
            CajuAndroidGameLoop.run(channel: channel, delegate: &delegate)
            finisher.join()
            #expect(delegate.log.first == "created")
            #expect(delegate.log.contains("active"))
            #expect(delegate.log.filter { $0 == "frame" }.count == 3)
            #expect(delegate.log.last == "destroyed")
        }
    }
}
