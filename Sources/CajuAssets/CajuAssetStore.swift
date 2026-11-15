/// Tabela de *slots* de um tipo de asset: geração, estado, posse e valor. **Núcleo estável do contrato**:
/// a regra de geração, as transições de estado e a posse são o que o `AssetServer` e os testes assumem.
///
/// Valor de uso na *thread* do jogo (sem sincronização); o servidor guarda uma tabela por tipo. As mutações
/// devolvem `false` quando o handle é velho ou a transição é ilegal, sem efeito.
public struct CajuAssetStore<A: CajuAsset>: Sendable {
    public typealias Handle = CajuAssetHandle<A>

    private struct Slot: Sendable {
        var generation: UInt32 = 1
        var state: CajuAssetState = .stale
        var refCount: UInt32 = 0
        var revision: UInt32 = 0
        var value: A?
        var error: CajuAssetError?
        var path: CajuAssetPath?
    }

    private var slots: [Slot] = []
    private var freeList: [UInt32] = []

    public init() {}

    /// Quantidade de slots vivos (não `stale`).
    public private(set) var liveCount = 0

    // MARK: Consultas (sem alocação)

    public func state(of handle: Handle) -> CajuAssetState {
        guard let i = valid(handle) else { return .stale }
        return slots[i].state
    }

    public func value(of handle: Handle) -> A? {
        guard let i = valid(handle), slots[i].state.hasValue else { return nil }
        return slots[i].value
    }

    public func error(of handle: Handle) -> CajuAssetError? {
        guard let i = valid(handle) else { return nil }
        return slots[i].error
    }

    public func revision(of handle: Handle) -> UInt32 {
        guard let i = valid(handle) else { return 0 }
        return slots[i].revision
    }

    public func path(of handle: Handle) -> CajuAssetPath? {
        guard let i = valid(handle) else { return nil }
        return slots[i].path
    }

    // MARK: Ciclo de vida

    /// Reserva um slot em `.queued` com uma posse.
    public mutating func reserve(path: CajuAssetPath? = nil) -> Handle {
        let index: Int
        if let free = freeList.popLast() {
            index = Int(free)
        } else {
            index = slots.count
            slots.append(Slot())
        }
        slots[index].state = .queued
        slots[index].refCount = 1
        slots[index].path = path
        liveCount += 1
        return Handle(index: UInt32(truncatingIfNeeded: index), generation: slots[index].generation)
    }

    /// `queued → loading`.
    @discardableResult public mutating func beginLoading(_ handle: Handle) -> Bool {
        guard let i = valid(handle), slots[i].state == .queued else { return false }
        slots[i].state = .loading
        return true
    }

    /// `loaded | failed → reloading` (com valor) ou `loading` (sem valor, após falha).
    @discardableResult public mutating func beginReload(_ handle: Handle) -> Bool {
        guard let i = valid(handle) else { return false }
        switch slots[i].state {
        case .loaded: slots[i].state = .reloading
        case .failed: slots[i].state = .loading
        default: return false
        }
        return true
    }

    /// `loading | reloading → loaded`; publica o valor, sobe `revision` e limpa o erro.
    @discardableResult public mutating func complete(_ handle: Handle, value: A) -> Bool {
        guard let i = valid(handle), slots[i].state == .loading || slots[i].state == .reloading else {
            return false
        }
        slots[i].value = value
        slots[i].error = nil
        slots[i].revision &+= 1
        slots[i].state = .loaded
        return true
    }

    /// Falha de carga: `loading → failed`. Falha de recarga: `reloading → loaded` mantendo o valor antigo
    /// (o erro fica em `error(of:)`).
    @discardableResult public mutating func fail(_ handle: Handle, error: CajuAssetError) -> Bool {
        guard let i = valid(handle) else { return false }
        switch slots[i].state {
        case .loading: slots[i].state = .failed
        case .reloading: slots[i].state = .loaded
        default: return false
        }
        slots[i].error = error
        return true
    }

    @discardableResult public mutating func retain(_ handle: Handle) -> Bool {
        guard let i = valid(handle) else { return false }
        slots[i].refCount &+= 1
        return true
    }

    /// Tira uma posse; ao zerar, libera o slot (valor cai, geração sobe, handle vira `.stale`).
    /// `false` se o handle já era velho.
    @discardableResult public mutating func release(_ handle: Handle) -> Bool {
        guard let i = valid(handle) else { return false }
        slots[i].refCount -= 1
        if slots[i].refCount == 0 {
            slots[i].value = nil
            slots[i].error = nil
            slots[i].path = nil
            slots[i].revision = 0
            slots[i].state = .stale
            // A geração nunca volta a 0 (0 é o `invalid`): ao dar a volta, recomeça em 1.
            slots[i].generation = slots[i].generation == .max ? 1 : slots[i].generation + 1
            freeList.append(handle.index)
            liveCount -= 1
        }
        return true
    }

    // MARK: Privado

    private func valid(_ handle: Handle) -> Int? {
        let i = Int(handle.index)
        guard i < slots.count, slots[i].generation == handle.generation, slots[i].state != .stale else {
            return nil
        }
        return i
    }
}
