import CajuMath
import CajuTesting
import Testing

@testable import CajuUILayout

private func leaf(_ w: Float, _ h: Float) -> CajuLayoutKind { .leaf(.fixed(CajuVec2(w, h))) }

private func frame(_ tree: CajuLayoutTree, _ id: CajuLayoutNodeID) -> CajuUIRect {
    tree.frame(of: id) ?? .zero
}

@Suite("Pilhas")
struct CajuStackTests {
    @Test func hStackPlacesFixedChildrenWithSpacing() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack(spacing: 10, alignment: .top))
        let a = try t.add(leaf(20, 30), to: root)
        let b = try t.add(leaf(40, 10), to: root)
        t.layout(in: CajuVec2(500, 500))
        #expect(frame(t, root).size == CajuVec2(70, 30))  // encolhe ao conteúdo
        #expect(frame(t, a) == CajuUIRect(x: 0, y: 0, width: 20, height: 30))
        #expect(frame(t, b) == CajuUIRect(x: 30, y: 0, width: 40, height: 10))
    }

    @Test func vStackCrossAlignment() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.vStack(spacing: 0, alignment: .trailing))
        let a = try t.add(leaf(20, 10), to: root)
        let b = try t.add(leaf(50, 10), to: root)
        t.layout(in: CajuVec2(500, 500))
        #expect(frame(t, a).origin.x == 30)
        #expect(frame(t, b).origin.x == 0)
        #expect(frame(t, b).origin.y == 10)
    }

    @Test func spacerPushesSiblingsApart() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack())
        let a = try t.add(leaf(20, 20), to: root)
        _ = try t.add(.spacer(), to: root)
        let b = try t.add(leaf(20, 20), to: root)
        t.layout(in: CajuVec2(200, 50))
        #expect(frame(t, a).origin.x == 0)
        #expect(frame(t, b).origin.x == 180)
        #expect(frame(t, root).size.x == 200)
        #expect(frame(t, root).size.y == 20)  // Spacer não estica o eixo transversal
    }

    @Test func twoSpacersShareEqually() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.vStack())
        _ = try t.add(.spacer(), to: root)
        let mid = try t.add(leaf(10, 20), to: root)
        _ = try t.add(.spacer(), to: root)
        t.layout(in: CajuVec2(10, 100))
        #expect(frame(t, mid).origin.y == 40)
    }

    @Test func spacerMinLengthIsRespected() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack())
        _ = try t.add(leaf(10, 10), to: root)
        _ = try t.add(.spacer(minLength: 30), to: root)
        let b = try t.add(leaf(10, 10), to: root)
        t.layout(in: CajuVec2(25, 10))  // menor que o mínimo: transborda sem encolher
        #expect(frame(t, b).origin.x == 40)
    }

    @Test func flexibleChildTakesRemainingSpace() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack())
        let fixed = try t.add(leaf(100, 10), to: root)
        let flex = try t.add(.leaf(.flexible()), to: root)
        t.layout(in: CajuVec2(300, 10))
        #expect(frame(t, fixed).size.x == 100)
        #expect(frame(t, flex).size.x == 200)
        #expect(frame(t, flex).origin.x == 100)
    }

    @Test func waterFillingRespectsMaximums() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack())
        let capped = try t.add(
            .leaf(CajuSizeRange(min: .zero, ideal: CajuVec2(10, 10), max: CajuVec2(50, 10))), to: root)
        let open = try t.add(.leaf(.flexible()), to: root)
        t.layout(in: CajuVec2(300, 10))
        #expect(frame(t, capped).size.x == 50)
        #expect(frame(t, open).size.x == 250)
    }

    @Test func waterFillingRespectsMinimums() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack())
        let big = try t.add(
            .leaf(
                CajuSizeRange(min: CajuVec2(200, 0), ideal: CajuVec2(200, 10), max: CajuVec2(.infinity, 10))),
            to: root)
        let small = try t.add(.leaf(.flexible()), to: root)
        t.layout(in: CajuVec2(300, 10))
        #expect(frame(t, big).size.x == 200)
        #expect(frame(t, small).size.x == 100)
    }

    @Test func nestedRowsAndColumns() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.vStack(spacing: 4, alignment: .leading))
        let row1 = try t.add(.hStack(spacing: 4), to: root)
        _ = try t.add(leaf(10, 10), to: row1)
        let r1b = try t.add(leaf(10, 10), to: row1)
        let row2 = try t.add(.hStack(), to: root)
        let r2 = try t.add(leaf(30, 10), to: row2)
        t.layout(in: CajuVec2(100, 100))
        #expect(frame(t, r1b).origin == CajuVec2(14, 0))
        #expect(frame(t, r2).origin.y == 14)
        #expect(frame(t, root).size == CajuVec2(30, 24))
    }
}

@Suite("ZStack, frame e padding")
struct CajuSingleChildTests {
    @Test func zStackAlignsEachChild() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.frame(CajuFrameConstraints(width: 100, height: 100)))
        let z = try t.add(.zStack(alignment: .bottomTrailing), to: root)
        let a = try t.add(leaf(100, 100), to: z)
        let b = try t.add(leaf(20, 10), to: z)
        t.layout(in: CajuVec2(500, 500))
        #expect(frame(t, a) == CajuUIRect(x: 0, y: 0, width: 100, height: 100))
        #expect(frame(t, b) == CajuUIRect(x: 80, y: 90, width: 20, height: 10))
    }

    @Test func fixedFrameCentersChild() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.frame(CajuFrameConstraints(width: 100, height: 50)))
        let child = try t.add(leaf(20, 10), to: root)
        t.layout(in: CajuVec2(500, 500))
        #expect(frame(t, root).size == CajuVec2(100, 50))
        #expect(frame(t, child) == CajuUIRect(x: 40, y: 20, width: 20, height: 10))
    }

    @Test func maxWidthInfinityFillsProposal() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.frame(CajuFrameConstraints(maxWidth: .infinity, alignment: .topLeading)))
        let child = try t.add(leaf(20, 10), to: root)
        t.layout(in: CajuVec2(300, 300))
        #expect(frame(t, root).size == CajuVec2(300, 10))
        #expect(frame(t, child).origin == .zero)
    }

    @Test func frameMinimumGrowsAndMaximumCapsAFixedChild() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack(alignment: .top))
        let grown = try t.add(.frame(CajuFrameConstraints(minWidth: 50)), to: root)
        _ = try t.add(leaf(20, 10), to: grown)
        let capped = try t.add(.frame(CajuFrameConstraints(maxWidth: 15)), to: root)
        _ = try t.add(leaf(20, 10), to: capped)
        t.layout(in: CajuVec2(500, 100))
        #expect(frame(t, grown).size.x == 50)
        #expect(frame(t, capped).size.x == 15)  // o filho transborda
    }

    @Test func paddingInsetsChild() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.padding(CajuInsets(top: 1, leading: 2, bottom: 3, trailing: 4)))
        let child = try t.add(leaf(10, 10), to: root)
        t.layout(in: CajuVec2(500, 500))
        #expect(frame(t, root).size == CajuVec2(16, 14))
        #expect(frame(t, child) == CajuUIRect(x: 2, y: 1, width: 10, height: 10))
    }

    @Test func nonFiniteProposalUsesIdealSize() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.leaf(.flexible(ideal: CajuVec2(30, 40))))
        t.layout(in: CajuVec2(.infinity, .nan))
        #expect(frame(t, root).size == CajuVec2(30, 40))
    }

    @Test func hostileValuesAreSanitized() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack(spacing: -5))
        let a = try t.add(.leaf(.fixed(CajuVec2(.nan, -3))), to: root)
        t.layout(in: CajuVec2(100, 100))
        #expect(frame(t, a).size == .zero)
    }
}

@Suite("Árvore")
struct CajuTreeEditingTests {
    @Test func structuralErrors() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.frame(CajuFrameConstraints(width: 10)))
        #expect(throws: CajuLayoutError.rootAlreadyExists) { try t.add(.zStack()) }
        let child = try t.add(leaf(1, 1), to: root)
        #expect(throws: CajuLayoutError.parentCannotHaveMoreChildren) { try t.add(leaf(1, 1), to: root) }
        #expect(throws: CajuLayoutError.parentCannotHaveMoreChildren) { try t.add(leaf(1, 1), to: child) }
        #expect(throws: CajuLayoutError.parentCannotHaveMoreChildren) { try t.update(root, kind: leaf(1, 1)) }
        try t.remove(child)
        #expect(throws: CajuLayoutError.invalidNode) { try t.update(child, kind: leaf(1, 1)) }
    }

    @Test func depthIsBounded() throws {
        var t = CajuLayoutTree()
        var cur = try t.add(.zStack())
        for _ in 1..<CajuLayoutTree.maxDepth { cur = try t.add(.zStack(), to: cur) }
        #expect(throws: CajuLayoutError.depthExceeded) { try t.add(.zStack(), to: cur) }
        t.layout(in: CajuVec2(10, 10))  // não estoura a pilha
    }

    @Test func removedIDsBecomeStaleAndSlotsAreReused() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.vStack())
        let a = try t.add(leaf(10, 10), to: root)
        let b = try t.add(leaf(10, 10), to: root)
        try t.remove(a)
        #expect(t.frame(of: a) == nil)
        #expect(throws: CajuLayoutError.invalidNode) { try t.remove(a) }
        let c = try t.add(leaf(10, 10), to: root)
        #expect(c != a)
        t.layout(in: CajuVec2(100, 100))
        #expect(t.children(of: root) == [b, c])
        #expect(frame(t, c).origin.y == 10)
        #expect(t.count == 3)
    }

    @Test func removingSubtreeFreesAllNodes() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.vStack())
        let group = try t.add(.hStack(), to: root)
        for _ in 0..<5 { _ = try t.add(leaf(1, 1), to: group) }
        _ = try t.add(leaf(1, 1), to: root)
        try t.remove(group)
        #expect(t.count == 2)
        try t.remove(root)
        #expect(t.count == 0)
        #expect(t.rootID == nil)
        _ = try t.add(.zStack())  // pode recomeçar
    }

    @Test func layoutIsSkippedWhenNothingChanged() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack())
        _ = try t.add(leaf(10, 10), to: root)
        t.layout(in: CajuVec2(100, 100))
        t.layout(in: CajuVec2(100, 100))
        #expect(t.layoutPasses == 1)
        t.layout(in: CajuVec2(120, 100))
        #expect(t.layoutPasses == 2)
        _ = try t.add(leaf(10, 10), to: root)
        t.layout(in: CajuVec2(120, 100))
        #expect(t.layoutPasses == 3)
    }
}

@Suite("Hit-testing")
struct CajuHitTestTests {
    @Test func topmostSiblingWins() throws {
        var t = CajuLayoutTree()
        let z = try t.add(.zStack(alignment: .topLeading))
        let below = try t.add(leaf(100, 100), to: z)
        let above = try t.add(leaf(40, 40), to: z)
        t.layout(in: CajuVec2(100, 100))
        #expect(t.hitTest(CajuVec2(10, 10)) == above)
        #expect(t.hitTest(CajuVec2(60, 60)) == below)
        #expect(t.hitTest(CajuVec2(100, 100)) == nil)  // borda direita/inferior exclusiva
        #expect(t.hitTest(CajuVec2(-1, 5)) == nil)
    }

    @Test func nonHitTestableNodesAreSkipped() throws {
        var t = CajuLayoutTree()
        let z = try t.add(.zStack(alignment: .topLeading))
        let below = try t.add(leaf(100, 100), to: z)
        let above = try t.add(leaf(40, 40), to: z)
        try t.setHitTestable(above, false)
        t.layout(in: CajuVec2(100, 100))
        #expect(t.hitTest(CajuVec2(10, 10)) == below)
        try t.setHitTestable(z, true)
        try t.setHitTestable(below, false)
        #expect(t.hitTest(CajuVec2(10, 10)) == z)
    }

    @Test func spacerAndContainersDoNotCatchByDefault() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.hStack())
        let a = try t.add(leaf(10, 10), to: root)
        _ = try t.add(.spacer(), to: root)
        t.layout(in: CajuVec2(100, 10))
        #expect(t.hitTest(CajuVec2(50, 5)) == nil)
        #expect(t.hitTest(CajuVec2(5, 5)) == a)
    }

    @Test func childrenOutsideParentAreClipped() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.frame(CajuFrameConstraints(width: 10, height: 10, alignment: .topLeading)))
        _ = try t.add(leaf(100, 100), to: root)
        t.layout(in: CajuVec2(200, 200))
        #expect(t.hitTest(CajuVec2(50, 50)) == nil)
        #expect(t.hitTest(CajuVec2(5, 5)) != nil)
    }
}

@Suite("Propriedades")
struct CajuLayoutPropertyTests {
    /// Gera uma árvore aleatória sem `frame` fixo (que pode transbordar por definição).
    private func randomTree(_ rng: inout CajuPCG32, into t: inout CajuLayoutTree) throws {
        func fl(_ lo: Float, _ hi: Float, _ rng: inout CajuPCG32) -> Float { rng.nextFloat(in: lo...hi) }
        func randomLeaf(_ rng: inout CajuPCG32) -> CajuLayoutKind {
            if rng.nextUInt32() % 3 == 0 {
                return .leaf(.flexible(ideal: CajuVec2(fl(0, 50, &rng), fl(0, 50, &rng))))
            }
            return leaf(fl(0, 80, &rng), fl(0, 80, &rng))
        }
        func container(_ rng: inout CajuPCG32) -> CajuLayoutKind {
            switch rng.nextUInt32() % 5 {
            case 0: return .hStack(spacing: fl(0, 8, &rng), alignment: .center)
            case 1: return .vStack(spacing: fl(0, 8, &rng), alignment: .leading)
            case 2: return .zStack(alignment: .bottomTrailing)
            case 3: return .padding(CajuInsets(all: fl(0, 6, &rng)))
            default:
                return .frame(
                    CajuFrameConstraints(
                        minWidth: fl(0, 40, &rng), minHeight: fl(0, 40, &rng), maxHeight: .infinity))
            }
        }
        var open: [CajuLayoutNodeID] = [try t.add(.vStack())]
        for _ in 0..<Int(rng.nextUInt32() % 40) + 1 {
            let parent = open[Int(rng.nextUInt32()) % open.count]
            let spacer = rng.nextUInt32() % 6 == 0
            let kind =
                spacer
                ? .spacer(minLength: fl(0, 10, &rng))
                : (rng.nextUInt32() % 3 == 0 ? container(&rng) : randomLeaf(&rng))
            if let id = try? t.add(kind, to: parent) {
                if kind.maxChildren > 0 { open.append(id) }
            } else {
                open.removeAll { $0 == parent }
                if open.isEmpty { return }
            }
        }
    }

    @Test func childrenStayInsideParentWhenRootFitsMinimum() throws {
        try CajuFuzz.run(iterations: 10_000) { rng, _ in
            var t = CajuLayoutTree()
            try randomTree(&rng, into: &t)
            guard let root = t.rootID else { return }
            t.layout(in: .zero)
            let min = t.ranges[Int(t.root)].min
            let avail = CajuVec2(min.x + rng.nextFloat(in: 0...200), min.y + rng.nextFloat(in: 0...200))
            t.layout(in: avail)
            let eps: Float = 1e-3
            var stack = [root]
            while let n = stack.popLast() {
                let r = frame(t, n)
                #expect(r.size.x >= 0 && r.size.y >= 0 && r.size.x.isFinite && r.size.y.isFinite)
                for c in t.children(of: n) {
                    let f = frame(t, c)
                    let ok =
                        f.origin.x >= r.origin.x - eps && f.origin.y >= r.origin.y - eps
                        && f.maxX <= r.maxX + eps && f.maxY <= r.maxY + eps
                    #expect(ok)
                    stack.append(c)
                }
            }
        }
    }

    @Test func layoutIsDeterministic() throws {
        try CajuFuzz.run(iterations: 1_000) { rng, _ in
            var t = CajuLayoutTree()
            try randomTree(&rng, into: &t)
            t.layout(in: CajuVec2(150, 150))
            let first = t.frames
            t.invalidate()
            t.layout(in: CajuVec2(150, 150))
            #expect(first == t.frames)
        }
    }

    @Test func hStackMainAxisSumsToAvailable() throws {
        try CajuFuzz.run(iterations: 10_000) { rng, _ in
            var t = CajuLayoutTree()
            let root = try t.add(.hStack(spacing: 2))
            let n = Int(rng.nextUInt32() % 8) + 1
            var minSum: Float = 0
            var maxSum: Float = 0
            for _ in 0..<n {
                let lo = rng.nextFloat(in: 0...30)
                let hi = rng.nextUInt32() % 4 == 0 ? Float.infinity : lo + rng.nextFloat(in: 0...60)
                minSum += lo
                maxSum += hi
                _ = try t.add(
                    .leaf(CajuSizeRange(min: CajuVec2(lo, 0), ideal: CajuVec2(lo, 0), max: CajuVec2(hi, 5))),
                    to: root)
            }
            let spacing = 2 * Float(n - 1)
            let avail = minSum + spacing + rng.nextFloat(in: 0...100)
            t.layout(in: CajuVec2(avail, 10))
            let used = frame(t, root).size.x
            #expect(abs(used - min(avail, maxSum + spacing)) <= 1e-3 * max(1, avail))
            let sum = t.children(of: root).reduce(Float(0)) { $0 + frame(t, $1).size.x } + spacing
            #expect(abs(sum - used) <= 1e-3 * max(1, avail))
        }
    }
}

@Suite("Alocação")
struct CajuAllocationTests {
    /// Em árvore estável o layout e o hit-test só leem/escrevem nos arrays existentes: o armazenamento
    /// não é realocado. (A ausência de `malloc` foi conferida à parte com um contador via `LD_PRELOAD`.)
    @Test func stableTreeKeepsItsStorage() throws {
        var t = CajuLayoutTree()
        let root = try t.add(.vStack(spacing: 2))
        for _ in 0..<20 {
            let row = try t.add(.hStack(spacing: 2), to: root)
            for _ in 0..<5 { _ = try t.add(leaf(10, 10), to: row) }
            _ = try t.add(.spacer(), to: row)
        }
        t.layout(in: CajuVec2(300, 600))
        func addresses(_ t: CajuLayoutTree) -> [Int] {
            [
                t.nodes.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) },
                t.ranges.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) },
                t.frames.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) },
                t.mainSizes.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) },
                t.frozen.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) },
            ]
        }
        let before = addresses(t)
        var hits = 0
        for i in 0..<200 {
            t.invalidate()
            t.layout(in: CajuVec2(300, 600))
            if t.hitTest(CajuVec2(Float(i % 100), Float(i % 200))) != nil { hits += 1 }
        }
        #expect(addresses(t) == before)
        #expect(hits > 0)
    }
}
