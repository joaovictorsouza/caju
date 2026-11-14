/// Filtro extra de consulta: componentes excluídos e *tags* exigidas/excluídas.
public struct CajuQueryFilter: Sendable, Equatable {
    public var withoutComponents: CajuComponentMask
    public var withTags: CajuComponentMask
    public var withoutTags: CajuComponentMask

    public init(
        withoutComponents: CajuComponentMask = .none,
        withTags: CajuComponentMask = .none,
        withoutTags: CajuComponentMask = .none
    ) {
        self.withoutComponents = withoutComponents
        self.withTags = withTags
        self.withoutTags = withoutTags
    }

    public static let none = CajuQueryFilter()
    @inlinable var usesTags: Bool { withTags.bits != 0 || withoutTags.bits != 0 }
}

/// Mundo ECS híbrido: arquétipos SoA para componentes + bitset por entidade para *tags*.
///
/// Acessado só pelo laço principal (ADR 0003, `docs/standards/codigo-swift.md` regra 5). Classe por
/// identidade/ciclo de vida. Nenhuma API aloca no caminho quente (consultas, `get`/`set`, tags);
/// `spawn`/`despawn` só alocam ao crescer arquétipo ou tabela de entidades (use `reserve`).
public final class CajuWorld {
    @usableFromInline struct Slot {
        @usableFromInline var generation: UInt32 = 0
        @usableFromInline var archetype: UInt32 = .max  // .max = livre
        @usableFromInline var row: UInt32 = 0
        @usableFromInline var tags: UInt64 = 0
    }

    @usableFromInline var slots: ContiguousArray<Slot> = []
    @usableFromInline var freeList: ContiguousArray<UInt32> = []
    @usableFromInline var archetypes: ContiguousArray<CajuArchetype> = []
    var archetypeBySignature: [UInt64: Int] = [:]
    var registry: ContiguousArray<(type: ObjectIdentifier, stride: Int, alignment: Int)?> =
        ContiguousArray(repeating: nil, count: CajuComponentID.maxCount)
    @usableFromInline var iterating = 0
    public private(set) var entityCount = 0

    public init() {}

    /// Pré-aloca a tabela de entidades para `entities` (evita alocar em `spawn`).
    public func reserve(entities: Int) {
        slots.reserveCapacity(entities)
        freeList.reserveCapacity(entities)
    }

    public func contains(_ entity: CajuEntity) -> Bool { location(of: entity) != nil }

    @inlinable func location(of entity: CajuEntity) -> (archetype: Int, row: Int)? {
        let i = Int(entity.index)
        guard i < slots.count else { return nil }
        let s = slots[i]
        guard s.generation == entity.generation, s.archetype != .max else { return nil }
        return (Int(s.archetype), Int(s.row))
    }

    // MARK: Registro

    @discardableResult @usableFromInline
    func register<C: CajuComponent>(_ type: C.Type) -> Result<Void, CajuWorldError> {
        let id = C.componentID
        guard id.isValid else { return .failure(.invalidComponentID(id)) }
        let oid = ObjectIdentifier(type)
        if let r = registry[Int(id.rawValue)] {
            return r.type == oid ? .success(()) : .failure(.componentIDConflict(id))
        }
        registry[Int(id.rawValue)] = (oid, MemoryLayout<C>.stride, MemoryLayout<C>.alignment)
        return .success(())
    }

    func archetype(for signature: UInt64) -> Int {
        if let i = archetypeBySignature[signature] { return i }
        var ids: [CajuComponentID] = []
        var strides: [Int] = []
        var aligns: [Int] = []
        for raw in 0..<UInt8(CajuComponentID.maxCount) where signature & (1 << UInt64(raw)) != 0 {
            guard let r = registry[Int(raw)] else { continue }
            ids.append(CajuComponentID(raw))
            strides.append(r.stride)
            aligns.append(r.alignment)
        }
        archetypes.append(
            CajuArchetype(signature: signature, ids: ids, strides: strides, alignments: aligns))
        archetypeBySignature[signature] = archetypes.count - 1
        return archetypes.count - 1
    }

    func allocateSlot() throws(CajuWorldError) -> UInt32 {
        if let i = freeList.popLast() { return i }
        guard slots.count < Int(UInt32.max) - 1 else { throw .capacityExceeded }
        slots.append(Slot())
        return UInt32(slots.count - 1)
    }

    // MARK: Spawn / despawn

    /// Cria uma entidade com os componentes dados (tipos distintos, ≤ 64 IDs).
    @inlinable
    public func spawn<each C: CajuComponent>(_ components: repeat each C) throws(CajuWorldError)
        -> CajuEntity
    {
        var signature: UInt64 = 0
        var failure: CajuWorldError?
        repeat registerAndMark(each components, &signature, &failure)
        if let failure { throw failure }
        let entity = try spawnEmpty(signature: signature)
        guard let loc = location(of: entity) else { throw .staleEntity(entity) }
        let a = archetypes[loc.archetype]
        repeat a.write(each components, row: loc.row)
        return entity
    }

    @inlinable func registerAndMark<T: CajuComponent>(
        _ value: T, _ signature: inout UInt64, _ failure: inout CajuWorldError?
    ) {
        if case .failure(let e) = register(T.self) {
            failure = failure ?? e
            return
        }
        if signature & T.componentID.bit != 0 { failure = failure ?? .duplicateComponent(T.componentID) }
        signature |= T.componentID.bit
    }

    @usableFromInline
    func spawnEmpty(signature: UInt64) throws(CajuWorldError) -> CajuEntity {
        guard iterating == 0 else { throw .structuralChangeDuringIteration }
        let ai = archetype(for: signature)
        let index = try allocateSlot()
        let entity = CajuEntity(index: index, generation: slots[Int(index)].generation)
        let row = archetypes[ai].appendRow(entity)
        slots[Int(index)].archetype = UInt32(ai)
        slots[Int(index)].row = UInt32(row)
        slots[Int(index)].tags = 0
        entityCount += 1
        return entity
    }

    /// Remove a entidade (invalida o `CajuEntity` por geração).
    public func despawn(_ entity: CajuEntity) throws(CajuWorldError) {
        guard iterating == 0 else { throw .structuralChangeDuringIteration }
        guard let loc = location(of: entity) else { throw .staleEntity(entity) }
        removeRow(archetype: loc.archetype, row: loc.row)
        let i = Int(entity.index)
        slots[i].archetype = .max
        slots[i].tags = 0
        slots[i].generation &+= 1
        freeList.append(entity.index)
        entityCount -= 1
    }

    private func removeRow(archetype ai: Int, row: Int) {
        if let moved = archetypes[ai].swapRemove(row: row) {
            slots[Int(moved.index)].row = UInt32(row)
        }
    }

    /// Percorre as entidades que têm o componente, entregando entidade e valor (sem alocação).
    @inlinable
    public func forEachEntity<C: CajuComponent>(having type: C.Type, _ body: (CajuEntity, C) -> Void) {
        guard C.componentID.isValid else { return }
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & C.componentID.bit != 0, let p = arch.pointer(type) else { continue }
            for row in 0..<arch.count { body(arch.entities[row], p[row]) }
        }
    }

    // MARK: Acesso por entidade

    public func has<C: CajuComponent>(_ type: C.Type, _ entity: CajuEntity) -> Bool {
        guard let loc = location(of: entity) else { return false }
        return archetypes[loc.archetype].signature & C.componentID.bit != 0
    }

    @inlinable public func get<C: CajuComponent>(_ type: C.Type, of entity: CajuEntity) -> C? {
        guard let loc = location(of: entity), let p = archetypes[loc.archetype].pointer(type)
        else { return nil }
        return p[loc.row]
    }

    /// Escreve o componente se a entidade o tem; devolve `false` caso contrário.
    @inlinable @discardableResult
    public func set<C: CajuComponent>(_ value: C, on entity: CajuEntity) -> Bool {
        guard let loc = location(of: entity), let p = archetypes[loc.archetype].pointer(C.self)
        else { return false }
        p[loc.row] = value
        return true
    }

    // MARK: Insert / remove (move entre arquétipos; caminho frio)

    public func insert<C: CajuComponent>(_ value: C, into entity: CajuEntity) throws(CajuWorldError) {
        guard iterating == 0 else { throw .structuralChangeDuringIteration }
        guard let loc = location(of: entity) else { throw .staleEntity(entity) }
        if case .failure(let e) = register(C.self) { throw e }
        let old = archetypes[loc.archetype]
        if old.signature & C.componentID.bit != 0 {
            old.pointer(C.self)?[loc.row] = value
            return
        }
        let new = move(entity, from: loc, toSignature: old.signature | C.componentID.bit)
        archetypes[new.archetype].write(value, row: new.row)
    }

    public func remove<C: CajuComponent>(_ type: C.Type, from entity: CajuEntity) throws(CajuWorldError) {
        guard iterating == 0 else { throw .structuralChangeDuringIteration }
        guard let loc = location(of: entity) else { throw .staleEntity(entity) }
        let old = archetypes[loc.archetype]
        guard old.signature & C.componentID.bit != 0 else { throw .missingComponent(C.componentID) }
        _ = move(entity, from: loc, toSignature: old.signature & ~C.componentID.bit)
    }

    private func move(
        _ entity: CajuEntity, from loc: (archetype: Int, row: Int), toSignature: UInt64
    ) -> (archetype: Int, row: Int) {
        let ni = archetype(for: toSignature)
        let old = archetypes[loc.archetype]
        let new = archetypes[ni]
        let newRow = new.appendRow(entity)
        for id in new.ids {
            let i = Int(id.rawValue)
            if let src = old.columns[i], let dst = new.columns[i] {
                let stride = new.strides[i]
                (dst + newRow * stride).copyMemory(from: src + loc.row * stride, byteCount: stride)
            }
        }
        removeRow(archetype: loc.archetype, row: loc.row)
        slots[Int(entity.index)].archetype = UInt32(ni)
        slots[Int(entity.index)].row = UInt32(newRow)
        return (ni, newRow)
    }

    // MARK: Tags (bitset por entidade; não move de arquétipo)

    @discardableResult
    public func addTag<T: CajuTag>(_ type: T.Type, to entity: CajuEntity) -> Bool {
        setTag(type.tagID, entity, true)
    }

    @discardableResult
    public func removeTag<T: CajuTag>(_ type: T.Type, from entity: CajuEntity) -> Bool {
        setTag(type.tagID, entity, false)
    }

    public func hasTag<T: CajuTag>(_ type: T.Type, _ entity: CajuEntity) -> Bool {
        let i = Int(entity.index)
        guard location(of: entity) != nil else { return false }
        return slots[i].tags & type.tagID.bit != 0
    }

    func setTag(_ id: CajuTagID, _ entity: CajuEntity, _ on: Bool) -> Bool {
        guard id.isValid, location(of: entity) != nil else { return false }
        if on {
            slots[Int(entity.index)].tags |= id.bit
        } else {
            slots[Int(entity.index)].tags &= ~id.bit
        }
        return true
    }
}

extension CajuArchetype {
    @inlinable func write<T: CajuComponent>(_ value: T, row: Int) {
        pointer(T.self)?[row] = value
    }
}
