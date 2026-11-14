#if canImport(Darwin)
    import Darwin
#elseif canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#endif

/// Thread própria do laço de jogo (ADR 0008). Nunca é a UI thread do Android.
public final class CajuGameThread: @unchecked Sendable {
    private final class Box {
        let name: String
        let body: @Sendable () -> Void
        init(name: String, body: @escaping @Sendable () -> Void) {
            self.name = name
            self.body = body
        }
    }

    #if canImport(Darwin)
        private var handle: pthread_t?
    #else
        private var handle: pthread_t = 0
    #endif
    private var started = false
    private let name: String
    private let body: @Sendable () -> Void

    public init(name: String, body: @escaping @Sendable () -> Void) {
        self.name = name
        self.body = body
    }

    /// Cria a thread e executa `body` nela.
    /// - Throws: ``CajuPlatformError/threadCreationFailed(code:)``.
    public func start() throws(CajuPlatformError) {
        let box = Unmanaged.passRetained(Box(name: name, body: body))
        #if canImport(Darwin)
            var created: pthread_t?
        #else
            var created: pthread_t = 0
        #endif
        let code = pthread_create(
            &created, nil,
            { argument in
                // `argument` é opcional no Glibc e não opcional no Darwin/Bionic: a conversão cobre os dois.
                guard let raw = argument as UnsafeMutableRawPointer? else { return nil }
                let box = Unmanaged<Box>.fromOpaque(raw).takeRetainedValue()
                // `pthread_setname_np` com nome da própria thread só existe no Darwin; no Glibc/Bionic
                // o símbolo não é exposto ao Swift (sem `_GNU_SOURCE`), então o nome é omitido.
                #if canImport(Darwin)
                    _ = pthread_setname_np(box.name)
                #endif
                box.body()
                return nil
            }, box.toOpaque())
        guard code == 0 else {
            box.release()
            throw .threadCreationFailed(code: code)
        }
        handle = created
        started = true
    }

    /// Espera a thread terminar (idempotente).
    public func join() {
        guard started else { return }
        started = false
        #if canImport(Darwin)
            if let handle { pthread_join(handle, nil) }
        #else
            pthread_join(handle, nil)
        #endif
    }
}
