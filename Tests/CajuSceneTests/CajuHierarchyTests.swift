import CajuCore
import CajuMath
import CajuScene
import Testing

private func makeScheduler(_ world: CajuWorld) throws -> CajuScheduler {
    let s = CajuScheduler(world: world)
    try s.add(CajuScene.transformPropagation())
    try s.build()
    return s
}

private func close(_ a: CajuVec3, _ b: CajuVec3) -> Bool { (a - b).length < 1e-4 }

@Suite("CajuScene hierarquia")
struct CajuHierarchyTests {
    @Test func transformMatrixIsTRS() {
        let q = CajuQuat(axis: .unitZ, radians: .pi / 2) ?? .identity
        let t = CajuTransform(position: CajuVec3(1, 2, 3), rotation: q, scale: CajuVec3(2, 2, 2))
        // ponto (1,0,0): escala → (2,0,0); rotação 90° em Z → (0,2,0); translação → (1,4,3)
        #expect(close(t.matrix.transformPoint(CajuVec3(1, 0, 0)), CajuVec3(1, 4, 3)))
        #expect(t.position == CajuVec3(1, 2, 3) && t.scale == CajuVec3(2, 2, 2))
        #expect(CajuGlobalTransform(t.matrix).matrix == t.matrix)
    }

    @Test func chainPropagatesParentBeforeChild() throws {
        let w = CajuWorld()
        let s = try makeScheduler(w)
        let q = CajuQuat(axis: .unitZ, radians: .pi / 2) ?? .identity
        // Registra o filho antes do pai na memória para provar independência da ordem de armazenamento.
        let root = try w.spawnNode(CajuTransform(position: CajuVec3(10, 0, 0), rotation: q))
        let mid = try w.spawnNode(CajuTransform(position: CajuVec3(1, 0, 0)), parent: root)
        let leaf = try w.spawnNode(CajuTransform(position: CajuVec3(1, 0, 0)), parent: mid)
        try s.tick(delta: 0.016)
        // root gira 90° em Z: mid em (10,1,0); leaf em (10,2,0)
        #expect(close(try #require(w.globalMatrix(of: mid)).transformPoint(.zero), CajuVec3(10, 1, 0)))
        #expect(close(try #require(w.globalMatrix(of: leaf)).transformPoint(.zero), CajuVec3(10, 2, 0)))
        #expect(w.get(CajuParent.self, of: leaf)?.depth == 2)
        #expect(w.children(of: root) == [mid] && w.parent(of: leaf) == mid)

        // Mover o pai move a árvore.
        w.set(CajuTransform(position: CajuVec3(0, 5, 0), rotation: q), on: root)
        try s.tick(delta: 0.016)
        #expect(close(try #require(w.globalMatrix(of: leaf)).transformPoint(.zero), CajuVec3(0, 7, 0)))
    }

    @Test func reparentUpdatesDepthsOfSubtree() throws {
        let w = CajuWorld()
        let a = try w.spawnNode()
        let b = try w.spawnNode(parent: a)
        let c = try w.spawnNode(parent: b)
        let d = try w.spawnNode()
        #expect(w.get(CajuParent.self, of: c)?.depth == 2)
        try w.setParent(b, to: d)  // b e c migram para a árvore de d
        try w.setParent(d, to: a)  // d vira filho de a: b=3? (a→d→b→c)
        #expect(w.get(CajuParent.self, of: d)?.depth == 1)
        #expect(w.get(CajuParent.self, of: b)?.depth == 2)
        #expect(w.get(CajuParent.self, of: c)?.depth == 3)
        try w.setParent(b, to: nil)
        #expect(w.parent(of: b) == nil)
        #expect(w.get(CajuParent.self, of: c)?.depth == 1)
    }

    @Test func rejectsCyclesAndStaleParents() throws {
        let w = CajuWorld()
        let a = try w.spawnNode()
        let b = try w.spawnNode(parent: a)
        #expect(throws: CajuHierarchyError.cycle) { try w.setParent(a, to: b) }
        #expect(throws: CajuHierarchyError.cycle) { try w.setParent(a, to: a) }
        let gone = try w.spawnNode()
        try w.despawn(gone)
        #expect(throws: CajuHierarchyError.staleParent(gone)) { try w.setParent(b, to: gone) }
        #expect(throws: CajuHierarchyError.world(.staleEntity(gone))) { try w.setParent(gone, to: a) }
        #expect(throws: CajuHierarchyError.staleParent(gone)) { _ = try w.spawnNode(parent: gone) }
        #expect(w.entityCount == 2)  // o nó criado para o pai inválido foi desfeito
    }

    @Test func orphanedChildBecomesRootInPropagation() throws {
        let w = CajuWorld()
        let s = try makeScheduler(w)
        let p = try w.spawnNode(CajuTransform(position: CajuVec3(100, 0, 0)))
        let c = try w.spawnNode(CajuTransform(position: CajuVec3(1, 0, 0)), parent: p)
        try w.despawn(p)
        try s.tick(delta: 0.016)
        #expect(close(try #require(w.globalMatrix(of: c)).transformPoint(.zero), CajuVec3(1, 0, 0)))
    }

    @Test func despawnSubtreeRemovesDescendantsOnly() throws {
        let w = CajuWorld()
        let a = try w.spawnNode()
        let b = try w.spawnNode(parent: a)
        let c = try w.spawnNode(parent: b)
        let other = try w.spawnNode()
        try w.despawnSubtree(b)
        #expect(w.contains(a) && w.contains(other) && !w.contains(b) && !w.contains(c))
    }

    @Test func wideTreeMatchesManualComposition() throws {
        let w = CajuWorld()
        let s = try makeScheduler(w)
        let root = try w.spawnNode(CajuTransform(position: CajuVec3(1, 1, 1), scale: CajuVec3(2, 2, 2)))
        var kids: [CajuEntity] = []
        for i in 0..<500 {
            kids.append(try w.spawnNode(CajuTransform(position: CajuVec3(Float(i), 0, 0)), parent: root))
        }
        try s.tick(delta: 0.016)
        for (i, k) in kids.enumerated() {
            #expect(
                close(
                    try #require(w.globalMatrix(of: k)).transformPoint(.zero),
                    CajuVec3(1 + 2 * Float(i), 1, 1)))
        }
    }
}
