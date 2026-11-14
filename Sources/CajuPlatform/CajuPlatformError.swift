/// Erros da camada de plataforma (tipados; sem `fatalError`).
public enum CajuPlatformError: Error, Equatable, Sendable {
    /// `pthread_create` falhou com o código `errno` informado.
    case threadCreationFailed(code: Int32)
    /// A capacidade da fila de eventos precisa ser maior que zero.
    case invalidCapacity
}
