import CajuAssetsCore
import CajuCore

/// Servidor de assets da engine (A-1, ADR 0021).
///
/// Pertence à *thread* do jogo, como o ``CajuWorld`` (ADR 0003 e 0008). Consultas (`state`, `value`,
/// `error`, `revision`) são síncronas, não bloqueiam e não alocam. Leitura e decodificação rodam em
/// tarefas fora do quadro; conclusões e avisos de *hot reload* chegam por uma caixa de correio e só
/// alteram o estado em ``applyCompletions()``, chamado uma vez por quadro no início.
///
/// ```swift
/// let source = CajuMemoryAssetSource()
/// let server = CajuAssetServer(source: source)
/// server.registerLoader(for: MyMesh.self) { bytes, _, _ in
///     MyMesh(byteCount: bytes.count)
/// }
/// let handle = server.load(MyMesh.self, path: try CajuAssetPath("models/chair.glb"))
/// // No início de cada quadro:
/// server.applyCompletions()
/// ```
public final class CajuAssetServer: CajuAssetServing {
    private let source: any CajuAssetSource
    private let limits: AssetLimits
    private let mailbox: CajuAssetMailbox
    private var buckets: [ObjectIdentifier: AssetBucketBase] = [:]
    private var events: [CajuAssetEvent] = []
    private var drainedCompletions: [CajuAssetCompletion] = []
    private var drainedWatchPaths: [CajuAssetPath] = []
    private var nextAttemptID: UInt64 = 1
    private var watchTask: Task<Void, Never>?
    private var isShutdown = false

    /// Cria um servidor ligado à fonte `source`.
    ///
    /// - Parameters:
    ///   - source: Fonte de bytes (e opcionalmente ``CajuAssetWatching`` para *hot reload* local).
    ///   - limits: Limites repassados aos `CajuAssetLoader`s antes de alocar.
    ///   - enableHotReload: Quando `true` e `source` conforma a ``CajuAssetWatching``, assina `changes()`.
    ///   - eventCapacity: Capacidade inicial pré-reservada para o buffer de eventos por quadro.
    public init(
        source: any CajuAssetSource,
        limits: AssetLimits = .default,
        enableHotReload: Bool = true,
        eventCapacity: Int = 64
    ) {
        self.source = source
        self.limits = limits
        self.mailbox = CajuAssetMailbox(initialCapacity: max(16, eventCapacity))
        let cap = max(16, eventCapacity)
        events.reserveCapacity(cap)
        drainedCompletions.reserveCapacity(cap)
        drainedWatchPaths.reserveCapacity(16)

        if enableHotReload, let watching = source as? any CajuAssetWatching {
            startWatching(watching)
        }
    }

    deinit {
        shutdown()
    }

    /// Registra (ou substitui) o decodificador para o tipo `L.Asset`.
    public func registerLoader<L: CajuAssetLoader>(_ loader: L) {
        let b = bucket(for: L.Asset.self)
        b.decode = { bytes, path, limits in
            do throws(CajuAssetError) {
                return .success(try await loader.load(bytes, path: path, limits: limits))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Registra uma função de decodificação assíncrona para `type`.
    public func registerLoader<A: CajuAsset>(
        for type: A.Type,
        _ decode:
            @escaping @Sendable ([UInt8], CajuAssetPath, AssetLimits) async throws(CajuAssetError) ->
            A
    ) {
        let b = bucket(for: type)
        b.decode = { bytes, path, limits in
            do throws(CajuAssetError) {
                return .success(try await decode(bytes, path, limits))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Pede o asset. Deduplica por `(A.self, path)`: o mesmo par devolve o mesmo handle e soma uma posse.
    /// Nunca falha na hora: erros aparecem em `state(of:)` como `.failed` e em `error(of:)`.
    public func load<A: CajuAsset>(_ type: A.Type, path: CajuAssetPath) -> CajuAssetHandle<A> {
        let b = bucket(for: type)
        if let existing = b.retainIfAlive(path: path) {
            return existing
        }

        let handle = b.reserve(path: path)
        if isShutdown {
            let attemptID = allocateAttemptID()
            b.setAttemptID(attemptID, for: handle)
            mailbox.postCompletion(
                CajuAssetCompletion(
                    typeID: ObjectIdentifier(A.self),
                    handle: handle.erased,
                    attemptID: attemptID,
                    result: .failure(.cancelled)
                )
            )
            return handle
        }

        launchLoad(bucket: b, handle: handle, path: path)
        return handle
    }

    /// Estado atual do handle; `.stale` para handle velho, `invalid` ou de outro servidor. Não aloca.
    public func state<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetState {
        guard handle.generation != 0,
            let b = buckets[ObjectIdentifier(A.self)] as? TypedAssetBucket<A>
        else { return .stale }
        return b.store.state(of: handle)
    }

    /// Valor publicado, se `state.hasValue`. Não aloca. Durante `reloading`, devolve o valor antigo.
    public func value<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> A? {
        guard handle.generation != 0,
            let b = buckets[ObjectIdentifier(A.self)] as? TypedAssetBucket<A>
        else { return nil }
        return b.store.value(of: handle)
    }

    /// Último erro de carga ou recarga; limpo por uma carga bem-sucedida. Não aloca na ausência de erro.
    public func error<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetError? {
        guard handle.generation != 0,
            let b = buckets[ObjectIdentifier(A.self)] as? TypedAssetBucket<A>
        else { return nil }
        return b.store.error(of: handle)
    }

    /// Revisão atual (1 na primeira carga, incrementa a cada troca). `0` sem valor ou para handle velho.
    public func revision<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> UInt32 {
        guard handle.generation != 0,
            let b = buckets[ObjectIdentifier(A.self)] as? TypedAssetBucket<A>
        else { return 0 }
        return b.store.revision(of: handle)
    }

    /// Soma uma posse ao handle. `false` se o handle já for `.stale`.
    @discardableResult
    public func retain<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool {
        guard handle.generation != 0,
            let b = buckets[ObjectIdentifier(A.self)] as? TypedAssetBucket<A>
        else { return false }
        return b.retain(handle)
    }

    /// Tira uma posse. Ao chegar a zero o slot é liberado no próximo ``applyCompletions()``.
    @discardableResult
    public func release<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool {
        guard handle.generation != 0,
            let b = buckets[ObjectIdentifier(A.self)] as? TypedAssetBucket<A>
        else { return false }
        return b.release(handle)
    }

    /// Agenda recarga do caminho em todos os tipos que o mantêm ativo, preservando o handle.
    public func reload(path: CajuAssetPath) {
        guard !isShutdown else { return }
        for b in buckets.values {
            b.reload(path: path, server: self)
        }
    }

    /// Aplica resultados de carga concluídos, pedidos de *hot reload* e libera slots sem posse.
    /// **Único ponto** onde o estado dos handles muda; chamar uma vez por quadro, no início.
    public func applyCompletions() {
        mailbox.drain(completions: &drainedCompletions, watchPaths: &drainedWatchPaths)

        if !drainedWatchPaths.isEmpty {
            for path in drainedWatchPaths {
                reload(path: path)
            }
            drainedWatchPaths.removeAll(keepingCapacity: true)
        }

        for b in buckets.values {
            b.applyPendingStartsAndReloads()
        }

        for item in drainedCompletions {
            buckets[item.typeID]?.applyCompletion(item, events: &events)
        }
        drainedCompletions.removeAll(keepingCapacity: true)

        for b in buckets.values {
            b.applyPendingUnloads(events: &events)
        }
    }

    /// Entrega e esvazia os eventos produzidos desde a última chamada. Sem alocação.
    public func drainEvents(_ body: (CajuAssetEvent) -> Void) {
        for event in events {
            body(event)
        }
        events.removeAll(keepingCapacity: true)
    }

    /// Encaminha os eventos acumulados para uma ``CajuMessageQueue`` e esvazia o buffer interno.
    public func drainEvents(into queue: CajuMessageQueue<CajuAssetEvent>) {
        drainEvents { event in
            _ = queue.send(event)
        }
    }

    /// Cancela tarefas de carga em voo e encerra a assinatura de *hot reload*.
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        watchTask?.cancel()
        watchTask = nil
        for b in buckets.values {
            b.cancelAllTasks()
        }
    }

    // MARK: Privado

    private func startWatching(_ watching: any CajuAssetWatching) {
        let mailbox = self.mailbox
        watchTask = Task.detached(priority: .utility) {
            let stream = watching.changes()
            for await path in stream {
                if Task.isCancelled { break }
                mailbox.postWatchChange(path)
            }
        }
    }

    private func bucket<A: CajuAsset>(for type: A.Type) -> TypedAssetBucket<A> {
        let id = ObjectIdentifier(type)
        if let existing = buckets[id] as? TypedAssetBucket<A> {
            return existing
        }
        let created = TypedAssetBucket<A>()
        buckets[id] = created
        return created
    }

    fileprivate func allocateAttemptID() -> UInt64 {
        let id = nextAttemptID
        nextAttemptID &+= 1
        if nextAttemptID == 0 { nextAttemptID = 1 }
        return id
    }

    fileprivate func launchLoad<A: CajuAsset>(
        bucket: TypedAssetBucket<A>,
        handle: CajuAssetHandle<A>,
        path: CajuAssetPath
    ) {
        let attemptID = allocateAttemptID()
        bucket.setAttemptID(attemptID, for: handle)

        guard let decode = bucket.decode else {
            mailbox.postCompletion(
                CajuAssetCompletion(
                    typeID: ObjectIdentifier(A.self),
                    handle: handle.erased,
                    attemptID: attemptID,
                    result: .failure(.noLoader(type: String(describing: A.self)))
                )
            )
            return
        }

        let source = self.source
        let limits = self.limits
        let mailbox = self.mailbox
        let erasedHandle = handle.erased
        let typeID = ObjectIdentifier(A.self)

        let task = Task.detached(priority: .utility) {
            let result = await CajuAssetServer.run(source: source, decode: decode, path: path, limits: limits)
            // `nil`: cancelada; nada a publicar.
            guard let result else { return }
            mailbox.postCompletion(
                CajuAssetCompletion(
                    typeID: typeID,
                    handle: erasedHandle,
                    attemptID: attemptID,
                    result: result
                )
            )
        }
        bucket.setActiveTask(task, for: handle)
    }

    /// Lê e decodifica fora do quadro. Devolve `nil` se a tarefa foi cancelada (nada a publicar).
    private static func run<A: CajuAsset>(
        source: any CajuAssetSource,
        decode: @Sendable ([UInt8], CajuAssetPath, AssetLimits) async -> Result<A, CajuAssetError>,
        path: CajuAssetPath,
        limits: AssetLimits
    ) async -> Result<any CajuAsset, CajuAssetError>? {
        let outcome: Result<A, CajuAssetError>
        do throws(CajuAssetError) {
            let bytes = try await source.read(path)
            if Task.isCancelled { return nil }
            outcome = await decode(bytes, path, limits)
        } catch {
            outcome = .failure(error)
        }
        if Task.isCancelled { return nil }
        switch outcome {
        case .success(let asset): return .success(asset)
        case .failure(let error): return .failure(error)
        }
    }
}

/// Alias compatível com o nome citado no planejamento e no brief da Onda 1.
public typealias AssetServer = CajuAssetServer

// MARK: - Buckets internos por tipo de asset

private class AssetBucketBase {
    func applyPendingStartsAndReloads() {}
    func applyCompletion(_ item: CajuAssetCompletion, events: inout [CajuAssetEvent]) {}
    func applyPendingUnloads(events: inout [CajuAssetEvent]) {}
    func reload(path: CajuAssetPath, server: CajuAssetServer) {}
    func cancelAllTasks() {}
}

private final class TypedAssetBucket<A: CajuAsset>: AssetBucketBase {
    struct SlotMeta {
        var generation: UInt32 = 0
        var logicalRefCount: UInt32 = 0
        var activeAttemptID: UInt64 = 0
        var pendingBeginLoading = false
        var pendingReload = false
        var pendingUnload = false
        var inPendingStartQueue = false
        var inPendingReloadQueue = false
        var inPendingUnloadQueue = false
        var activeTask: Task<Void, Never>?
    }

    var store = CajuAssetStore<A>()
    var decode: (@Sendable ([UInt8], CajuAssetPath, AssetLimits) async -> Result<A, CajuAssetError>)?
    private var meta: [SlotMeta] = []
    private var pathToHandle: [CajuAssetPath: CajuAssetHandle<A>] = [:]
    private var pendingStartIndices: [UInt32] = []
    private var pendingReloadIndices: [UInt32] = []
    private var pendingUnloadIndices: [UInt32] = []

    func retainIfAlive(path: CajuAssetPath) -> CajuAssetHandle<A>? {
        guard let handle = pathToHandle[path] else { return nil }
        guard store.state(of: handle) != .stale else {
            pathToHandle.removeValue(forKey: path)
            return nil
        }
        let idx = Int(handle.index)
        guard idx < meta.count, meta[idx].generation == handle.generation else {
            pathToHandle.removeValue(forKey: path)
            return nil
        }
        meta[idx].logicalRefCount &+= 1
        meta[idx].pendingUnload = false
        return handle
    }

    func reserve(path: CajuAssetPath) -> CajuAssetHandle<A> {
        let handle = store.reserve(path: path)
        let idx = Int(handle.index)
        while meta.count <= idx {
            meta.append(SlotMeta())
        }
        meta[idx] = SlotMeta(
            generation: handle.generation,
            logicalRefCount: 1,
            activeAttemptID: 0,
            pendingBeginLoading: true,
            pendingReload: false,
            pendingUnload: false,
            inPendingStartQueue: true,
            inPendingReloadQueue: false,
            inPendingUnloadQueue: false,
            activeTask: nil
        )
        pendingStartIndices.append(handle.index)
        pathToHandle[path] = handle
        return handle
    }

    func setAttemptID(_ attemptID: UInt64, for handle: CajuAssetHandle<A>) {
        let idx = Int(handle.index)
        guard idx < meta.count, meta[idx].generation == handle.generation else { return }
        meta[idx].activeAttemptID = attemptID
    }

    func setActiveTask(_ task: Task<Void, Never>?, for handle: CajuAssetHandle<A>) {
        let idx = Int(handle.index)
        guard idx < meta.count, meta[idx].generation == handle.generation else {
            task?.cancel()
            return
        }
        meta[idx].activeTask?.cancel()
        meta[idx].activeTask = task
    }

    func retain(_ handle: CajuAssetHandle<A>) -> Bool {
        guard store.state(of: handle) != .stale else { return false }
        let idx = Int(handle.index)
        guard idx < meta.count, meta[idx].generation == handle.generation else { return false }
        meta[idx].logicalRefCount &+= 1
        meta[idx].pendingUnload = false
        return true
    }

    func release(_ handle: CajuAssetHandle<A>) -> Bool {
        guard store.state(of: handle) != .stale else { return false }
        let idx = Int(handle.index)
        guard idx < meta.count, meta[idx].generation == handle.generation, meta[idx].logicalRefCount > 0
        else {
            return false
        }
        meta[idx].logicalRefCount -= 1
        if meta[idx].logicalRefCount == 0 {
            meta[idx].pendingUnload = true
            if !meta[idx].inPendingUnloadQueue {
                meta[idx].inPendingUnloadQueue = true
                pendingUnloadIndices.append(handle.index)
            }
        }
        return true
    }

    override func reload(path: CajuAssetPath, server: CajuAssetServer) {
        guard let handle = pathToHandle[path] else { return }
        guard store.state(of: handle) != .stale else {
            pathToHandle.removeValue(forKey: path)
            return
        }
        let idx = Int(handle.index)
        guard idx < meta.count, meta[idx].generation == handle.generation, !meta[idx].pendingUnload else {
            return
        }
        meta[idx].activeTask?.cancel()
        meta[idx].activeTask = nil
        meta[idx].pendingReload = true
        if !meta[idx].inPendingReloadQueue {
            meta[idx].inPendingReloadQueue = true
            pendingReloadIndices.append(handle.index)
        }
        server.launchLoad(bucket: self, handle: handle, path: path)
    }

    override func applyPendingStartsAndReloads() {
        for rawIndex in pendingStartIndices {
            let idx = Int(rawIndex)
            guard idx < meta.count else { continue }
            meta[idx].inPendingStartQueue = false
            guard meta[idx].pendingBeginLoading, !meta[idx].pendingUnload else { continue }
            let handle = CajuAssetHandle<A>(index: rawIndex, generation: meta[idx].generation)
            _ = store.beginLoading(handle)
            meta[idx].pendingBeginLoading = false
        }
        pendingStartIndices.removeAll(keepingCapacity: true)

        for rawIndex in pendingReloadIndices {
            let idx = Int(rawIndex)
            guard idx < meta.count else { continue }
            meta[idx].inPendingReloadQueue = false
            guard meta[idx].pendingReload, !meta[idx].pendingUnload else { continue }
            let handle = CajuAssetHandle<A>(index: rawIndex, generation: meta[idx].generation)
            _ = store.beginReload(handle)
            meta[idx].pendingReload = false
        }
        pendingReloadIndices.removeAll(keepingCapacity: true)
    }

    override func applyCompletion(_ item: CajuAssetCompletion, events: inout [CajuAssetEvent]) {
        guard let handle = item.handle.typed(as: A.self) else { return }
        let idx = Int(handle.index)
        guard idx < meta.count,
            meta[idx].generation == handle.generation,
            !meta[idx].pendingUnload,
            meta[idx].activeAttemptID == item.attemptID,
            store.state(of: handle) != .stale
        else { return }

        meta[idx].activeTask = nil
        let wasReloading = store.state(of: handle) == .reloading

        switch item.result {
        case .success(let anyAsset):
            guard let typedAsset = anyAsset as? A else { return }
            if store.complete(handle, value: typedAsset) {
                events.append(CajuAssetEvent(kind: wasReloading ? .reloaded : .loaded, asset: item.handle))
            }
        case .failure(let error):
            if store.fail(handle, error: error) {
                events.append(CajuAssetEvent(kind: .failed, asset: item.handle))
            }
        }
    }

    override func applyPendingUnloads(events: inout [CajuAssetEvent]) {
        for rawIndex in pendingUnloadIndices {
            let idx = Int(rawIndex)
            guard idx < meta.count else { continue }
            meta[idx].inPendingUnloadQueue = false
            guard meta[idx].pendingUnload, meta[idx].logicalRefCount == 0 else { continue }
            let handle = CajuAssetHandle<A>(index: rawIndex, generation: meta[idx].generation)
            guard store.state(of: handle) != .stale else {
                meta[idx] = SlotMeta()
                continue
            }
            meta[idx].activeTask?.cancel()
            if let path = store.path(of: handle), pathToHandle[path] == handle {
                pathToHandle.removeValue(forKey: path)
            }
            if store.release(handle) {
                events.append(CajuAssetEvent(kind: .unloaded, asset: handle.erased))
            }
            meta[idx] = SlotMeta()
        }
        pendingUnloadIndices.removeAll(keepingCapacity: true)
    }

    override func cancelAllTasks() {
        for i in 0..<meta.count {
            meta[i].activeTask?.cancel()
            meta[i].activeTask = nil
        }
    }
}
