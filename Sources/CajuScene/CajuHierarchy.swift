import CajuCore
import CajuMath

public enum CajuHierarchyError: Error, Equatable, Sendable {
    case world(CajuWorldError)
    case staleParent(CajuEntity)
    /// O pai é o próprio nó ou um descendente dele.
    case cycle
    /// Cadeia de ancestrais maior que `CajuScene.maxDepth`.
    case tooDeep
}

/// Constantes da cena.
public enum CajuScene {
    public static let maxDepth = 1024

    /// Sistema que calcula `CajuGlobalTransform` (estágio `postUpdate`).
    ///
    /// Raízes primeiro; depois cada nível de profundidade (1, 2, …), garantindo pai antes do filho.
    /// Custo: um percurso das entidades com `CajuParent` por nível de profundidade (a melhorar com
    /// *dirty flags*/ordenação quando houver cenas profundas medidas). Pai inexistente = nó raiz.
    public static func transformPropagation() -> CajuSystemDescriptor {
        CajuSystemDescriptor(
            name: "CajuScene.transformPropagation", stage: .postUpdate,
            reads: CajuComponentMask(CajuTransform.componentID, CajuParent.componentID),
            writes: CajuComponentMask(CajuGlobalTransform.componentID)
        ) { ctx throws(CajuAccessError) in
            try ctx.forEach(
                CajuRead<CajuTransform>.self, CajuWrite<CajuGlobalTransform>.self,
                filter: CajuQueryFilter(withoutComponents: CajuComponentMask(CajuParent.componentID))
            ) { t, g in
                g.value = CajuGlobalTransform(t.matrix)
            }
            var level: UInt16 = 1
            while true {
                var processed = 0
                let current = level
                try ctx.forEach(
                    CajuRead<CajuParent>.self, CajuRead<CajuTransform>.self,
                    CajuWrite<CajuGlobalTransform>.self
                ) { p, t, g in
                    guard p.depth == current else { return }
                    processed += 1
                    let local = t.matrix
                    if let parentGlobal = try? ctx.get(CajuGlobalTransform.self, of: p.entity) {
                        g.value = CajuGlobalTransform(parentGlobal.matrix * local)
                    } else {
                        g.value = CajuGlobalTransform(local)
                    }
                }
                if processed == 0 || level == UInt16.max { break }
                level += 1
            }
        }
    }
}

extension CajuWorld {
    /// Cria um nó (transform + matriz de mundo inicial), opcionalmente já filho de `parent`.
    public func spawnNode(_ transform: CajuTransform = .identity, parent: CajuEntity? = nil)
        throws(CajuHierarchyError) -> CajuEntity
    {
        let node: CajuEntity
        do { node = try spawn(transform, CajuGlobalTransform(transform.matrix)) } catch {
            throw .world(error)
        }
        if let parent {
            do throws(CajuHierarchyError) {
                try setParent(node, to: parent)
            } catch {
                try? despawn(node)
                throw error
            }
        }
        return node
    }

    public func parent(of node: CajuEntity) -> CajuEntity? {
        get(CajuParent.self, of: node)?.entity
    }

    /// Filhos diretos (percorre todos os nós com pai; caminho frio, aloca o resultado).
    public func children(of node: CajuEntity) -> [CajuEntity] {
        var result: [CajuEntity] = []
        forEachEntity(having: CajuParent.self) { entity, p in
            if p.entity == node { result.append(entity) }
        }
        return result
    }

    public func globalMatrix(of node: CajuEntity) -> CajuMat4? {
        get(CajuGlobalTransform.self, of: node)?.matrix
    }

    /// Reparenta `child` (ou o torna raiz com `nil`). Recusa ciclos e pais inexistentes.
    public func setParent(_ child: CajuEntity, to newParent: CajuEntity?) throws(CajuHierarchyError) {
        guard contains(child) else { throw .world(.staleEntity(child)) }
        guard let newParent else {
            if has(CajuParent.self, child) {
                do { try remove(CajuParent.self, from: child) } catch { throw .world(error) }
                fixDepths()
            }
            return
        }
        guard contains(newParent) else { throw .staleParent(newParent) }
        var cursor: CajuEntity? = newParent
        var steps = 0
        while let c = cursor {
            if c == child { throw .cycle }
            steps += 1
            if steps > CajuScene.maxDepth { throw .tooDeep }
            cursor = parent(of: c)
        }
        let depth = UInt16(steps)  // newParent está a `steps - 1` níveis da raiz; filho = steps
        do { try insert(CajuParent(entity: newParent, depth: depth), into: child) } catch {
            throw .world(error)
        }
        fixDepths()
    }

    /// Remove o nó e todos os descendentes (caminho frio).
    public func despawnSubtree(_ root: CajuEntity) throws(CajuHierarchyError) {
        guard contains(root) else { throw .world(.staleEntity(root)) }
        var queue = [root]
        var i = 0
        while i < queue.count {
            queue.append(contentsOf: children(of: queue[i]))
            i += 1
        }
        for e in queue.reversed() {
            do { try despawn(e) } catch { throw .world(error) }
        }
    }

    /// Recalcula `depth` de todos os nós com pai até estabilizar (limitado por `maxDepth`).
    private func fixDepths() {
        var changed = true
        var rounds = 0
        while changed && rounds <= CajuScene.maxDepth + 1 {
            changed = false
            rounds += 1
            forEach(CajuWrite<CajuParent>.self) { p in
                let parentDepth = self.get(CajuParent.self, of: p.value.entity)?.depth ?? 0
                let want = parentDepth &+ 1
                if p.value.depth != want {
                    p.value.depth = want
                    changed = true
                }
            }
        }
    }
}
