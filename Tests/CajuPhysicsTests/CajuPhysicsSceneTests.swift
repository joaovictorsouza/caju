import CajuCore
import CajuInput
import CajuMath
import CajuPhysics
import CajuPhysicsSpatial
import CajuPlatform
import CajuScene
import Testing

#if canImport(Darwin)
    import Darwin
#endif

/// Gerador determinístico (xorshift64*), sem relógio nem `SystemRandomNumberGenerator`.
private struct Rng {
    var s: UInt64
    mutating func next() -> Float {
        s ^= s >> 12
        s ^= s << 25
        s ^= s >> 27
        let r = (s &* 2_685_821_657_736_338_717) >> 40
        return Float(r) / Float(1 << 24)
    }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
    mutating func vec(_ a: Float, _ b: Float) -> CajuVec3 {
        CajuVec3(range(a, b), range(a, b), range(a, b))
    }
}

private func makeScheduler(_ world: CajuWorld, _ scene: CajuPhysicsScene) throws -> CajuScheduler {
    let s = CajuScheduler(world: world)
    try s.add(CajuPhysics.kinematicSystem())
    try s.add(CajuScene.transformPropagation())
    try s.add(scene.syncSystem(world: world))
    try s.build()
    return s
}

private struct Reference {
    var entity: CajuEntity
    var world: CajuMat4
    var collider: CajuCollider
}

/// Fase estreita independente do módulo: usa `CajuRay.intersects` do `CajuMath` no espaço local.
private func bruteRaycast(_ refs: [Reference], _ ray: CajuRay) -> (CajuEntity, Float)? {
    var best: (CajuEntity, Float)?
    for r in refs {
        guard let inv = r.world.inverseAffine else { continue }
        let o = inv.transformPoint(ray.origin)
        let d = inv.transformDirection(ray.direction)
        let local = CajuRay(origin: o, direction: d)
        let c = CajuVec3(storage: r.collider.center)
        let t: Float?
        switch r.collider.shape {
        case .box:
            t = local.intersects(CajuAABB(center: c, extents: CajuVec3(storage: r.collider.size)))
        case .sphere:
            t = local.intersects(CajuSphere(center: c, radius: r.collider.size.x))
        }
        if let t, best == nil || t < best!.1 { best = (r.entity, t) }
    }
    return best
}

private func buildScene(seed: UInt64, count: Int) throws -> (
    CajuWorld, CajuPhysicsScene, CajuScheduler, [Reference]
) {
    var rng = Rng(s: seed)
    let world = CajuWorld()
    let scene = try CajuPhysicsScene()
    let sched = try makeScheduler(world, scene)
    var parents: [CajuEntity] = []
    var specs: [(CajuEntity, CajuCollider)] = []
    for i in 0..<count {
        let parent: CajuEntity? =
            (i % 4 == 3 && !parents.isEmpty)
            ? parents[Int(rng.next() * Float(parents.count)) % parents.count] : nil
        let q =
            CajuQuat(
                axis: CajuVec3(rng.range(-1, 1), rng.range(-1, 1), rng.range(0.1, 1)),
                radians: rng.range(0, 6)) ?? .identity
        let isSphere = i % 3 == 0
        let s = isSphere ? CajuVec3(repeating: rng.range(0.5, 1.5)) : rng.vec(0.5, 1.5)
        let e = try world.spawnNode(
            CajuTransform(position: rng.vec(-20, 20), rotation: q, scale: s), parent: parent)
        parents.append(e)
        let collider: CajuCollider =
            isSphere
            ? .sphere(radius: rng.range(0.3, 1.0), center: rng.vec(-0.2, 0.2))
            : .box(halfExtents: rng.vec(0.3, 1.2), center: rng.vec(-0.2, 0.2))
        try world.insert(collider, into: e)
        specs.append((e, collider))
    }
    try sched.tick(delta: 1.0 / 60.0)
    let refs = specs.compactMap { e, c in
        world.globalMatrix(of: e).map { Reference(entity: e, world: $0, collider: c) }
    }
    return (world, scene, sched, refs)
}

@Suite("CajuPhysics consultas no ECS")
struct CajuPhysicsSceneTests {
    @Test func raycastMatchesBruteForceInHierarchicalWorld() throws {
        let (_, scene, _, refs) = try buildScene(seed: 0xC0FFEE, count: 300)
        #expect(scene.count == 300)
        var rng = Rng(s: 42)
        var hits = 0
        for _ in 0..<600 {
            let origin = rng.vec(-60, 60)
            let target = rng.vec(-20, 20)
            guard let ray = CajuRay(origin: origin, normalizingDirection: target - origin) else { continue }
            let expected = bruteRaycast(refs, ray)
            let got = scene.raycast(ray)
            #expect((got == nil) == (expected == nil))
            if let got, let expected {
                hits += 1
                #expect(abs(got.t - expected.1) < 1e-4 * (1 + expected.1))
                #expect(got.entity == expected.0)
                #expect(abs((got.point - ray.point(at: got.t)).length) < 1e-3)
                #expect(abs(got.normal.length - 1) < 1e-3)
            }
        }
        #expect(hits > 50)
    }

    @Test func raycastAllMatchesBruteForceCount() throws {
        let (_, scene, _, refs) = try buildScene(seed: 7, count: 120)
        var rng = Rng(s: 9)
        for _ in 0..<100 {
            let origin = rng.vec(-50, 50)
            guard let ray = CajuRay(origin: origin, normalizingDirection: rng.vec(-1, 1)) else { continue }
            var n = 0
            scene.raycastAll(ray) { _ in
                n += 1
                return true
            }
            var expected = 0
            for r in refs {
                let single = bruteRaycast([r], ray)
                if single != nil { expected += 1 }
            }
            #expect(n == expected)
        }
    }

    @Test func layerMaskAndMaxDistanceFilter() throws {
        let world = CajuWorld()
        let scene = try CajuPhysicsScene()
        let sched = try makeScheduler(world, scene)
        let a = try world.spawnNode(CajuTransform(position: CajuVec3(0, 0, 5)))
        let b = try world.spawnNode(CajuTransform(position: CajuVec3(0, 0, 10)))
        try world.insert(CajuCollider.sphere(radius: 1, layers: 0b01), into: a)
        try world.insert(CajuCollider.sphere(radius: 1, layers: 0b10), into: b)
        try sched.tick(delta: 0.016)
        let ray = CajuRay(origin: .zero, direction: CajuVec3(0, 0, 1))
        #expect(scene.raycast(ray)?.entity == a)
        #expect(scene.raycast(ray, layerMask: 0b10)?.entity == b)
        #expect(scene.raycast(ray, layerMask: 0b100) == nil)
        #expect(scene.raycast(ray, maxDistance: 3) == nil)
        let hit = try #require(scene.raycast(ray))
        #expect(abs(hit.t - 4) < 1e-4 && abs(hit.normal.z + 1) < 1e-4)
    }

    @Test func boxNormalAndInsideOrigin() throws {
        let world = CajuWorld()
        let scene = try CajuPhysicsScene()
        let sched = try makeScheduler(world, scene)
        let e = try world.spawnNode()
        try world.insert(CajuCollider.box(halfExtents: CajuVec3(1, 1, 1)), into: e)
        try sched.tick(delta: 0.016)
        let hit = try #require(
            scene.raycast(CajuRay(origin: CajuVec3(-5, 0, 0), direction: CajuVec3(1, 0, 0))))
        #expect(abs(hit.t - 4) < 1e-4 && abs(hit.normal.x + 1) < 1e-4)
        let inside = try #require(scene.raycast(CajuRay(origin: .zero, direction: CajuVec3(0, 1, 0))))
        #expect(inside.t == 0 && abs(inside.normal.y + 1) < 1e-4)
    }

    @Test func overlapSphereMatchesBruteForce() throws {
        let (_, scene, _, refs) = try buildScene(seed: 99, count: 200)
        var rng = Rng(s: 5)
        for _ in 0..<100 {
            let c = rng.vec(-20, 20)
            let r = rng.range(0.2, 4)
            var got = Set<CajuEntity>()
            scene.overlapSphere(CajuSphere(center: c, radius: r)) {
                got.insert($0)
                return true
            }
            var expected = Set<CajuEntity>()
            for ref in refs {
                guard let inv = ref.world.inverseAffine else { continue }
                let lc = inv.transformPoint(c)
                let hit: Bool
                switch ref.collider.shape {
                case .box:
                    let box = CajuAABB(
                        center: CajuVec3(storage: ref.collider.center),
                        extents: CajuVec3(storage: ref.collider.size))
                    let closest = lc.clamp(min: box.min, max: box.max)
                    hit = (ref.world.transformPoint(closest) - c).lengthSquared <= r * r
                case .sphere:
                    let wc = ref.world.transformPoint(CajuVec3(storage: ref.collider.center))
                    let sc = max(
                        ref.world.c0.xyzLength, max(ref.world.c1.xyzLength, ref.world.c2.xyzLength))
                    let rr = r + ref.collider.size.x * sc
                    hit = (wc - c).lengthSquared <= rr * rr
                }
                if hit { expected.insert(ref.entity) }
            }
            #expect(got == expected)
        }
    }

    @Test func spherecastHitsSphereAtExpectedTime() throws {
        let world = CajuWorld()
        let scene = try CajuPhysicsScene()
        let sched = try makeScheduler(world, scene)
        let e = try world.spawnNode(CajuTransform(position: CajuVec3(0, 0, 10)))
        try world.insert(CajuCollider.sphere(radius: 1), into: e)
        try sched.tick(delta: 0.016)
        let hit = try #require(
            scene.spherecast(
                CajuSphere(center: .zero, radius: 0.5), displacement: CajuVec3(0, 0, 20)))
        // contato quando a distância entre centros = 1.5 → z = 8.5 → t = 0.425
        #expect(hit.entity == e && abs(hit.t - 0.425) < 1e-4)
        #expect(
            scene.spherecast(CajuSphere(center: .zero, radius: 0.5), displacement: CajuVec3(0, 0, 5)) == nil)
    }

    @Test func syncTracksMoveDespawnAndRemoval() throws {
        let world = CajuWorld()
        let scene = try CajuPhysicsScene()
        let sched = try makeScheduler(world, scene)
        let e = try world.spawnNode(CajuTransform(position: CajuVec3(0, 0, 5)))
        try world.insert(CajuCollider.sphere(radius: 1), into: e)
        try sched.tick(delta: 0.016)
        let ray = CajuRay(origin: .zero, direction: CajuVec3(0, 0, 1))
        #expect(scene.raycast(ray)?.entity == e)
        // move para fora do raio
        _ = world.set(CajuTransform(position: CajuVec3(50, 0, 5)), on: e)
        try sched.tick(delta: 0.016)
        #expect(scene.raycast(ray) == nil && scene.count == 1)
        // remove o componente
        try world.remove(CajuCollider.self, from: e)
        try sched.tick(delta: 0.016)
        #expect(scene.count == 0)
        // despawn + reuso do índice com geração nova
        let f = try world.spawnNode(CajuTransform(position: CajuVec3(0, 0, 5)))
        try world.insert(CajuCollider.sphere(radius: 1), into: f)
        try sched.tick(delta: 0.016)
        #expect(scene.raycast(ray)?.entity == f)
        try world.despawnSubtree(f)
        try sched.tick(delta: 0.016)
        #expect(scene.count == 0 && scene.raycast(ray) == nil)
        let g = try world.spawnNode(CajuTransform(position: CajuVec3(0, 0, 8)))
        try world.insert(CajuCollider.box(halfExtents: CajuVec3(1, 1, 1)), into: g)
        try sched.tick(delta: 0.016)
        #expect(scene.raycast(ray)?.entity == g && scene.count == 1)
    }

    @Test func invalidColliderIsIgnored() throws {
        let world = CajuWorld()
        let scene = try CajuPhysicsScene()
        let sched = try makeScheduler(world, scene)
        let e = try world.spawnNode()
        try world.insert(CajuCollider(shape: .box, size: SIMD3(-1, 1, 1)), into: e)
        try sched.tick(delta: 0.016)
        #expect(scene.count == 0)
    }

    @Test func pickingFromPointerHitsObjectUnderTouch() throws {
        let world = CajuWorld()
        let scene = try CajuPhysicsScene()
        let sched = try makeScheduler(world, scene)
        let center = try world.spawnNode(CajuTransform(position: CajuVec3(0, 0, -10)))
        let right = try world.spawnNode(CajuTransform(position: CajuVec3(4, 0, -10)))
        try world.insert(CajuCollider.sphere(radius: 1), into: center)
        try world.insert(CajuCollider.sphere(radius: 1), into: right)
        try sched.tick(delta: 0.016)

        let view = CajuMat4.identity
        let proj = try #require(CajuMat4.perspective(fovY: .pi / 2, aspect: 2, near: 0.1, far: 100))
        let invVP = try #require((proj * view).inverse)
        let viewport = CajuVec2(800, 400)

        let tapCenter = CajuPointerEvent(
            pointerID: 1, phase: .began, position: CajuVec2(400, 200),
            timestamp: CajuTimestamp(nanoseconds: 0))
        let ray = try #require(
            CajuPicking.ray(event: tapCenter, viewportSize: viewport, inverseViewProjection: invVP))
        #expect(abs(ray.direction.z + 1) < 1e-3 && abs(ray.direction.x) < 1e-3)
        #expect(
            scene.pick(
                pointer: tapCenter.position, viewportSize: viewport, inverseViewProjection: invVP)?.entity
                == center)

        // x = 4 a z = -10: tan(45°)·aspect·10 = 20 → ndc.x = 0.2 → px = 480
        let hit = scene.pick(
            pointer: CajuVec2(480, 200), viewportSize: viewport, inverseViewProjection: invVP)
        #expect(hit?.entity == right)
        #expect(
            scene.pick(pointer: CajuVec2(10, 10), viewportSize: viewport, inverseViewProjection: invVP) == nil
        )
        #expect(
            CajuPicking.ray(pointer: .zero, viewportSize: CajuVec2(0, 0), inverseViewProjection: invVP) == nil
        )
    }

    @Test func kinematicMovesAndRotatesTransform() throws {
        let world = CajuWorld()
        let scene = try CajuPhysicsScene()
        let sched = try makeScheduler(world, scene)
        let e = try world.spawnNode()
        try world.insert(
            CajuKinematicBody(linearVelocity: SIMD3(2, 0, 0), angularVelocity: SIMD3(0, 0, .pi)), into: e)
        for _ in 0..<60 { try sched.tick(delta: 1.0 / 60.0) }
        let t = try #require(world.get(CajuTransform.self, of: e))
        #expect(abs(t.position.x - 2) < 1e-3)
        // 1 s a π rad/s em Z = 180°
        let r = t.rotation.rotate(CajuVec3(1, 0, 0))
        #expect(abs(r.x + 1) < 1e-3 && abs(r.y) < 1e-3)
        #expect(abs(t.rotation.storage.x) < 1e-3 && abs(Float(t.rotation.storage.w)) < 1e-3)
    }

    @Test func kinematicColliderIsTrackedBySceneAfterMove() throws {
        let world = CajuWorld()
        let scene = try CajuPhysicsScene()
        let sched = try makeScheduler(world, scene)
        let e = try world.spawnNode()
        try world.insert(CajuCollider.sphere(radius: 1), into: e)
        try world.insert(CajuKinematicBody(linearVelocity: SIMD3(0, 0, 10)), into: e)
        try sched.tick(delta: 1)
        let ray = CajuRay(origin: CajuVec3(0, 0, 0), direction: CajuVec3(0, 0, 1))
        let hit = try #require(scene.raycast(ray))
        #expect(abs(hit.t - 9) < 1e-3)
    }

    #if canImport(Darwin)
        /// Blocos de `malloc` em uso na zona padrão.
        private func blocksInUse() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Int(stats.blocks_in_use)
        }

        @Test func queriesDoNotAllocateOnHotPath() throws {
            let (_, scene, _, _) = try buildScene(seed: 1234, count: 200)
            var rng = Rng(s: 77)
            var rays: [CajuRay] = []
            for _ in 0..<64 {
                let o = rng.vec(-60, 60)
                rays.append(
                    CajuRay(origin: o, normalizingDirection: rng.vec(-20, 20) - o)
                        ?? CajuRay(origin: o, direction: CajuVec3(1, 0, 0)))
            }
            let sphere = CajuSphere(center: .zero, radius: 3)
            let inverse = try #require(
                (CajuMat4.perspective(fovY: 1, aspect: 1, near: 0.1, far: 100) ?? .identity).inverse)
            var sink = 0
            func run() {
                for r in rays {
                    if scene.raycast(r) != nil { sink += 1 }
                    scene.raycastAll(r) { _ in
                        sink += 1
                        return true
                    }
                }
                scene.overlapSphere(sphere) { _ in
                    sink += 1
                    return true
                }
                if scene.spherecast(sphere, displacement: CajuVec3(10, 0, 0)) != nil { sink += 1 }
                if scene.pick(
                    pointer: CajuVec2(10, 10), viewportSize: CajuVec2(100, 100),
                    inverseViewProjection: inverse) != nil
                {
                    sink += 1
                }
            }
            run()  // aquece (pilha de travessia)
            let before = blocksInUse()
            for _ in 0..<20 { run() }
            let after = blocksInUse()
            #expect(after - before <= 2, "consultas alocaram \(after - before) blocos")
            #expect(sink >= 0)
        }
    #endif
}

extension SIMD4 where Scalar == Float {
    fileprivate var xyzLength: Float { (x * x + y * y + z * z).squareRoot() }
}
