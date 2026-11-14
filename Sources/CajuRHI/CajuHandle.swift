/// Handle numérico (geração + índice) para um recurso do RHI.
///
/// O índice aponta uma posição na tabela do backend e a geração invalida handles antigos depois
/// que a posição é reutilizada: usar um recurso destruído falha com `CajuRHIError.invalidHandle`
/// em vez de corromper memória. `Tag` é um tipo fantasma que impede misturar tipos de recurso
/// (`CajuBufferHandle` não converte para `CajuTextureHandle`).
public struct CajuHandle<Tag>: Sendable, Hashable {
    /// Posição na tabela de recursos.
    public let index: UInt32
    /// Geração da posição quando o recurso foi criado; `0` nunca é válida.
    public let generation: UInt32

    @inlinable public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }

    /// Handle que nunca refere um recurso (geração 0).
    public static var null: Self { Self(index: 0, generation: 0) }

    /// `true` se o handle não é o nulo (não garante que o recurso ainda exista).
    @inlinable public var isNonNull: Bool { generation != 0 }
}

public enum CajuBufferTag: Sendable {}
public enum CajuTextureTag: Sendable {}
public enum CajuSamplerTag: Sendable {}
public enum CajuShaderTag: Sendable {}
public enum CajuRenderPipelineTag: Sendable {}
public enum CajuComputePipelineTag: Sendable {}

public typealias CajuBufferHandle = CajuHandle<CajuBufferTag>
public typealias CajuTextureHandle = CajuHandle<CajuTextureTag>
public typealias CajuSamplerHandle = CajuHandle<CajuSamplerTag>
public typealias CajuShaderHandle = CajuHandle<CajuShaderTag>
public typealias CajuRenderPipelineHandle = CajuHandle<CajuRenderPipelineTag>
public typealias CajuComputePipelineHandle = CajuHandle<CajuComputePipelineTag>

/// Tabela geracional de recursos: aloca índices, reutiliza posições livres e valida handles.
///
/// Alocar e liberar não aloca memória quando há posição livre; o armazenamento cresce só na
/// criação de recursos (fora do caminho quente). `Value` é o registro do backend.
public struct CajuHandlePool<Tag, Value> {
    private var values: [Value?] = []
    private var generations: [UInt32] = []
    private var freeList: [UInt32] = []

    public init() {}

    /// Quantidade de recursos vivos.
    public private(set) var count: Int = 0

    /// Registra um valor e devolve o handle.
    public mutating func insert(_ value: Value) -> CajuHandle<Tag> {
        count += 1
        if let index = freeList.popLast() {
            let slot = Int(index)
            values[slot] = value
            return CajuHandle(index: index, generation: generations[slot])
        }
        values.append(value)
        generations.append(1)
        return CajuHandle(index: UInt32(values.count - 1), generation: 1)
    }

    /// Valor associado ao handle, ou `nil` se o handle é nulo, antigo ou fora da tabela.
    public func value(for handle: CajuHandle<Tag>) -> Value? {
        let slot = Int(handle.index)
        guard handle.generation != 0, slot < values.count, generations[slot] == handle.generation else {
            return nil
        }
        return values[slot]
    }

    /// Remove o recurso e invalida os handles antigos; devolve o valor removido.
    @discardableResult
    public mutating func remove(_ handle: CajuHandle<Tag>) -> Value? {
        let slot = Int(handle.index)
        guard handle.generation != 0, slot < values.count, generations[slot] == handle.generation,
            let old = values[slot]
        else { return nil }
        values[slot] = nil
        // Pula a geração 0 ao dar a volta (reservada ao handle nulo).
        let next = generations[slot] &+ 1
        generations[slot] = next == 0 ? 1 : next
        freeList.append(handle.index)
        count -= 1
        return old
    }

    /// Substitui o valor de um handle vivo.
    public mutating func update(_ handle: CajuHandle<Tag>, _ value: Value) -> Bool {
        let slot = Int(handle.index)
        guard handle.generation != 0, slot < values.count, generations[slot] == handle.generation,
            values[slot] != nil
        else { return false }
        values[slot] = value
        return true
    }

    /// Erro padrão para handle inválido.
    public static func invalid(_ handle: CajuHandle<Tag>) -> CajuRHIError {
        .invalidHandle(index: handle.index, generation: handle.generation)
    }
}
