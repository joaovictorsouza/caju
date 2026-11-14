/// Termo de consulta: um componente lido (`CajuRead`) ou escrito (`CajuWrite`).
///
/// A API usa *parameter packs* (ADR 0003): `world.forEach(CajuRead<A>.self, CajuWrite<B>.self) { a, b in … }`.
/// O acesso (`isWrite`) alimenta a validação do agendador (`CajuSystemContext`).
public protocol CajuQueryTerm {
    associatedtype Cursor
    associatedtype Item
    static var componentID: CajuComponentID { get }
    static var isWrite: Bool { get }
    static func cursor(_ archetype: CajuArchetype) -> Cursor
    static func item(_ cursor: Cursor, _ row: Int) -> Item
}

/// Referência mutável a um componente dentro de uma consulta; válida só durante o fechamento.
public struct CajuRef<C: CajuComponent> {
    @usableFromInline let pointer: UnsafeMutablePointer<C>
    @inlinable init(_ pointer: UnsafeMutablePointer<C>) { self.pointer = pointer }
    @inlinable public var value: C {
        get { pointer.pointee }
        nonmutating set { pointer.pointee = newValue }
    }
}

/// Lê o componente (cópia por valor).
public struct CajuRead<C: CajuComponent>: CajuQueryTerm {
    @inlinable public static var componentID: CajuComponentID { C.componentID }
    @inlinable public static var isWrite: Bool { false }
    @inlinable public static func cursor(_ a: CajuArchetype) -> UnsafeMutablePointer<C>? { a.pointer(C.self) }
    @inlinable public static func item(_ c: UnsafeMutablePointer<C>?, _ row: Int) -> C {
        c.unsafelyUnwrapped[row]
    }
}

/// Lê e escreve o componente (por `CajuRef.value`).
public struct CajuWrite<C: CajuComponent>: CajuQueryTerm {
    @inlinable public static var componentID: CajuComponentID { C.componentID }
    @inlinable public static var isWrite: Bool { true }
    @inlinable public static func cursor(_ a: CajuArchetype) -> UnsafeMutablePointer<C>? { a.pointer(C.self) }
    @inlinable public static func item(_ c: UnsafeMutablePointer<C>?, _ row: Int) -> CajuRef<C> {
        CajuRef(c.unsafelyUnwrapped + row)
    }
}

extension CajuWorld {
    /// Máscara de componentes exigidos pelos termos e acessos (leitura/escrita) deles.
    @inlinable
    public static func access<each Q: CajuQueryTerm>(of terms: repeat (each Q).Type)
        -> (reads: CajuComponentMask, writes: CajuComponentMask, valid: Bool)
    {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        repeat accumulate((each Q).self, &r, &w, &valid)
        return (CajuComponentMask(bits: r), CajuComponentMask(bits: w), valid)
    }

    @inlinable static func accumulate<T: CajuQueryTerm>(
        _ t: T.Type, _ r: inout UInt64, _ w: inout UInt64, _ valid: inout Bool
    ) {
        valid = valid && T.componentID.isValid
        if T.isWrite { w |= T.componentID.bit } else { r |= T.componentID.bit }
    }

    /// Versão com *parameter packs* (PoC do ADR 0003; aridade ilimitada). No SIL otimizado ela mantém
    /// `witness_method` por termo/linha, por isso o caminho quente usa os overloads `forEach` de
    /// aridade 1..8 (`CajuQueryArity.swift`, gerados). Use esta só para aridade > 8.
    @inlinable
    public func forEachPack<each Q: CajuQueryTerm>(
        _ terms: repeat (each Q).Type, filter: CajuQueryFilter = .none,
        _ body: (repeat (each Q).Item) -> Void
    ) {
        let acc = Self.access(of: repeat each terms)
        let required = acc.reads.bits | acc.writes.bits
        guard acc.valid else { return }
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let a = archetypes[ai]
            guard a.signature & required == required, a.signature & filter.withoutComponents.bits == 0,
                a.count > 0
            else { continue }
            run(a, filter, terms: repeat (each Q).self, cursors: repeat (each Q).cursor(a), body: body)
        }
    }

    @inlinable
    func run<each Q: CajuQueryTerm>(
        _ a: CajuArchetype, _ filter: CajuQueryFilter, terms: repeat (each Q).Type,
        cursors: repeat (each Q).Cursor, body: (repeat (each Q).Item) -> Void
    ) {
        let n = a.count
        if filter.usesTags {
            var row = 0
            while row < n {
                let tags = slots[Int(a.entities[row].index)].tags
                if tags & filter.withTags.bits == filter.withTags.bits, tags & filter.withoutTags.bits == 0 {
                    body(repeat (each Q).item(each cursors, row))
                }
                row += 1
            }
        } else {
            var row = 0
            while row < n {
                body(repeat (each Q).item(each cursors, row))
                row += 1
            }
        }
    }
}
