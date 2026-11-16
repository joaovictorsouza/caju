/// Handle numérico (índice + geração) para um recurso do `CajuAudio`.
///
/// A geração invalida handles antigos após a posição ser reutilizada: usar um recurso já
/// destruído falha com `CajuAudioError.invalidHandle` em vez de acessar memória liberada.
/// `Tag` é um tipo fantasma que impede misturar tipos de recurso (`CajuAudioClipHandle`
/// não converte para `CajuAudioSourceHandle`).
public struct CajuAudioHandle<Tag: Sendable>: Sendable, Hashable {
    /// Posição na tabela interna do recurso.
    public let index: UInt32
    /// Geração da posição no momento da criação; `0` é reservada ao handle nulo.
    public let generation: UInt32

    @inlinable public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }

    /// Handle que nunca refere um recurso válido (geração `0`).
    public static var null: Self { Self(index: 0, generation: 0) }

    /// `true` se o handle não é o nulo (não garante que o recurso ainda esteja vivo).
    @inlinable public var isNonNull: Bool { generation != 0 }
}

/// Marca fantasma para handles de clipes de áudio decodificados.
public enum CajuAudioClipTag: Sendable {}

/// Marca fantasma para handles de buses de mixagem.
public enum CajuAudioBusTag: Sendable {}

/// Marca fantasma para handles de fontes de áudio.
public enum CajuAudioSourceTag: Sendable {}

/// Handle para um clipe de áudio carregado na engine.
public typealias CajuAudioClipHandle = CajuAudioHandle<CajuAudioClipTag>

/// Handle para um bus (grupo) de mixagem na engine.
public typealias CajuAudioBusHandle = CajuAudioHandle<CajuAudioBusTag>

/// Handle para uma instância de fonte sonora 2D ou 3D.
public typealias CajuAudioSourceHandle = CajuAudioHandle<CajuAudioSourceTag>

/// Tabela geracional interna para alocação e validação de handles sem realocar após aquecida.
struct CajuAudioHandlePool<Tag: Sendable, Value> {
    private var values: [Value?] = []
    private var generations: [UInt32] = []
    private var freeList: [UInt32] = []

    private(set) var count: Int = 0

    init() {}

    mutating func insert(_ value: Value) throws(CajuAudioError) -> CajuAudioHandle<Tag> {
        if let index = freeList.popLast() {
            let slot = Int(index)
            values[slot] = value
            count += 1
            return CajuAudioHandle(index: index, generation: generations[slot])
        }
        guard values.count < Int(UInt32.max) else {
            throw .capacityExceeded
        }
        let index = UInt32(values.count)
        values.append(value)
        generations.append(1)
        count += 1
        return CajuAudioHandle(index: index, generation: 1)
    }

    func value(for handle: CajuAudioHandle<Tag>) -> Value? {
        let slot = Int(handle.index)
        guard handle.generation != 0, slot < values.count, generations[slot] == handle.generation else {
            return nil
        }
        return values[slot]
    }

    func require(_ handle: CajuAudioHandle<Tag>) throws(CajuAudioError) -> Value {
        guard let value = value(for: handle) else {
            throw .invalidHandle(index: handle.index, generation: handle.generation)
        }
        return value
    }

    @discardableResult
    mutating func update(_ handle: CajuAudioHandle<Tag>, _ transform: (inout Value) -> Void)
        throws(CajuAudioError) -> Value
    {
        let slot = Int(handle.index)
        guard handle.generation != 0, slot < values.count, generations[slot] == handle.generation,
            var value = values[slot]
        else {
            throw .invalidHandle(index: handle.index, generation: handle.generation)
        }
        transform(&value)
        values[slot] = value
        return value
    }

    @discardableResult
    mutating func remove(_ handle: CajuAudioHandle<Tag>) -> Value? {
        let slot = Int(handle.index)
        guard handle.generation != 0, slot < values.count, generations[slot] == handle.generation,
            let old = values[slot]
        else {
            return nil
        }
        values[slot] = nil
        // Geração 0 é reservada para o handle nulo.
        let next = generations[slot] &+ 1
        generations[slot] = next == 0 ? 1 : next
        freeList.append(handle.index)
        count -= 1
        return old
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: false)
        generations.removeAll(keepingCapacity: false)
        freeList.removeAll(keepingCapacity: false)
        count = 0
    }
}
