// GERADO por docs/tools/gen-query-overloads.py. NÃO EDITE à mão.

extension CajuWorld {
    @inlinable
    public func forEach<A: CajuQueryTerm>(
        _ a: A.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item) -> Void
    ) {
        guard A.componentID.isValid else { return }
        let required = A.componentID.bit
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & required == required, arch.signature & filter.withoutComponents.bits == 0,
                arch.count > 0
            else { continue }
            let ca = A.cursor(arch)
            let n = arch.count
            var row = 0
            if filter.usesTags {
                while row < n {
                    let tags = slots[Int(arch.entities[row].index)].tags
                    if tags & filter.withTags.bits == filter.withTags.bits,
                        tags & filter.withoutTags.bits == 0
                    {
                        body(A.item(ca, row))
                    }
                    row += 1
                }
            } else {
                while row < n {
                    body(A.item(ca, row))
                    row += 1
                }
            }
        }
    }

    @inlinable
    public func forEach<A: CajuQueryTerm, B: CajuQueryTerm>(
        _ a: A.Type, _ b: B.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item) -> Void
    ) {
        guard A.componentID.isValid && B.componentID.isValid else { return }
        let required = A.componentID.bit | B.componentID.bit
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & required == required, arch.signature & filter.withoutComponents.bits == 0,
                arch.count > 0
            else { continue }
            let ca = A.cursor(arch)
            let cb = B.cursor(arch)
            let n = arch.count
            var row = 0
            if filter.usesTags {
                while row < n {
                    let tags = slots[Int(arch.entities[row].index)].tags
                    if tags & filter.withTags.bits == filter.withTags.bits,
                        tags & filter.withoutTags.bits == 0
                    {
                        body(A.item(ca, row), B.item(cb, row))
                    }
                    row += 1
                }
            } else {
                while row < n {
                    body(A.item(ca, row), B.item(cb, row))
                    row += 1
                }
            }
        }
    }

    @inlinable
    public func forEach<A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm>(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item) -> Void
    ) {
        guard A.componentID.isValid && B.componentID.isValid && C.componentID.isValid else { return }
        let required = A.componentID.bit | B.componentID.bit | C.componentID.bit
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & required == required, arch.signature & filter.withoutComponents.bits == 0,
                arch.count > 0
            else { continue }
            let ca = A.cursor(arch)
            let cb = B.cursor(arch)
            let cc = C.cursor(arch)
            let n = arch.count
            var row = 0
            if filter.usesTags {
                while row < n {
                    let tags = slots[Int(arch.entities[row].index)].tags
                    if tags & filter.withTags.bits == filter.withTags.bits,
                        tags & filter.withoutTags.bits == 0
                    {
                        body(A.item(ca, row), B.item(cb, row), C.item(cc, row))
                    }
                    row += 1
                }
            } else {
                while row < n {
                    body(A.item(ca, row), B.item(cb, row), C.item(cc, row))
                    row += 1
                }
            }
        }
    }

    @inlinable
    public func forEach<A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm>(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item) -> Void
    ) {
        guard A.componentID.isValid && B.componentID.isValid && C.componentID.isValid && D.componentID.isValid
        else { return }
        let required = A.componentID.bit | B.componentID.bit | C.componentID.bit | D.componentID.bit
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & required == required, arch.signature & filter.withoutComponents.bits == 0,
                arch.count > 0
            else { continue }
            let ca = A.cursor(arch)
            let cb = B.cursor(arch)
            let cc = C.cursor(arch)
            let cd = D.cursor(arch)
            let n = arch.count
            var row = 0
            if filter.usesTags {
                while row < n {
                    let tags = slots[Int(arch.entities[row].index)].tags
                    if tags & filter.withTags.bits == filter.withTags.bits,
                        tags & filter.withoutTags.bits == 0
                    {
                        body(A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row))
                    }
                    row += 1
                }
            } else {
                while row < n {
                    body(A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row))
                    row += 1
                }
            }
        }
    }

    @inlinable
    public func forEach<
        A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm, E: CajuQueryTerm
    >(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item, E.Item) -> Void
    ) {
        guard
            A.componentID.isValid && B.componentID.isValid && C.componentID.isValid && D.componentID.isValid
                && E.componentID.isValid
        else { return }
        let required =
            A.componentID.bit | B.componentID.bit | C.componentID.bit | D.componentID.bit | E.componentID.bit
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & required == required, arch.signature & filter.withoutComponents.bits == 0,
                arch.count > 0
            else { continue }
            let ca = A.cursor(arch)
            let cb = B.cursor(arch)
            let cc = C.cursor(arch)
            let cd = D.cursor(arch)
            let ce = E.cursor(arch)
            let n = arch.count
            var row = 0
            if filter.usesTags {
                while row < n {
                    let tags = slots[Int(arch.entities[row].index)].tags
                    if tags & filter.withTags.bits == filter.withTags.bits,
                        tags & filter.withoutTags.bits == 0
                    {
                        body(
                            A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row),
                            E.item(ce, row))
                    }
                    row += 1
                }
            } else {
                while row < n {
                    body(A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row), E.item(ce, row))
                    row += 1
                }
            }
        }
    }

    @inlinable
    public func forEach<
        A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm, E: CajuQueryTerm,
        F: CajuQueryTerm
    >(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, _ f: F.Type,
        filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item, E.Item, F.Item) -> Void
    ) {
        guard
            A.componentID.isValid && B.componentID.isValid && C.componentID.isValid && D.componentID.isValid
                && E.componentID.isValid && F.componentID.isValid
        else { return }
        let required =
            A.componentID.bit | B.componentID.bit | C.componentID.bit | D.componentID.bit | E.componentID.bit
            | F.componentID.bit
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & required == required, arch.signature & filter.withoutComponents.bits == 0,
                arch.count > 0
            else { continue }
            let ca = A.cursor(arch)
            let cb = B.cursor(arch)
            let cc = C.cursor(arch)
            let cd = D.cursor(arch)
            let ce = E.cursor(arch)
            let cf = F.cursor(arch)
            let n = arch.count
            var row = 0
            if filter.usesTags {
                while row < n {
                    let tags = slots[Int(arch.entities[row].index)].tags
                    if tags & filter.withTags.bits == filter.withTags.bits,
                        tags & filter.withoutTags.bits == 0
                    {
                        body(
                            A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row),
                            E.item(ce, row), F.item(cf, row))
                    }
                    row += 1
                }
            } else {
                while row < n {
                    body(
                        A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row), E.item(ce, row),
                        F.item(cf, row))
                    row += 1
                }
            }
        }
    }

    @inlinable
    public func forEach<
        A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm, E: CajuQueryTerm,
        F: CajuQueryTerm, G: CajuQueryTerm
    >(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, _ f: F.Type, _ g: G.Type,
        filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item, E.Item, F.Item, G.Item) -> Void
    ) {
        guard
            A.componentID.isValid && B.componentID.isValid && C.componentID.isValid && D.componentID.isValid
                && E.componentID.isValid && F.componentID.isValid && G.componentID.isValid
        else { return }
        let required =
            A.componentID.bit | B.componentID.bit | C.componentID.bit | D.componentID.bit | E.componentID.bit
            | F.componentID.bit | G.componentID.bit
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & required == required, arch.signature & filter.withoutComponents.bits == 0,
                arch.count > 0
            else { continue }
            let ca = A.cursor(arch)
            let cb = B.cursor(arch)
            let cc = C.cursor(arch)
            let cd = D.cursor(arch)
            let ce = E.cursor(arch)
            let cf = F.cursor(arch)
            let cg = G.cursor(arch)
            let n = arch.count
            var row = 0
            if filter.usesTags {
                while row < n {
                    let tags = slots[Int(arch.entities[row].index)].tags
                    if tags & filter.withTags.bits == filter.withTags.bits,
                        tags & filter.withoutTags.bits == 0
                    {
                        body(
                            A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row),
                            E.item(ce, row), F.item(cf, row), G.item(cg, row))
                    }
                    row += 1
                }
            } else {
                while row < n {
                    body(
                        A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row), E.item(ce, row),
                        F.item(cf, row), G.item(cg, row))
                    row += 1
                }
            }
        }
    }

    @inlinable
    public func forEach<
        A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm, E: CajuQueryTerm,
        F: CajuQueryTerm, G: CajuQueryTerm, H: CajuQueryTerm
    >(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, _ f: F.Type, _ g: G.Type,
        _ h: H.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item, E.Item, F.Item, G.Item, H.Item) -> Void
    ) {
        guard
            A.componentID.isValid && B.componentID.isValid && C.componentID.isValid && D.componentID.isValid
                && E.componentID.isValid && F.componentID.isValid && G.componentID.isValid
                && H.componentID.isValid
        else { return }
        let required =
            A.componentID.bit | B.componentID.bit | C.componentID.bit | D.componentID.bit | E.componentID.bit
            | F.componentID.bit | G.componentID.bit | H.componentID.bit
        iterating += 1
        defer { iterating -= 1 }
        for ai in 0..<archetypes.count {
            let arch = archetypes[ai]
            guard arch.signature & required == required, arch.signature & filter.withoutComponents.bits == 0,
                arch.count > 0
            else { continue }
            let ca = A.cursor(arch)
            let cb = B.cursor(arch)
            let cc = C.cursor(arch)
            let cd = D.cursor(arch)
            let ce = E.cursor(arch)
            let cf = F.cursor(arch)
            let cg = G.cursor(arch)
            let ch = H.cursor(arch)
            let n = arch.count
            var row = 0
            if filter.usesTags {
                while row < n {
                    let tags = slots[Int(arch.entities[row].index)].tags
                    if tags & filter.withTags.bits == filter.withTags.bits,
                        tags & filter.withoutTags.bits == 0
                    {
                        body(
                            A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row),
                            E.item(ce, row), F.item(cf, row), G.item(cg, row), H.item(ch, row))
                    }
                    row += 1
                }
            } else {
                while row < n {
                    body(
                        A.item(ca, row), B.item(cb, row), C.item(cc, row), D.item(cd, row), E.item(ce, row),
                        F.item(cf, row), G.item(cg, row), H.item(ch, row))
                    row += 1
                }
            }
        }
    }

}

extension CajuSystemContext {
    @inlinable
    public func forEach<A: CajuQueryTerm>(
        _ a: A.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item) -> Void
    ) throws(CajuAccessError) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        CajuWorld.accumulate(A.self, &r, &w, &valid)
        try check(reads: CajuComponentMask(bits: r), writes: CajuComponentMask(bits: w))
        world.forEach(a, filter: filter, body)
    }

    @inlinable
    public func forEach<A: CajuQueryTerm, B: CajuQueryTerm>(
        _ a: A.Type, _ b: B.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item) -> Void
    ) throws(CajuAccessError) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        CajuWorld.accumulate(A.self, &r, &w, &valid)
        CajuWorld.accumulate(B.self, &r, &w, &valid)
        try check(reads: CajuComponentMask(bits: r), writes: CajuComponentMask(bits: w))
        world.forEach(a, b, filter: filter, body)
    }

    @inlinable
    public func forEach<A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm>(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item) -> Void
    ) throws(CajuAccessError) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        CajuWorld.accumulate(A.self, &r, &w, &valid)
        CajuWorld.accumulate(B.self, &r, &w, &valid)
        CajuWorld.accumulate(C.self, &r, &w, &valid)
        try check(reads: CajuComponentMask(bits: r), writes: CajuComponentMask(bits: w))
        world.forEach(a, b, c, filter: filter, body)
    }

    @inlinable
    public func forEach<A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm>(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item) -> Void
    ) throws(CajuAccessError) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        CajuWorld.accumulate(A.self, &r, &w, &valid)
        CajuWorld.accumulate(B.self, &r, &w, &valid)
        CajuWorld.accumulate(C.self, &r, &w, &valid)
        CajuWorld.accumulate(D.self, &r, &w, &valid)
        try check(reads: CajuComponentMask(bits: r), writes: CajuComponentMask(bits: w))
        world.forEach(a, b, c, d, filter: filter, body)
    }

    @inlinable
    public func forEach<
        A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm, E: CajuQueryTerm
    >(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item, E.Item) -> Void
    ) throws(CajuAccessError) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        CajuWorld.accumulate(A.self, &r, &w, &valid)
        CajuWorld.accumulate(B.self, &r, &w, &valid)
        CajuWorld.accumulate(C.self, &r, &w, &valid)
        CajuWorld.accumulate(D.self, &r, &w, &valid)
        CajuWorld.accumulate(E.self, &r, &w, &valid)
        try check(reads: CajuComponentMask(bits: r), writes: CajuComponentMask(bits: w))
        world.forEach(a, b, c, d, e, filter: filter, body)
    }

    @inlinable
    public func forEach<
        A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm, E: CajuQueryTerm,
        F: CajuQueryTerm
    >(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, _ f: F.Type,
        filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item, E.Item, F.Item) -> Void
    ) throws(CajuAccessError) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        CajuWorld.accumulate(A.self, &r, &w, &valid)
        CajuWorld.accumulate(B.self, &r, &w, &valid)
        CajuWorld.accumulate(C.self, &r, &w, &valid)
        CajuWorld.accumulate(D.self, &r, &w, &valid)
        CajuWorld.accumulate(E.self, &r, &w, &valid)
        CajuWorld.accumulate(F.self, &r, &w, &valid)
        try check(reads: CajuComponentMask(bits: r), writes: CajuComponentMask(bits: w))
        world.forEach(a, b, c, d, e, f, filter: filter, body)
    }

    @inlinable
    public func forEach<
        A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm, E: CajuQueryTerm,
        F: CajuQueryTerm, G: CajuQueryTerm
    >(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, _ f: F.Type, _ g: G.Type,
        filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item, E.Item, F.Item, G.Item) -> Void
    ) throws(CajuAccessError) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        CajuWorld.accumulate(A.self, &r, &w, &valid)
        CajuWorld.accumulate(B.self, &r, &w, &valid)
        CajuWorld.accumulate(C.self, &r, &w, &valid)
        CajuWorld.accumulate(D.self, &r, &w, &valid)
        CajuWorld.accumulate(E.self, &r, &w, &valid)
        CajuWorld.accumulate(F.self, &r, &w, &valid)
        CajuWorld.accumulate(G.self, &r, &w, &valid)
        try check(reads: CajuComponentMask(bits: r), writes: CajuComponentMask(bits: w))
        world.forEach(a, b, c, d, e, f, g, filter: filter, body)
    }

    @inlinable
    public func forEach<
        A: CajuQueryTerm, B: CajuQueryTerm, C: CajuQueryTerm, D: CajuQueryTerm, E: CajuQueryTerm,
        F: CajuQueryTerm, G: CajuQueryTerm, H: CajuQueryTerm
    >(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, _ f: F.Type, _ g: G.Type,
        _ h: H.Type, filter: CajuQueryFilter = .none,
        _ body: (A.Item, B.Item, C.Item, D.Item, E.Item, F.Item, G.Item, H.Item) -> Void
    ) throws(CajuAccessError) {
        var r: UInt64 = 0
        var w: UInt64 = 0
        var valid = true
        CajuWorld.accumulate(A.self, &r, &w, &valid)
        CajuWorld.accumulate(B.self, &r, &w, &valid)
        CajuWorld.accumulate(C.self, &r, &w, &valid)
        CajuWorld.accumulate(D.self, &r, &w, &valid)
        CajuWorld.accumulate(E.self, &r, &w, &valid)
        CajuWorld.accumulate(F.self, &r, &w, &valid)
        CajuWorld.accumulate(G.self, &r, &w, &valid)
        CajuWorld.accumulate(H.self, &r, &w, &valid)
        try check(reads: CajuComponentMask(bits: r), writes: CajuComponentMask(bits: w))
        world.forEach(a, b, c, d, e, f, g, h, filter: filter, body)
    }

}
