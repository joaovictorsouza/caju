/// Orçamento de bytes enviados à GPU por quadro (NFR de travadas: nenhum upload deve estourar o quadro).
///
/// O gerenciador de recursos chama `reserve` antes de cada upload e adia o que não couber para o
/// quadro seguinte. Um upload maior que o orçamento inteiro é aceito sozinho (sem inanição).
public struct CajuUploadBudget: Sendable, Equatable {
    /// Bytes permitidos por quadro.
    public var bytesPerFrame: Int
    public private(set) var usedThisFrame: Int = 0

    public init(bytesPerFrame: Int) {
        self.bytesPerFrame = max(bytesPerFrame, 0)
    }

    /// Bytes ainda disponíveis neste quadro.
    public var remaining: Int { max(bytesPerFrame - usedThisFrame, 0) }

    /// Zera o contador; chame no início de cada quadro.
    public mutating func beginFrame() { usedThisFrame = 0 }

    /// Tenta reservar `bytes`; `false` significa "adie para o próximo quadro".
    public mutating func reserve(_ bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        if usedThisFrame == 0 || usedThisFrame + bytes <= bytesPerFrame {
            usedThisFrame += bytes
            return true
        }
        return false
    }
}
