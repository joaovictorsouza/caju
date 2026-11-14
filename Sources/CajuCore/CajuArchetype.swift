/// Arquétipo: todas as entidades com o mesmo conjunto de componentes, em colunas SoA contíguas.
///
/// Detalhe de implementação exposto só para a especialização de `CajuWorld.forEach` entre módulos;
/// não faz parte da API estável.
///
/// Classe por ter identidade e ciclo de vida (libera memória no `deinit`).
public final class CajuArchetype {
    @usableFromInline let signature: UInt64
    @usableFromInline let ids: [CajuComponentID]
    /// Coluna por ID de componente (nil = ausente), tamanho fixo 64.
    @usableFromInline var columns: ContiguousArray<UnsafeMutableRawPointer?>
    @usableFromInline var strides: ContiguousArray<Int>
    @usableFromInline var alignments: ContiguousArray<Int>
    @usableFromInline var entities: ContiguousArray<CajuEntity> = []
    @usableFromInline var count = 0
    @usableFromInline var capacity = 0

    init(signature: UInt64, ids: [CajuComponentID], strides: [Int], alignments: [Int]) {
        self.signature = signature
        self.ids = ids
        self.columns = ContiguousArray(repeating: nil, count: CajuComponentID.maxCount)
        self.strides = ContiguousArray(repeating: 0, count: CajuComponentID.maxCount)
        self.alignments = ContiguousArray(repeating: 1, count: CajuComponentID.maxCount)
        for (i, id) in ids.enumerated() {
            self.strides[Int(id.rawValue)] = strides[i]
            self.alignments[Int(id.rawValue)] = alignments[i]
        }
    }

    deinit {
        for id in ids { columns[Int(id.rawValue)]?.deallocate() }
    }

    /// Garante espaço para mais uma linha (crescimento ×2; caminho frio).
    func reserveOneMore() {
        guard count == capacity else { return }
        let newCapacity = max(16, capacity * 2)
        for id in ids {
            let i = Int(id.rawValue)
            let stride = strides[i]
            let new = UnsafeMutableRawPointer.allocate(
                byteCount: max(1, newCapacity * stride), alignment: max(16, alignments[i]))
            if let old = columns[i] {
                new.copyMemory(from: old, byteCount: count * stride)
                old.deallocate()
            }
            columns[i] = new
        }
        entities.reserveCapacity(newCapacity)
        capacity = newCapacity
    }

    @inlinable func pointer<C: CajuComponent>(_ type: C.Type) -> UnsafeMutablePointer<C>? {
        columns[Int(C.componentID.rawValue)]?.assumingMemoryBound(to: C.self)
    }

    /// Acrescenta uma linha com a entidade; as colunas ficam por preencher pelo chamador.
    func appendRow(_ entity: CajuEntity) -> Int {
        reserveOneMore()
        entities.append(entity)
        count += 1
        return count - 1
    }

    /// Remove a linha por troca com a última. Devolve a entidade movida para `row`, se houve.
    func swapRemove(row: Int) -> CajuEntity? {
        let last = count - 1
        if row != last {
            for id in ids {
                let i = Int(id.rawValue)
                if let base = columns[i] {
                    let stride = strides[i]
                    (base + row * stride).copyMemory(from: base + last * stride, byteCount: stride)
                }
            }
            entities[row] = entities[last]
        }
        entities.removeLast()
        count -= 1
        return row != last ? entities[row] : nil
    }
}
