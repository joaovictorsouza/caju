/// Fila de mensagens tipada com buffer duplo e capacidade fixa (sem alocação após o `init`).
///
/// Mensagens enviadas no quadro N ficam legíveis após `swap()` (início do quadro N+1) e são
/// descartadas no `swap()` seguinte. Se o buffer encher, `send` devolve `false` e conta em
/// `droppedCount` (nunca falha nem aloca).
public final class CajuMessageQueue<M: BitwiseCopyable & Sendable> {
    private let capacity: Int
    private var write: UnsafeMutablePointer<M>
    private var read: UnsafeMutablePointer<M>
    private var writeCount = 0
    public private(set) var readCount = 0
    public private(set) var droppedCount = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        write = .allocate(capacity: self.capacity)
        read = .allocate(capacity: self.capacity)
    }

    deinit {
        write.deallocate()
        read.deallocate()
    }

    @discardableResult
    public func send(_ message: M) -> Bool {
        guard writeCount < capacity else {
            droppedCount += 1
            return false
        }
        (write + writeCount).initialize(to: message)
        writeCount += 1
        return true
    }

    /// Troca os buffers: o que foi enviado vira legível; o legível anterior é descartado.
    public func swap() {
        Swift.swap(&write, &read)
        readCount = writeCount
        writeCount = 0
    }

    public subscript(index: Int) -> M? {
        guard index >= 0, index < readCount else { return nil }
        return read[index]
    }

    public func forEachMessage(_ body: (M) -> Void) {
        for i in 0..<readCount { body(read[i]) }
    }
}
