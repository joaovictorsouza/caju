/// Comando estrutural adiado, aplicado no ponto de sincronização entre estágios.
public enum CajuCommand: Sendable, Equatable {
    case despawn(CajuEntity)
    case addTag(CajuEntity, CajuTagID)
    case removeTag(CajuEntity, CajuTagID)
}

/// Buffer de comandos com capacidade fixa (sem alocação após o `init`).
public final class CajuCommandBuffer {
    private var commands: ContiguousArray<CajuCommand>
    private let capacity: Int
    public private(set) var droppedCount = 0

    public init(capacity: Int = 1024) {
        self.capacity = max(1, capacity)
        commands = []
        commands.reserveCapacity(self.capacity)
    }

    public var count: Int { commands.count }

    /// Enfileira; `false` (e `droppedCount`) se cheio.
    @discardableResult
    public func push(_ command: CajuCommand) -> Bool {
        guard commands.count < capacity else {
            droppedCount += 1
            return false
        }
        commands.append(command)
        return true
    }

    /// Aplica e esvazia. Comandos de entidades já inválidas são ignorados.
    public func apply(to world: CajuWorld) {
        for c in commands {
            switch c {
            case .despawn(let e): try? world.despawn(e)
            case .addTag(let e, let id): _ = world.setTag(id, e, true)
            case .removeTag(let e, let id): _ = world.setTag(id, e, false)
            }
        }
        commands.removeAll(keepingCapacity: true)
    }
}
