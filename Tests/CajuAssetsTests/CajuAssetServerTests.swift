import CajuAssets
import CajuAssetsCore
import CajuCore
import CajuTesting
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - Tipos e fontes auxiliares de teste

private struct SyntheticMesh: CajuAsset, Equatable {
    var version: Int
    var byteCount: Int
}

private struct SyntheticTagAsset: CajuAsset, Equatable {
    var label: String
}

private struct SyntheticGLTFAsset: CajuAsset, Equatable {
    var meshCount: Int
    var nodeCount: Int
}

private struct SyntheticMeshLoader: CajuAssetLoader {
    func load(
        _ bytes: [UInt8],
        path: CajuAssetPath,
        limits: AssetLimits
    ) async throws(CajuAssetError) -> SyntheticMesh {
        guard bytes.count <= limits.maxInputBytes else {
            throw .decode(
                .limitExceeded(context: path.rawValue, limit: limits.maxInputBytes, requested: bytes.count)
            )
        }
        guard bytes.count >= 2 else {
            throw .decode(.truncated(context: path.rawValue))
        }
        return SyntheticMesh(version: Int(bytes[0]), byteCount: bytes.count)
    }
}

private struct SyntheticGLTFLoader: CajuAssetLoader {
    func load(
        _ bytes: [UInt8],
        path _: CajuAssetPath,
        limits: AssetLimits
    ) async throws(CajuAssetError) -> SyntheticGLTFAsset {
        do {
            let doc = try GLTFParser.parse(bytes, limits: limits)
            return SyntheticGLTFAsset(meshCount: doc.meshes.count, nodeCount: doc.nodes.count)
        } catch {
            throw .decode(error)
        }
    }
}

private struct TestMeshComponent: CajuAssetComponent {
    static let componentID = CajuComponentID(48)
    var assetHandle: CajuAssetHandle<SyntheticMesh>
}

/// Fonte síncrona/assíncrona com barreira manual para testar estados intermediários (`.loading`,
/// `.reloading`) e corridas entre recargas de forma determinística.
private final class ControlledAssetSource: CajuAssetSource, @unchecked Sendable {
    private let lock = TestPosixLock()
    private var payloads: [CajuAssetPath: [UInt8]] = [:]
    private var failures: [CajuAssetPath: CajuAssetError] = [:]
    private var gatedPaths: Set<CajuAssetPath> = []
    private var waiters: [CajuAssetPath: [CheckedContinuation<Void, Never>]] = [:]
    private var readSignals: [CajuAssetPath: [CheckedContinuation<Void, Never>]] = [:]
    private var readCounts: [CajuAssetPath: Int] = [:]

    func setBytes(_ bytes: [UInt8], for path: CajuAssetPath) {
        lock.withLock {
            payloads[path] = bytes
            _ = failures.removeValue(forKey: path)
        }
    }

    func setFailure(_ error: CajuAssetError?, for path: CajuAssetPath) {
        lock.withLock {
            if let error {
                failures[path] = error
            } else {
                _ = failures.removeValue(forKey: path)
            }
        }
    }

    func setGated(_ gated: Bool, for path: CajuAssetPath) {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            if gated {
                gatedPaths.insert(path)
                return []
            } else {
                gatedPaths.remove(path)
                return waiters.removeValue(forKey: path) ?? []
            }
        }
        for c in toResume { c.resume() }
    }

    func releaseNextGate(for path: CajuAssetPath) {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            guard var list = waiters[path], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            if list.isEmpty {
                waiters.removeValue(forKey: path)
            } else {
                waiters[path] = list
            }
            return first
        }
        next?.resume()
    }

    func waitUntilReadStarts(for path: CajuAssetPath) async {
        await withCheckedContinuation { continuation in
            let alreadyWaiting: Bool = lock.withLock {
                if let list = waiters[path], !list.isEmpty {
                    return true
                }
                readSignals[path, default: []].append(continuation)
                return false
            }
            if alreadyWaiting {
                continuation.resume()
            }
        }
    }

    func readCount(for path: CajuAssetPath) -> Int {
        lock.withLock { readCounts[path] ?? 0 }
    }

    func read(_ path: CajuAssetPath) async throws(CajuAssetError) -> [UInt8] {
        let shouldGate = recordReadAndCheckGate(path)
        if shouldGate {
            await awaitGate(path)
        }
        let (failure, bytes) = lock.withLock { (failures[path], payloads[path]) }
        if let failure { throw failure }
        guard let bytes else { throw .notFound(path: path.rawValue) }
        return bytes
    }

    private func recordReadAndCheckGate(_ path: CajuAssetPath) -> Bool {
        let (gated, signals): (Bool, [CheckedContinuation<Void, Never>]) = lock.withLock {
            readCounts[path, default: 0] += 1
            let g = gatedPaths.contains(path)
            let s = readSignals.removeValue(forKey: path) ?? []
            return (g, s)
        }
        for s in signals { s.resume() }
        return gated
    }

    private func awaitGate(_ path: CajuAssetPath) async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if !gatedPaths.contains(path) {
                    return true
                }
                waiters[path, default: []].append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }
}

private final class TestPosixLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        mutex = .allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    func withLock<R>(_ body: () -> R) -> R {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return body()
    }
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    step: Duration = .milliseconds(5),
    _ predicate: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !predicate() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: step)
    }
    return true
}

private func collectEvents(from server: CajuAssetServer) -> [CajuAssetEvent] {
    var out: [CajuAssetEvent] = []
    server.drainEvents { out.append($0) }
    return out
}

// MARK: - Suíte de testes do AssetServer

@Suite("CajuAssets servidor")
struct CajuAssetServerTests {
    @Test func loadRunsOffFrameAndOnlyPublishesOnApplyCompletions() async throws {
        let source = ControlledAssetSource()
        let path = try CajuAssetPath("meshes/chair.bin")
        source.setBytes([7, 1, 2, 3], for: path)
        source.setGated(true, for: path)

        let server = AssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())

        let handle = server.load(SyntheticMesh.self, path: path)
        #expect(server.state(of: handle) == .queued)
        #expect(server.value(of: handle) == nil)
        #expect(server.revision(of: handle) == 0)
        #expect(collectEvents(from: server).isEmpty)

        await source.waitUntilReadStarts(for: path)

        // Primeiro applyCompletions: ainda aguardando I/O -> queued -> loading.
        server.applyCompletions()
        #expect(server.state(of: handle) == .loading)
        #expect(server.state(of: handle).isPending)
        #expect(server.value(of: handle) == nil)
        #expect(collectEvents(from: server).isEmpty)

        // Libera a fonte e espera a tarefa terminar fora do quadro.
        source.setGated(false, for: path)

        // Ainda antes de applyCompletions, nenhum evento foi publicado nem valor visível.
        let loaded = await waitUntil {
            server.applyCompletions()
            return server.state(of: handle) == .loaded
        }
        #expect(loaded)
        #expect(server.value(of: handle) == SyntheticMesh(version: 7, byteCount: 4))
        #expect(server.revision(of: handle) == 1)
        #expect(server.error(of: handle) == nil)

        let events = collectEvents(from: server)
        #expect(events == [CajuAssetEvent(kind: .loaded, asset: handle.erased)])
        #expect(collectEvents(from: server).isEmpty)
    }

    @Test func queuedCompletionAlsoWaitsForApplyCompletionsBeforePublishing() async throws {
        let path = try CajuAssetPath("meshes/instant.bin")
        let source = CajuMemoryAssetSource([path: [3, 9, 9]])
        let server = CajuAssetServer(source: source)

        let gate = AsyncStream<Void>.makeStream()
        server.registerLoader(for: SyntheticMesh.self) { bytes, _, _ in
            gate.continuation.yield(())
            return SyntheticMesh(version: Int(bytes[0]), byteCount: bytes.count)
        }

        let handle = server.load(SyntheticMesh.self, path: path)
        #expect(server.state(of: handle) == .queued)

        var iterator = gate.stream.makeAsyncIterator()
        _ = await iterator.next()
        try? await Task.sleep(for: .milliseconds(10))

        // Mesmo depois de o loader concluir em background, o estado do quadro não muda até applyCompletions.
        #expect(server.state(of: handle) == .queued)
        #expect(server.value(of: handle) == nil)

        server.applyCompletions()
        #expect(server.state(of: handle) == .loaded)
        #expect(server.value(of: handle) == SyntheticMesh(version: 3, byteCount: 3))
        #expect(server.revision(of: handle) == 1)
    }

    @Test func deduplicatesByTypeAndPathAndSeparatesDifferentTypes() async throws {
        let source = ControlledAssetSource()
        let path = try CajuAssetPath("shared/asset.dat")
        source.setBytes([2, 10, 20], for: path)

        let server = CajuAssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())
        server.registerLoader(for: SyntheticTagAsset.self) { bytes, p, _ in
            SyntheticTagAsset(label: "\(p.rawValue):\(bytes.count)")
        }

        let h1 = server.load(SyntheticMesh.self, path: path)
        let h2 = server.load(SyntheticMesh.self, path: path)
        #expect(h1 == h2)

        let hTag = server.load(SyntheticTagAsset.self, path: path)
        #expect(h1.erased != hTag.erased)

        let ready = await waitUntil {
            server.applyCompletions()
            return server.state(of: h1) == .loaded && server.state(of: hTag) == .loaded
        }
        #expect(ready)
        #expect(source.readCount(for: path) == 2)  // 1 por tipo, não 3
        #expect(server.value(of: hTag) == SyntheticTagAsset(label: "shared/asset.dat:3"))

        // h1 teve duas posses (h1 e h2): liberar uma mantém vivo.
        #expect(server.release(h1))
        server.applyCompletions()
        #expect(server.state(of: h1) == .loaded)

        // Liberar a segunda descarrega no próximo applyCompletions.
        #expect(server.release(h2))
        #expect(server.state(of: h2) == .loaded)  // ainda vivo no meio do quadro!
        server.applyCompletions()
        #expect(server.state(of: h1) == .stale)
        #expect(server.value(of: h1) == nil)
        #expect(server.revision(of: h1) == 0)
        #expect(!server.retain(h1))
        #expect(!server.release(h1))

        let events = collectEvents(from: server)
        #expect(events.contains(CajuAssetEvent(kind: .unloaded, asset: h1.erased)))
        #expect(server.state(of: hTag) == .loaded)
    }

    @Test func retainInSameFrameCancelsPendingUnload() async throws {
        let path = try CajuAssetPath("meshes/reused.bin")
        let source = CajuMemoryAssetSource([path: [5, 0]])
        let server = CajuAssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())

        let h1 = server.load(SyntheticMesh.self, path: path)
        let ready = await waitUntil {
            server.applyCompletions()
            return server.state(of: h1) == .loaded
        }
        #expect(ready)
        _ = collectEvents(from: server)

        #expect(server.release(h1))
        // Nova carga (ou retain) antes de applyCompletions cancela a liberação.
        let h2 = server.load(SyntheticMesh.self, path: path)
        #expect(h1 == h2)
        server.applyCompletions()
        #expect(server.state(of: h1) == .loaded)
        #expect(collectEvents(from: server).isEmpty)

        #expect(server.release(h2))
        server.applyCompletions()
        #expect(server.state(of: h1) == .stale)
    }

    @Test func missingLoaderNotFoundAndLimitsErrors() async throws {
        let missingPath = try CajuAssetPath("missing/file.bin")
        let bigPath = try CajuAssetPath("big/file.bin")
        let source = CajuMemoryAssetSource([bigPath: [UInt8](repeating: 1, count: 64)])
        let server = CajuAssetServer(source: source, limits: AssetLimits(maxInputBytes: 16))

        let noLoaderHandle = server.load(SyntheticTagAsset.self, path: missingPath)
        server.registerLoader(SyntheticMeshLoader())
        let missingHandle = server.load(SyntheticMesh.self, path: missingPath)
        let bigHandle = server.load(SyntheticMesh.self, path: bigPath)

        let done = await waitUntil {
            server.applyCompletions()
            return server.state(of: noLoaderHandle) == .failed
                && server.state(of: missingHandle) == .failed
                && server.state(of: bigHandle) == .failed
        }
        #expect(done)
        #expect(server.error(of: noLoaderHandle) == .noLoader(type: "SyntheticTagAsset"))
        #expect(server.error(of: missingHandle) == .notFound(path: "missing/file.bin"))
        #expect(
            server.error(of: bigHandle)
                == .decode(.limitExceeded(context: "big/file.bin", limit: 16, requested: 64))
        )
        #expect(server.value(of: bigHandle) == nil)
    }

    @Test func hotReloadViaMemorySourceKeepsOldValueUntilSwap() async throws {
        let path = try CajuAssetPath("models/hero.bin")
        let source = CajuMemoryAssetSource([path: [1, 2, 3]])
        let server = CajuAssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())

        let h = server.load(SyntheticMesh.self, path: path)
        let firstReady = await waitUntil {
            server.applyCompletions()
            return server.state(of: h) == .loaded
        }
        #expect(firstReady)
        #expect(server.value(of: h) == SyntheticMesh(version: 1, byteCount: 3))
        #expect(server.revision(of: h) == 1)
        _ = collectEvents(from: server)

        // Atualiza bytes e dispara watcher automaticamente.
        source.setBytes([9, 2, 3, 4, 5], for: path)

        let reloaded = await waitUntil {
            server.applyCompletions()
            return server.revision(of: h) == 2
        }
        #expect(reloaded)
        #expect(server.state(of: h) == .loaded)
        #expect(server.value(of: h) == SyntheticMesh(version: 9, byteCount: 5))
        let events = collectEvents(from: server)
        #expect(events == [CajuAssetEvent(kind: .reloaded, asset: h.erased)])
    }

    @Test func reloadingStateExposesOldValueAndFailurePreservesOldValue() async throws {
        let source = ControlledAssetSource()
        let path = try CajuAssetPath("models/controlled.bin")
        source.setBytes([1, 2], for: path)

        let server = CajuAssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())

        let h = server.load(SyntheticMesh.self, path: path)
        let loaded = await waitUntil {
            server.applyCompletions()
            return server.state(of: h) == .loaded
        }
        #expect(loaded)
        _ = collectEvents(from: server)

        // Inicia reload com barreira fechada -> estado fica .reloading e valor antigo continua legível.
        source.setGated(true, for: path)
        source.setFailure(.io(path: path.rawValue, reason: "disco ocupado"), for: path)
        server.reload(path: path)

        await source.waitUntilReadStarts(for: path)
        server.applyCompletions()
        #expect(server.state(of: h) == .reloading)
        #expect(server.state(of: h).hasValue)
        #expect(server.state(of: h).isPending)
        #expect(server.value(of: h) == SyntheticMesh(version: 1, byteCount: 2))
        #expect(server.revision(of: h) == 1)

        // Libera para falhar o reload -> volta para .loaded com valor antigo e erro registrado.
        source.setGated(false, for: path)
        let failedReload = await waitUntil {
            server.applyCompletions()
            return server.state(of: h) == .loaded && server.error(of: h) != nil
        }
        #expect(failedReload)
        #expect(server.value(of: h) == SyntheticMesh(version: 1, byteCount: 2))
        #expect(server.revision(of: h) == 1)
        #expect(server.error(of: h) == .io(path: path.rawValue, reason: "disco ocupado"))
        #expect(collectEvents(from: server) == [CajuAssetEvent(kind: .failed, asset: h.erased)])

        // Novo reload bem-sucedido limpa o erro e incrementa revisão.
        source.setFailure(nil, for: path)
        source.setBytes([4, 5, 6], for: path)
        server.reload(path: path)
        let recovered = await waitUntil {
            server.applyCompletions()
            return server.revision(of: h) == 2
        }
        #expect(recovered)
        #expect(server.error(of: h) == nil)
        #expect(server.value(of: h) == SyntheticMesh(version: 4, byteCount: 3))
    }

    @Test func supersededReloadDiscardsStaleAttemptCompletion() async throws {
        let source = ControlledAssetSource()
        let path = try CajuAssetPath("models/race.bin")
        source.setBytes([1, 0], for: path)

        let server = CajuAssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())

        let h = server.load(SyntheticMesh.self, path: path)
        let ready = await waitUntil {
            server.applyCompletions()
            return server.state(of: h) == .loaded
        }
        #expect(ready)

        // Dispara reload 1 preso na barreira.
        source.setGated(true, for: path)
        source.setBytes([2, 0, 0], for: path)
        server.reload(path: path)
        await source.waitUntilReadStarts(for: path)
        server.applyCompletions()
        #expect(server.state(of: h) == .reloading)

        // Dispara reload 2 sem barreira; só o 2 deve vencer.
        source.setGated(false, for: path)
        // Libera o gate da tentativa 1 apenas após definir payload novo da tentativa 2:
        // mesmo que a tentativa 1 conclua, seu attemptID foi invalidado pela tentativa 2.
        source.setBytes([3, 0, 0, 0], for: path)
        server.reload(path: path)

        let finished = await waitUntil {
            server.applyCompletions()
            return server.state(of: h) == .loaded && server.revision(of: h) == 2
        }
        #expect(finished)
        #expect(server.value(of: h) == SyntheticMesh(version: 3, byteCount: 4))
    }

    @Test func gltfParserIntegrationAndFuzzInheritedFromP2() async throws {
        let path = try CajuAssetPath("scenes/minimal.gltf")
        let fuzzPath = try CajuAssetPath("scenes/fuzz.gltf")
        let validGLTF = Array(#"{"asset":{"version":"2.0"},"nodes":[{"name":"root"}]}"#.utf8)
        let source = CajuMemoryAssetSource([path: validGLTF])
        let server = CajuAssetServer(
            source: source,
            limits: AssetLimits(maxInputBytes: 4096, maxJSONDepth: 16, maxElements: 256)
        )
        server.registerLoader(SyntheticGLTFLoader())

        let h = server.load(SyntheticGLTFAsset.self, path: path)
        let ready = await waitUntil {
            server.applyCompletions()
            return server.state(of: h) == .loaded
        }
        #expect(ready)
        #expect(server.value(of: h) == SyntheticGLTFAsset(meshCount: 0, nodeCount: 1))

        // Fuzz determinístico (P-2): entradas aleatórias nunca travam nem dão crash no servidor/parser.
        var fuzzCases: [[UInt8]] = []
        CajuFuzz.run(seed: 0xA1_F022, iterations: 40) { rng, _ in
            let count = Int(rng.nextUInt32() % 128)
            var bytes = [UInt8](repeating: 0, count: count)
            for j in 0..<count {
                bytes[j] = UInt8(truncatingIfNeeded: rng.nextUInt32())
            }
            fuzzCases.append(bytes)
        }
        for (i, bytes) in fuzzCases.enumerated() {
            source.setBytes(bytes, for: fuzzPath, notifyWatchers: false)
            let fh = server.load(SyntheticGLTFAsset.self, path: fuzzPath)
            let settled = await waitUntil {
                server.applyCompletions()
                return !server.state(of: fh).isPending
            }
            #expect(settled, "Iteração \(i) não estabilizou")
            #expect(server.release(fh))
            server.applyCompletions()
            #expect(server.state(of: fh) == .stale)
        }
    }

    @Test func localFileSourceHotReloadsOnMtimeAndEnforcesLimits() async throws {
        let dir = "/tmp/caju-assets-test-\(getpid())-\(UInt64.random(in: 1...UInt64.max))"
        #expect(mkdir(dir, 0o755) == 0)
        defer {
            _ = unlink("\(dir)/mesh.bin")
            _ = unlink("\(dir)/big.bin")
            _ = rmdir(dir)
        }

        let meshPath = try CajuAssetPath("mesh.bin")
        let bigPath = try CajuAssetPath("big.bin")
        let meshFile = "\(dir)/mesh.bin"
        let bigFile = "\(dir)/big.bin"

        try writeFileBytes([1, 10, 20], to: meshFile)
        try writeFileBytes([UInt8](repeating: 0xAA, count: 128), to: bigFile)

        let source = CajuFileAssetSource(
            rootPath: dir,
            limits: AssetLimits(maxInputBytes: 32),
            pollInterval: .milliseconds(15)
        )
        let server = CajuAssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())

        let h = server.load(SyntheticMesh.self, path: meshPath)
        let hBig = server.load(SyntheticMesh.self, path: bigPath)

        let initialReady = await waitUntil {
            server.applyCompletions()
            return server.state(of: h) == .loaded && server.state(of: hBig) == .failed
        }
        #expect(initialReady)
        #expect(server.value(of: h) == SyntheticMesh(version: 1, byteCount: 3))
        #expect(
            server.error(of: hBig)
                == .decode(.limitExceeded(context: "big.bin", limit: 32, requested: 128))
        )
        _ = collectEvents(from: server)

        // Atualiza conteúdo e garante mudança de tamanho e mtime para detecção por polling.
        try? await Task.sleep(for: .milliseconds(25))
        try writeFileBytes([8, 10, 20, 30, 40], to: meshFile)

        let reloaded = await waitUntil(timeout: .seconds(3)) {
            server.applyCompletions()
            return server.revision(of: h) == 2
        }
        #expect(reloaded)
        #expect(server.value(of: h) == SyntheticMesh(version: 8, byteCount: 5))
        #expect(collectEvents(from: server) == [CajuAssetEvent(kind: .reloaded, asset: h.erased)])
    }

    @Test func ecsHandleTrackerAndMessageQueueIntegration() async throws {
        let path = try CajuAssetPath("meshes/ecs.bin")
        let source = CajuMemoryAssetSource([path: [4, 2, 1]])
        let server = CajuAssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())

        let queue = CajuMessageQueue<CajuAssetEvent>(capacity: 16)
        let world = CajuWorld()
        let tracker = CajuAssetHandleTracker<TestMeshComponent>(expectedEntities: 8)

        let h = server.load(SyntheticMesh.self, path: path)
        let entity = try world.spawn(TestMeshComponent(assetHandle: h))
        tracker.sync(world: world, server: server)

        // Transfere posse exclusiva para a entidade.
        #expect(server.release(h))

        let ready = await waitUntil {
            server.applyCompletions()
            server.drainEvents(into: queue)
            queue.swap()
            return server.state(of: h) == .loaded
        }
        #expect(ready)
        #expect(queue.readCount >= 1)
        #expect(queue[0] == CajuAssetEvent(kind: .loaded, asset: h.erased))

        // Despawn da entidade faz o tracker liberar o handle no próximo sync + applyCompletions.
        try world.despawn(entity)
        tracker.sync(world: world, server: server)
        server.applyCompletions()
        server.drainEvents(into: queue)
        queue.swap()

        #expect(server.state(of: h) == .stale)
        #expect(queue.readCount == 1)
        #expect(queue[0] == CajuAssetEvent(kind: .unloaded, asset: h.erased))
    }

    @Test func handlesAreSendableAndConcurrentLoadsAndHotReloadsAreRaceFreeUnderTSan() async throws {
        let source = CajuMemoryAssetSource()
        let server = CajuAssetServer(source: source)
        server.registerLoader(SyntheticMeshLoader())

        var paths: [CajuAssetPath] = []
        var handles: [CajuAssetHandle<SyntheticMesh>] = []
        for i in 0..<12 {
            let p = try CajuAssetPath("stress/asset_\(i).bin")
            paths.append(p)
            source.setBytes([UInt8(i + 1), 1, 2, 3], for: p, notifyWatchers: false)
            handles.append(server.load(SyntheticMesh.self, path: p))
        }

        // Envia handles entre tarefas para validar Sendable em compilação e execução.
        let handleSnapshot = handles
        let verifiedCount = await Task.detached {
            var count = 0
            for h in handleSnapshot where h.generation >= 1 {
                count += 1
            }
            return count
        }.value
        #expect(verifiedCount == handles.count)

        // Tarefa concorrente dispara atualizações contínuas de hot reload enquanto a Game Thread roda.
        let allPaths = paths
        let writer = Task.detached {
            for round in 0..<25 {
                for (idx, p) in allPaths.enumerated() {
                    source.setBytes([UInt8((round + idx) % 200), 1, 2, 3], for: p)
                }
                await Task.yield()
            }
        }

        for _ in 0..<40 {
            server.applyCompletions()
            for h in handles {
                _ = server.state(of: h)
                _ = server.value(of: h)
                _ = server.revision(of: h)
                _ = server.error(of: h)
            }
            server.drainEvents { _ in }
            await Task.yield()
        }
        await writer.value

        let settled = await waitUntil {
            server.applyCompletions()
            return handles.allSatisfy { server.state(of: $0) == .loaded }
        }
        #expect(settled)

        for h in handles {
            #expect(server.release(h))
        }
        server.applyCompletions()
        for h in handles {
            #expect(server.state(of: h) == .stale)
        }
    }
}

private func writeFileBytes(_ bytes: [UInt8], to path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else {
        throw CajuAssetError.io(path: path, reason: "falha ao criar arquivo temporário")
    }
    defer { close(fd) }
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            #if canImport(Darwin)
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            #elseif canImport(Android)
                return Android.write(fd, base.advanced(by: offset), bytes.count - offset)
            #elseif canImport(Glibc)
                return Glibc.write(fd, base.advanced(by: offset), bytes.count - offset)
            #endif
        }
        if written < 0 {
            if errno == EINTR { continue }
            throw CajuAssetError.io(path: path, reason: "falha ao escrever arquivo temporário")
        }
        offset += written
    }
}
