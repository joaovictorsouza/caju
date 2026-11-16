import CajuCore
import CajuMath
import CajuPhysicsSpatial
import CajuScene

/// Índice espacial dos `CajuCollider` de um `CajuWorld` e consultas sobre ele (raycast, sobreposição,
/// varredura de esfera, picking).
///
/// - Uso: chame `sync(world:)` (ou registre `syncSystem(world:)` no estágio `postUpdate`, depois da
///   propagação de transform) e consulte. Cada `sync` insere, atualiza e remove proxies na
///   `CajuBVH`; as consultas só leem.
/// - Sem alocação por consulta: a pilha de travessia e os *visitors* são reutilizados/não escapantes.
///   `sync` pode alocar (cresce tabelas); consultas, não.
/// - Não é thread-safe: use da mesma thread que roda o agendador.
public final class CajuPhysicsScene {
    @usableFromInline internal var bvh: CajuBVH
    @usableFromInline internal var stack = CajuBVHTraversalStack()
    @usableFromInline internal var entries: [CajuColliderEntry] = []
    private var proxyOfEntity: [CajuBVHProxy?] = []
    private var stamp: UInt64 = 0

    /// Quantidade de volumes indexados.
    public var count: Int { bvh.count }

    public init(fatMargin: Float = 0.05) throws(CajuSpatialError) {
        bvh = try CajuBVH(fatMargin: fatMargin)
    }

    // MARK: - Sincronização com o ECS

    /// Sistema do estágio `postUpdate` que chama `sync(world:)`.
    ///
    /// O contexto de sistema não entrega entidades, então o sistema captura `world` (o mesmo do
    /// agendador) e declara a leitura de `CajuCollider` e `CajuGlobalTransform`.
    public func syncSystem(world: CajuWorld) -> CajuSystemDescriptor {
        CajuSystemDescriptor(
            name: "CajuPhysics.sync", stage: .postUpdate,
            reads: CajuComponentMask(CajuCollider.componentID, CajuGlobalTransform.componentID),
            after: ["CajuScene.transformPropagation"]
        ) { [self] _ throws(CajuAccessError) in
            sync(world: world)
        }
    }

    /// Reflete na BVH as entidades com `CajuCollider` + `CajuGlobalTransform`: insere as novas, atualiza
    /// as que se moveram e remove as que sumiram (despawn, componente removido ou volume inválido).
    public func sync(world: CajuWorld) {
        stamp &+= 1
        let current = stamp
        world.forEachEntity(having: CajuCollider.self) { entity, collider in
            guard collider.isValid, let g = world.get(CajuGlobalTransform.self, of: entity),
                let inv = g.matrix.inverseAffine
            else { return }
            upsert(entity, collider, g.matrix, inv, current)
        }
        for i in entries.indices where entries[i].live && entries[i].stamp != current {
            removeSlot(i)
        }
    }

    private func upsert(
        _ entity: CajuEntity, _ collider: CajuCollider, _ m: CajuMat4, _ inv: CajuMat4, _ current: UInt64
    ) {
        let ei = Int(entity.index)
        if ei >= proxyOfEntity.count {
            proxyOfEntity.append(contentsOf: repeatElement(nil, count: ei + 1 - proxyOfEntity.count))
        }
        if let p = proxyOfEntity[ei] {
            let slot = Int(p.index)
            if entries[slot].live, entries[slot].entity == entity {
                let old = entries[slot].worldBounds().center.storage
                entries[slot].collider = collider
                entries[slot].world = m
                entries[slot].inverse = inv
                entries[slot].stamp = current
                let b = entries[slot].worldBounds()
                _ = try? bvh.update(p, bounds: b, displacement: b.center.storage - old)
                return
            }
            if entries[slot].live { removeSlot(slot) }
            proxyOfEntity[ei] = nil
        }
        var entry = CajuColliderEntry(
            entity: entity, collider: collider, world: m, inverse: inv, stamp: current, live: true)
        guard let p = try? bvh.insert(bounds: entry.worldBounds(), userData: entity.index) else { return }
        let slot = Int(p.index)
        if slot >= entries.count {
            entry.live = true
            entries.append(
                contentsOf: repeatElement(
                    CajuColliderEntry(
                        entity: entity, collider: collider, world: m, inverse: inv, stamp: 0, live: false),
                    count: slot + 1 - entries.count))
        }
        entries[slot] = entry
        proxyOfEntity[ei] = p
    }

    private func removeSlot(_ slot: Int) {
        let e = entries[slot]
        entries[slot].live = false
        let ei = Int(e.entity.index)
        if ei < proxyOfEntity.count, let p = proxyOfEntity[ei], Int(p.index) == slot {
            _ = try? bvh.remove(p)
            proxyOfEntity[ei] = nil
        }
    }

    // MARK: - Raycast

    /// Primeiro volume atingido por `ray` (menor `t`), ou `nil`. `t` está em unidades de `ray.direction`.
    public func raycast(
        _ ray: CajuRay, maxDistance: Float = .greatestFiniteMagnitude, layerMask: UInt32 = .max
    ) -> CajuPhysicsHit? {
        guard let q = try? CajuRayQuery(ray: ray, tMin: 0, tMax: maxDistance) else { return nil }
        var best: CajuPhysicsHit?
        var bestT = q.tMax
        bvh.raycastAll(q, stack: &stack) { hit in
            let e = entries[Int(hit.proxy.index)]
            guard e.live, e.collider.layers & layerMask != 0,
                let r = e.raycast(origin: q.origin, direction: q.direction, tMin: q.tMin, tMax: bestT)
            else { return true }
            bestT = r.t
            best = CajuPhysicsHit(
                entity: e.entity, t: r.t, point: CajuVec3(storage: q.point(at: r.t)),
                normal: CajuVec3(storage: r.normal))
            return true
        }
        return best
    }

    /// Visita todos os volumes atingidos por `ray` (ordem não especificada). `visitor` devolve `false` para parar.
    public func raycastAll(
        _ ray: CajuRay, maxDistance: Float = .greatestFiniteMagnitude, layerMask: UInt32 = .max,
        visitor: (CajuPhysicsHit) -> Bool
    ) {
        guard let q = try? CajuRayQuery(ray: ray, tMin: 0, tMax: maxDistance) else { return }
        bvh.raycastAll(q, stack: &stack) { hit in
            let e = entries[Int(hit.proxy.index)]
            guard e.live, e.collider.layers & layerMask != 0,
                let r = e.raycast(origin: q.origin, direction: q.direction, tMin: q.tMin, tMax: q.tMax)
            else { return true }
            return visitor(
                CajuPhysicsHit(
                    entity: e.entity, t: r.t, point: CajuVec3(storage: q.point(at: r.t)),
                    normal: CajuVec3(storage: r.normal)))
        }
    }

    // MARK: - Shapecast

    /// Visita as entidades cujo volume toca `sphere`. `visitor` devolve `false` para parar.
    public func overlapSphere(
        _ sphere: CajuSphere, layerMask: UInt32 = .max, visitor: (CajuEntity) -> Bool
    ) {
        let c = sphere.center.storage
        try? bvh.shapecast(sphere: sphere, stack: &stack) { proxy, _ in
            let e = entries[Int(proxy.index)]
            guard e.live, e.collider.layers & layerMask != 0,
                e.overlaps(sphereCenter: c, radius: sphere.radius)
            else { return true }
            return visitor(e.entity)
        }
    }

    /// Primeiro volume atingido ao varrer `sphere` por `displacement` (`t` em `0...1`), ou `nil`.
    /// Exato contra esferas; contra caixas é conservador nas arestas e cantos.
    public func spherecast(
        _ sphere: CajuSphere, displacement: CajuVec3, layerMask: UInt32 = .max
    ) -> CajuPhysicsHit? {
        guard sphere.isFinite, sphere.radius >= 0, displacement.isFinite else { return nil }
        let c = sphere.center.storage
        let d = displacement.storage
        let r = SIMD3<Float>(repeating: sphere.radius)
        let box = CajuAABB(min: CajuVec3(storage: c - r), max: CajuVec3(storage: c + r))
        var best: CajuPhysicsHit?
        var bestT = Float.infinity
        try? bvh.shapecast(swept: box, displacement: d, stack: &stack) { hit in
            let e = entries[Int(hit.proxy.index)]
            guard e.live, e.collider.layers & layerMask != 0,
                let s = e.spherecast(origin: c, displacement: d, radius: sphere.radius), s.t < bestT
            else { return true }
            bestT = s.t
            best = CajuPhysicsHit(
                entity: e.entity, t: s.t, point: CajuVec3(storage: c + d * s.t),
                normal: CajuVec3(storage: s.normal))
            return true
        }
        return best
    }

    // MARK: - Picking

    /// Picking por ponteiro: raio da câmera pelo ponto `pointer` e primeiro volume atingido.
    public func pick(
        pointer: CajuVec2, viewportSize: CajuVec2, inverseViewProjection: CajuMat4,
        maxDistance: Float = .greatestFiniteMagnitude, layerMask: UInt32 = .max
    ) -> CajuPhysicsHit? {
        guard
            let ray = CajuPicking.ray(
                pointer: pointer, viewportSize: viewportSize, inverseViewProjection: inverseViewProjection)
        else { return nil }
        return raycast(ray, maxDistance: maxDistance, layerMask: layerMask)
    }
}
