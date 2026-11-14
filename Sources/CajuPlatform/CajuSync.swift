#if canImport(Darwin)
    import Darwin
#elseif canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#endif

/// Fila FIFO limitada (anel pré-alocado) entre a Activity e a Game Thread.
///
/// Sem alocação após o `init`. Se encher, `push` devolve `false` (o chamador
/// decide; eventos de ciclo de vida nunca devem chegar a isso: capacidade folgada).
public final class CajuEventQueue<Event: BitwiseCopyable & Sendable>: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Event>
    private let capacity: Int
    private var head = 0
    private var count = 0
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private let condition: UnsafeMutablePointer<pthread_cond_t>

    /// - Throws: ``CajuPlatformError/invalidCapacity`` se `capacity <= 0`.
    public init(capacity: Int) throws(CajuPlatformError) {
        guard capacity > 0 else { throw .invalidCapacity }
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        mutex = .allocate(capacity: 1)
        condition = .allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deallocate()
        mutex.deallocate()
        storage.deallocate()
    }

    /// Enfileira `event`; `false` se a fila está cheia.
    @discardableResult
    public func push(_ event: Event) -> Bool {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        guard count < capacity else { return false }
        (storage + (head + count) % capacity).initialize(to: event)
        count += 1
        pthread_cond_signal(condition)
        return true
    }

    /// Retira o evento mais antigo sem bloquear.
    public func pop() -> Event? {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return removeFirst()
    }

    /// Bloqueia até haver um evento e o retira.
    public func wait() -> Event {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        while count == 0 { pthread_cond_wait(condition, mutex) }
        return storageFirst()
    }

    private func removeFirst() -> Event? {
        guard count > 0 else { return nil }
        return storageFirst()
    }

    /// Pré-condição interna: `count > 0` e mutex tomado.
    private func storageFirst() -> Event {
        let event = (storage + head).move()
        head = (head + 1) % capacity
        count -= 1
        return event
    }
}

/// Sinal de uso único repetível: a Activity espera até a Game Thread terminar
/// de usar um recurso (janela, fila de entrada) antes de devolver o controle ao sistema.
public final class CajuHandshake: @unchecked Sendable {
    private var signaled = false
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private let condition: UnsafeMutablePointer<pthread_cond_t>

    public init() {
        mutex = .allocate(capacity: 1)
        condition = .allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deallocate()
        mutex.deallocate()
    }

    /// Libera quem espera (ou o próximo `wait`).
    public func signal() {
        pthread_mutex_lock(mutex)
        signaled = true
        pthread_cond_broadcast(condition)
        pthread_mutex_unlock(mutex)
    }

    /// Espera o sinal por até `timeoutMilliseconds`; consome o sinal.
    /// - Returns: `true` se sinalizado, `false` se estourou o tempo.
    @discardableResult
    public func wait(timeoutMilliseconds: Int) -> Bool {
        var deadline = timespec()
        clock_gettime(CLOCK_REALTIME, &deadline)
        let totalNs = Int(deadline.tv_nsec) + (timeoutMilliseconds % 1000) * 1_000_000
        deadline.tv_sec += timeoutMilliseconds / 1000 + totalNs / 1_000_000_000
        deadline.tv_nsec = totalNs % 1_000_000_000

        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        while !signaled {
            if pthread_cond_timedwait(condition, mutex, &deadline) != 0 { break }
        }
        let result = signaled
        signaled = false
        return result
    }
}
