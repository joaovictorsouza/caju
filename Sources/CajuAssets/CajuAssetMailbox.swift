import CajuAssetsCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#endif

/// Trava síncrona baseada em `pthread_mutex_t` (sem Foundation, compatível com iOS 17+/Linux/Android).
///
/// Nunca deve envolver pontos de suspensão (`await`); use sempre `withLock(_:)` em métodos síncronos.
final class CajuPosixLock: @unchecked Sendable {
    // SAFETY: `mutex` é inicializado no `init`, destruído no `deinit` e usado apenas em `lock`/`unlock`
    // síncronos via `withLock`.
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        mutex = .allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    @inline(__always)
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }
}

/// Resultado de uma tentativa assíncrona de carga ou recarga, pronto para aplicação na *thread* do jogo.
struct CajuAssetCompletion: Sendable {
    let typeID: ObjectIdentifier
    let handle: CajuAnyAssetHandle
    let attemptID: UInt64
    let result: Result<any CajuAsset, CajuAssetError>
}

/// Caixa de correio *thread-safe* entre as tarefas de carga/*hot reload* e a *thread* do jogo.
///
/// Usa ``CajuPosixLock`` em vez de `Synchronization.Mutex` (que exige iOS 18, acima do mínimo iOS 17)
/// e evita Foundation (ADR 0005, ADR 0021). Drenada uma vez por quadro em `applyCompletions()` por troca
/// de buffers (`swap`), sem alocação após estabilizar a capacidade.
final class CajuAssetMailbox: @unchecked Sendable {
    // SAFETY: Todos os campos mutáveis (`completions`, `watchPaths`) são acessados exclusivamente dentro
    // de `lock.withLock`; `drain` troca os arrays por buffers já reservados e libera a trava antes de
    // qualquer processamento na thread do jogo.
    private let lock = CajuPosixLock()
    private var completions: [CajuAssetCompletion] = []
    private var watchPaths: [CajuAssetPath] = []

    init(initialCapacity: Int = 32) {
        let capacity = max(1, initialCapacity)
        completions.reserveCapacity(capacity)
        watchPaths.reserveCapacity(capacity)
    }

    func postCompletion(_ item: CajuAssetCompletion) {
        lock.withLock {
            completions.append(item)
        }
    }

    func postWatchChange(_ path: CajuAssetPath) {
        lock.withLock {
            if !watchPaths.contains(path) {
                watchPaths.append(path)
            }
        }
    }

    func drain(
        completions outCompletions: inout [CajuAssetCompletion],
        watchPaths outWatchPaths: inout [CajuAssetPath]
    ) {
        outCompletions.removeAll(keepingCapacity: true)
        outWatchPaths.removeAll(keepingCapacity: true)
        lock.withLock {
            swap(&completions, &outCompletions)
            swap(&watchPaths, &outWatchPaths)
        }
    }
}
