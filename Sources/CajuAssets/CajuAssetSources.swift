import CajuAssetsCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#endif

/// Fonte sintética de bytes em memória, com suporte a *hot reload* para testes headless e ferramentas.
///
/// Sem Foundation; segura para acesso concorrente entre tarefas de carga e código de teste.
public final class CajuMemoryAssetSource: CajuAssetWatching, @unchecked Sendable {
    // SAFETY: `entries`, `failures` e `continuations` são acessados exclusivamente sob `lock.withLock`.
    // As continuações do `AsyncStream` são notificadas fora do mutex após copiar a lista.
    private let lock = CajuPosixLock()
    private var entries: [CajuAssetPath: [UInt8]]
    private var failures: [CajuAssetPath: CajuAssetError] = [:]
    private var continuations: [UInt64: AsyncStream<CajuAssetPath>.Continuation] = [:]
    private var nextWatcherID: UInt64 = 1

    /// Cria uma fonte em memória opcionalmente pré-populada com `initial`.
    public init(_ initial: [CajuAssetPath: [UInt8]] = [:]) {
        self.entries = initial
    }

    deinit {
        let active = lock.withLock {
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for c in active {
            c.finish()
        }
    }

    /// Define ou substitui os bytes de `path`; opcionalmente notifica assinantes de `changes()`.
    public func setBytes(_ bytes: [UInt8], for path: CajuAssetPath, notifyWatchers: Bool = true) {
        let targets = lock.withLock {
            entries[path] = bytes
            failures.removeValue(forKey: path)
            return notifyWatchers ? Array(continuations.values) : []
        }
        for continuation in targets {
            continuation.yield(path)
        }
    }

    /// Remove `path` da fonte; leituras futuras passam a falhar com ``CajuAssetError/notFound(path:)``.
    public func remove(path: CajuAssetPath, notifyWatchers: Bool = false) {
        let targets = lock.withLock {
            entries.removeValue(forKey: path)
            return notifyWatchers ? Array(continuations.values) : []
        }
        for continuation in targets {
            continuation.yield(path)
        }
    }

    /// Configura um erro sintético para `path` (ou `nil` para restaurar a leitura normal).
    public func setFailure(_ error: CajuAssetError?, for path: CajuAssetPath, notifyWatchers: Bool = false) {
        let targets = lock.withLock {
            if let error {
                failures[path] = error
            } else {
                failures.removeValue(forKey: path)
            }
            return notifyWatchers ? Array(continuations.values) : []
        }
        for continuation in targets {
            continuation.yield(path)
        }
    }

    /// Dispara manualmente um aviso de mudança em `path` para os observadores ativos.
    public func notifyChange(_ path: CajuAssetPath) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(path)
        }
    }

    public func read(_ path: CajuAssetPath) async throws(CajuAssetError) -> [UInt8] {
        try readSync(path)
    }

    private func readSync(_ path: CajuAssetPath) throws(CajuAssetError) -> [UInt8] {
        let (failure, bytes) = lock.withLock { (failures[path], entries[path]) }
        if let failure {
            throw failure
        }
        guard let bytes else {
            throw .notFound(path: path.rawValue)
        }
        return bytes
    }

    public func changes() -> AsyncStream<CajuAssetPath> {
        AsyncStream { continuation in
            let id = registerContinuation(continuation)
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    private func registerContinuation(_ continuation: AsyncStream<CajuAssetPath>.Continuation) -> UInt64 {
        lock.withLock {
            let id = nextWatcherID
            nextWatcherID &+= 1
            continuations[id] = continuation
            return id
        }
    }

    private func removeContinuation(id: UInt64) {
        lock.withLock {
            _ = continuations.removeValue(forKey: id)
        }
    }
}

/// Fonte local de arquivos baseada em POSIX com *hot reload* por polling de `mtime` e tamanho.
///
/// Observa todos os caminhos já solicitados via ``read(_:)`` sem dependências externas nem Foundation.
/// O polling é pensado apenas para desenvolvimento local.
public final class CajuFileAssetSource: CajuAssetWatching, @unchecked Sendable {
    private struct FileStamp: Equatable, Sendable {
        var exists: Bool
        var mtimeSec: Int64
        var mtimeNsec: Int64
        var size: Int64

        static let missing = FileStamp(exists: false, mtimeSec: 0, mtimeNsec: 0, size: 0)
    }

    // SAFETY: `observed` é acessado exclusivamente sob `lock.withLock`. As chamadas POSIX
    // `stat`/`open`/`read` ocorrem fora do mutex para não bloquear outros leitores durante I/O.
    private let lock = CajuPosixLock()
    private let rootPath: String
    private let limits: AssetLimits
    private let pollInterval: Duration
    private var observed: [CajuAssetPath: FileStamp] = [:]

    /// Cria uma fonte apontando para o diretório `rootPath`.
    ///
    /// - Parameters:
    ///   - rootPath: Diretório raiz onde residem os caminhos relativos ``CajuAssetPath``.
    ///   - limits: Limite `maxInputBytes` verificado via `fstat` antes de alocar o buffer de leitura.
    ///   - pollInterval: Intervalo entre varreduras de `mtime` em ``changes()``.
    public init(
        rootPath: String,
        limits: AssetLimits = .default,
        pollInterval: Duration = .milliseconds(250)
    ) {
        if rootPath.count > 1, rootPath.hasSuffix("/") {
            self.rootPath = String(rootPath.dropLast())
        } else {
            self.rootPath = rootPath
        }
        self.limits = limits
        self.pollInterval = pollInterval
    }

    public func read(_ path: CajuAssetPath) async throws(CajuAssetError) -> [UInt8] {
        try readSync(path)
    }

    private func readSync(_ path: CajuAssetPath) throws(CajuAssetError) -> [UInt8] {
        let fullPath = resolveFullPath(path)
        let fd = open(fullPath, O_RDONLY)
        if fd < 0 {
            let err = errno
            recordStamp(Self.missingOrCurrentStamp(at: fullPath), for: path)
            if err == ENOENT || err == ENOTDIR {
                throw .notFound(path: path.rawValue)
            }
            throw .io(path: path.rawValue, reason: Self.errorReason(err))
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let err = errno
            throw .io(path: path.rawValue, reason: Self.errorReason(err))
        }

        let isRegular = (st.st_mode & S_IFMT) == S_IFREG
        guard isRegular else {
            throw .io(path: path.rawValue, reason: "caminho não aponta para arquivo regular")
        }

        guard st.st_size >= 0 else {
            throw .io(path: path.rawValue, reason: "tamanho de arquivo negativo")
        }
        let byteCount64 = Int64(st.st_size)
        guard byteCount64 <= Int64(limits.maxInputBytes) else {
            let requested = Int(clamping: byteCount64)
            throw .decode(
                .limitExceeded(context: path.rawValue, limit: limits.maxInputBytes, requested: requested)
            )
        }

        let byteCount = Int(byteCount64)
        var buffer = [UInt8](repeating: 0, count: byteCount)
        var totalRead = 0
        while totalRead < byteCount {
            let remaining = byteCount - totalRead
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                #if canImport(Darwin)
                    return Darwin.read(fd, base.advanced(by: totalRead), remaining)
                #elseif canImport(Android)
                    return Android.read(fd, base.advanced(by: totalRead), remaining)
                #elseif canImport(Glibc)
                    return Glibc.read(fd, base.advanced(by: totalRead), remaining)
                #endif
            }
            if n > 0 {
                totalRead += n
            } else if n == 0 {
                buffer.removeLast(byteCount - totalRead)
                break
            } else {
                let err = errno
                if err == EINTR { continue }
                throw .io(path: path.rawValue, reason: Self.errorReason(err))
            }
        }

        recordStamp(Self.fileStamp(from: st), for: path)
        return buffer
    }

    public func changes() -> AsyncStream<CajuAssetPath> {
        let interval = pollInterval
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        break
                    }
                    guard let self, !Task.isCancelled else { break }
                    let changed = self.pollChangedPaths()
                    for path in changed {
                        continuation.yield(path)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Executa uma varredura síncrona dos caminhos observados e retorna os que mudaram de `mtime` ou tamanho.
    public func pollChangedPaths() -> [CajuAssetPath] {
        let snapshot = lock.withLock { observed }

        var changed: [CajuAssetPath] = []
        var updates: [(CajuAssetPath, FileStamp)] = []
        for (path, previous) in snapshot {
            let current = Self.missingOrCurrentStamp(at: resolveFullPath(path))
            if current != previous {
                changed.append(path)
                updates.append((path, current))
            }
        }

        if !updates.isEmpty {
            lock.withLock {
                for (path, stamp) in updates {
                    if observed[path] != nil {
                        observed[path] = stamp
                    }
                }
            }
        }
        return changed
    }

    private func resolveFullPath(_ path: CajuAssetPath) -> String {
        if rootPath.isEmpty {
            return path.rawValue
        }
        if rootPath == "/" {
            return "/" + path.rawValue
        }
        return rootPath + "/" + path.rawValue
    }

    private func recordStamp(_ stamp: FileStamp, for path: CajuAssetPath) {
        lock.withLock {
            observed[path] = stamp
        }
    }

    private static func missingOrCurrentStamp(at fullPath: String) -> FileStamp {
        var st = stat()
        guard stat(fullPath, &st) == 0 else {
            return .missing
        }
        return fileStamp(from: st)
    }

    private static func fileStamp(from st: stat) -> FileStamp {
        #if canImport(Darwin)
            return FileStamp(
                exists: true,
                mtimeSec: Int64(st.st_mtimespec.tv_sec),
                mtimeNsec: Int64(st.st_mtimespec.tv_nsec),
                size: Int64(st.st_size)
            )
        #elseif canImport(Android) || canImport(Glibc)
            return FileStamp(
                exists: true,
                mtimeSec: Int64(st.st_mtim.tv_sec),
                mtimeNsec: Int64(st.st_mtim.tv_nsec),
                size: Int64(st.st_size)
            )
        #endif
    }

    private static func errorReason(_ code: Int32) -> String {
        guard let cStr = strerror(code) else {
            return "erro POSIX \(code)"
        }
        return String(cString: cStr)
    }
}
