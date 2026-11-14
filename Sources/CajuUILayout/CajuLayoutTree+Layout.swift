import CajuMath

@inline(__always) private func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
    Swift.min(Swift.max(v, lo), hi)
}

@inline(__always) private func clamp(_ v: CajuVec2, _ r: CajuSizeRange) -> CajuVec2 {
    CajuVec2(clamp(v.x, r.min.x, r.max.x), clamp(v.y, r.min.y, r.max.y))
}

extension CajuLayoutTree {
    /// Calcula as molduras de todos os nós dentro de `available` (tamanho proposto à raiz).
    ///
    /// Nada é recalculado se a árvore não mudou e `available` é o mesmo da chamada anterior.
    /// Um eixo não finito de `available` usa o tamanho ideal da raiz nesse eixo.
    public mutating func layout(in available: CajuVec2) {
        guard root >= 0 else { return }
        guard isDirty || available != lastAvailable else { return }
        layoutPasses += 1
        computeRanges(root)
        let r = ranges[Int(root)]
        let proposal = CajuVec2(
            available.x.isFinite ? available.x : r.ideal.x,
            available.y.isFinite ? available.y : r.ideal.y)
        place(root, origin: .zero, size: clamp(proposal, r))
        lastAvailable = available
        isDirty = false
    }

    // MARK: - Passo 1: faixas de baixo para cima

    private mutating func computeRanges(_ i: Int32) {
        var c = nodes[Int(i)].firstChild
        while c >= 0 {
            computeRanges(c)
            c = nodes[Int(c)].nextSibling
        }
        ranges[Int(i)] = range(of: i)
    }

    private func range(of i: Int32) -> CajuSizeRange {
        let node = nodes[Int(i)]
        switch node.kind {
        case .leaf(let r):
            return r
        case .spacer(let m):
            if node.parent >= 0 {
                switch nodes[Int(node.parent)].kind {
                case .hStack:
                    return CajuSizeRange(
                        min: CajuVec2(m, 0), ideal: CajuVec2(m, 0), max: CajuVec2(.infinity, 0))
                case .vStack:
                    return CajuSizeRange(
                        min: CajuVec2(0, m), ideal: CajuVec2(0, m), max: CajuVec2(0, .infinity))
                default: break
                }
            }
            return CajuSizeRange(
                min: CajuVec2(m, m), ideal: CajuVec2(m, m), max: CajuVec2(.infinity, .infinity))
        case .padding(let ins):
            let child = node.firstChild >= 0 ? ranges[Int(node.firstChild)] : .zero
            let extra = CajuVec2(ins.leading + ins.trailing, ins.top + ins.bottom)
            return CajuSizeRange(min: child.min + extra, ideal: child.ideal + extra, max: child.max + extra)
        case .frame(let c):
            let child = node.firstChild >= 0 ? ranges[Int(node.firstChild)] : .zero
            let w = axisRange(
                fixed: c.width, lo: c.minWidth, hi: c.maxWidth,
                child: (child.min.x, child.ideal.x, child.max.x))
            let h = axisRange(
                fixed: c.height, lo: c.minHeight, hi: c.maxHeight,
                child: (child.min.y, child.ideal.y, child.max.y))
            return CajuSizeRange(
                min: CajuVec2(w.0, h.0), ideal: CajuVec2(w.1, h.1), max: CajuVec2(w.2, h.2))
        case .zStack:
            var r = CajuSizeRange.zero
            var c = node.firstChild
            while c >= 0 {
                let cr = ranges[Int(c)]
                r.min = CajuVec2(Swift.max(r.min.x, cr.min.x), Swift.max(r.min.y, cr.min.y))
                r.ideal = CajuVec2(Swift.max(r.ideal.x, cr.ideal.x), Swift.max(r.ideal.y, cr.ideal.y))
                r.max = CajuVec2(Swift.max(r.max.x, cr.max.x), Swift.max(r.max.y, cr.max.y))
                c = nodes[Int(c)].nextSibling
            }
            return r
        case .hStack(let spacing, _):
            return stackRange(of: node, horizontal: true, spacing: spacing)
        case .vStack(let spacing, _):
            return stackRange(of: node, horizontal: false, spacing: spacing)
        }
    }

    /// Faixa de um eixo do `frame`: o tamanho do quadro é o do filho limitado a `[lo, hi]`; com `hi`
    /// explícito o quadro também cresce até `hi` quando há espaço (`maxWidth: .infinity` preenche).
    /// Se `hi` for menor que o mínimo do filho, o filho transborda (como no SwiftUI).
    private func axisRange(
        fixed: Float?, lo: Float?, hi: Float?, child: (Float, Float, Float)
    ) -> (Float, Float, Float) {
        if let fixed { return (fixed, fixed, fixed) }
        let floor = lo ?? 0
        let ceiling = Swift.max(hi ?? .infinity, floor)
        let low = clamp(child.0, floor, ceiling)
        let high = hi != nil ? Swift.max(ceiling, low) : Swift.max(child.2, low)
        return (low, clamp(child.1, low, high), high)
    }

    private func stackRange(of node: Node, horizontal: Bool, spacing: Float) -> CajuSizeRange {
        var n: Float = 0
        var main = SIMD3<Float>(repeating: 0)  // (min, ideal, max) no eixo principal
        var cross = SIMD3<Float>(repeating: 0)
        var c = node.firstChild
        while c >= 0 {
            let r = ranges[Int(c)]
            let m = horizontal ? SIMD3(r.min.x, r.ideal.x, r.max.x) : SIMD3(r.min.y, r.ideal.y, r.max.y)
            let x = horizontal ? SIMD3(r.min.y, r.ideal.y, r.max.y) : SIMD3(r.min.x, r.ideal.x, r.max.x)
            main += m
            cross = cross.replacing(with: x, where: x .> cross)
            n += 1
            c = nodes[Int(c)].nextSibling
        }
        if n > 1 { main += SIMD3(repeating: spacing * (n - 1)) }
        return horizontal
            ? CajuSizeRange(
                min: CajuVec2(main.x, cross.x), ideal: CajuVec2(main.y, cross.y),
                max: CajuVec2(main.z, cross.z))
            : CajuSizeRange(
                min: CajuVec2(cross.x, main.x), ideal: CajuVec2(cross.y, main.y),
                max: CajuVec2(cross.z, main.z))
    }

    // MARK: - Passo 2: molduras de cima para baixo

    private mutating func place(_ i: Int32, origin: CajuVec2, size: CajuVec2) {
        frames[Int(i)] = CajuUIRect(origin: origin, size: size)
        let node = nodes[Int(i)]
        switch node.kind {
        case .leaf, .spacer:
            return
        case .padding(let ins):
            guard node.firstChild >= 0 else { return }
            let inner = CajuVec2(
                Swift.max(0, size.x - ins.leading - ins.trailing),
                Swift.max(0, size.y - ins.top - ins.bottom))
            placeAligned(
                node.firstChild,
                in: CajuUIRect(origin: origin + CajuVec2(ins.leading, ins.top), size: inner),
                alignment: .center)
        case .frame(let c):
            guard node.firstChild >= 0 else { return }
            placeAligned(
                node.firstChild, in: CajuUIRect(origin: origin, size: size), alignment: c.alignment)
        case .zStack(let a):
            var c = node.firstChild
            while c >= 0 {
                placeAligned(c, in: CajuUIRect(origin: origin, size: size), alignment: a)
                c = nodes[Int(c)].nextSibling
            }
        case .hStack(let spacing, let a):
            placeStack(
                node, origin: origin, size: size, horizontal: true, spacing: spacing, crossFactor: a.factor)
        case .vStack(let spacing, let a):
            placeStack(
                node, origin: origin, size: size, horizontal: false, spacing: spacing, crossFactor: a.factor)
        }
    }

    /// Propõe todo o `area` ao filho, aceita o tamanho dentro da faixa dele e o alinha.
    private mutating func placeAligned(_ child: Int32, in area: CajuUIRect, alignment: CajuAlignment) {
        let s = clamp(area.size, ranges[Int(child)])
        let o = CajuVec2(
            area.origin.x + (area.size.x - s.x) * alignment.horizontal.factor,
            area.origin.y + (area.size.y - s.y) * alignment.vertical.factor)
        place(child, origin: o, size: s)
    }

    /// Distribui o eixo principal pelo método do "nível de água": cada filho recebe
    /// `clamp(nível, min, max)` e o nível é ajustado até a soma fechar (como o CSS flex, sem ordenar).
    private mutating func placeStack(
        _ node: Node, origin: CajuVec2, size: CajuVec2, horizontal: Bool, spacing: Float,
        crossFactor: Float
    ) {
        var count = 0
        var sumMin: Float = 0
        var sumMax: Float = 0
        var c = node.firstChild
        while c >= 0 {
            let r = ranges[Int(c)]
            sumMin += horizontal ? r.min.x : r.min.y
            sumMax += horizontal ? r.max.x : r.max.y
            count += 1
            c = nodes[Int(c)].nextSibling
        }
        guard count > 0 else { return }
        let mainExtent = horizontal ? size.x : size.y
        let crossExtent = horizontal ? size.y : size.x
        let avail = Swift.max(0, mainExtent - spacing * Float(count - 1))

        if avail <= sumMin {
            assign(node, horizontal: horizontal, useMax: false)
        } else if avail >= sumMax {
            assign(node, horizontal: horizontal, useMax: true)
        } else {
            var free = count
            var frozenSum: Float = 0
            c = node.firstChild
            while c >= 0 {
                frozen[Int(c)] = false
                c = nodes[Int(c)].nextSibling
            }
            while free > 0 {
                let level = (avail - frozenSum) / Float(free)
                var violation: Float = 0
                c = node.firstChild
                while c >= 0 {
                    if !frozen[Int(c)] {
                        let r = ranges[Int(c)]
                        let lo = horizontal ? r.min.x : r.min.y
                        let hi = horizontal ? r.max.x : r.max.y
                        violation += clamp(level, lo, hi) - level
                    }
                    c = nodes[Int(c)].nextSibling
                }
                c = node.firstChild
                while c >= 0 {
                    let k = Int(c)
                    if !frozen[k] {
                        let r = ranges[k]
                        let lo = horizontal ? r.min.x : r.min.y
                        let hi = horizontal ? r.max.x : r.max.y
                        // violation == 0: todos cabem no nível; > 0: congela os que ficaram abaixo do
                        // mínimo; < 0: congela os que passaram do máximo.
                        if violation == 0 || (violation > 0 && level < lo) || (violation < 0 && level > hi) {
                            let s = clamp(level, lo, hi)
                            mainSizes[k] = s
                            frozen[k] = true
                            frozenSum += s
                            free -= 1
                        }
                    }
                    c = nodes[k].nextSibling
                }
            }
        }

        var cursor: Float = 0
        c = node.firstChild
        while c >= 0 {
            let k = Int(c)
            let r = ranges[k]
            let m = mainSizes[k]
            let cross = clamp(crossExtent, horizontal ? r.min.y : r.min.x, horizontal ? r.max.y : r.max.x)
            let crossOffset = (crossExtent - cross) * crossFactor
            if horizontal {
                place(
                    c, origin: CajuVec2(origin.x + cursor, origin.y + crossOffset), size: CajuVec2(m, cross))
            } else {
                place(
                    c, origin: CajuVec2(origin.x + crossOffset, origin.y + cursor), size: CajuVec2(cross, m))
            }
            cursor += m + spacing
            c = nodes[k].nextSibling
        }
    }

    private mutating func assign(_ node: Node, horizontal: Bool, useMax: Bool) {
        var c = node.firstChild
        while c >= 0 {
            let r = ranges[Int(c)]
            let v = useMax ? r.max : r.min
            mainSizes[Int(c)] = horizontal ? v.x : v.y
            c = nodes[Int(c)].nextSibling
        }
    }
}
