import CajuMath
import CajuPhysicsSpatial
import CajuTesting
import Testing

private let relTolerance: Float = 1e-4

private func close(_ a: Float, _ b: Float) -> Bool {
    abs(a - b) <= relTolerance * max(1, max(abs(a), abs(b)))
}

private func randomAABB(_ rng: inout CajuPCG32, range: ClosedRange<Float> = -20...20) throws -> CajuAABB {
    let p = SIMD3(
        rng.nextFloat(in: range),
        rng.nextFloat(in: range),
        rng.nextFloat(in: range)
    )
    let size = SIMD3(
        rng.nextFloat(in: 0.1...4.0),
        rng.nextFloat(in: 0.1...4.0),
        rng.nextFloat(in: 0.1...4.0)
    )
    return try CajuAABB(min: p, max: p + size)
}

private func randomRay(_ rng: inout CajuPCG32) throws -> CajuRay {
    let origin = SIMD3(
        rng.nextFloat(in: -30...30),
        rng.nextFloat(in: -30...30),
        rng.nextFloat(in: -30...30)
    )
    var dir = SIMD3(
        rng.nextFloat(in: -1...1),
        rng.nextFloat(in: -1...1),
        rng.nextFloat(in: -1...1)
    )
    if (dir * dir).sum() < 1e-4 {
        dir = SIMD3(1, 0.25, -0.5)
    }
    let tMax = rng.nextFloat(in: 5...80)
    return try CajuRay(origin: origin, direction: dir, tMin: 0, tMax: tMax)
}

@Suite("CajuAABB e CajuRay")
struct CajuAABBRayTests {
    @Test func rejectsNonFiniteAndInvalidBounds() {
        #expect(throws: CajuSpatialError.nonFiniteBounds) {
            _ = try CajuAABB(min: SIMD3(.nan, 0, 0), max: SIMD3(1, 1, 1))
        }
        #expect(throws: CajuSpatialError.nonFiniteBounds) {
            _ = try CajuAABB(min: SIMD3(0, 0, 0), max: SIMD3(1, .infinity, 1))
        }
        #expect(throws: CajuSpatialError.nonFiniteBounds) {
            _ = try CajuAABB(min: SIMD3(-.infinity, 0, 0), max: SIMD3(1, 1, 1))
        }
        #expect(throws: CajuSpatialError.invalidBounds) {
            _ = try CajuAABB(min: SIMD3(2, 0, 0), max: SIMD3(1, 1, 1))
        }
        #expect(throws: CajuSpatialError.invalidBounds) {
            _ = try CajuAABB(min: CajuVec3(0, 5, 0), max: CajuVec3(1, 4, 1))
        }
    }

    @Test func rejectsInvalidRays() {
        #expect(throws: CajuSpatialError.nonFiniteRay) {
            _ = try CajuRay(origin: SIMD3(.nan, 0, 0), direction: SIMD3(1, 0, 0))
        }
        #expect(throws: CajuSpatialError.nonFiniteRay) {
            _ = try CajuRay(origin: SIMD3(0, 0, 0), direction: SIMD3(1, .infinity, 0))
        }
        #expect(throws: CajuSpatialError.nonFiniteRay) {
            _ = try CajuRay(origin: SIMD3(0, 0, 0), direction: SIMD3(1, 0, 0), tMax: .infinity)
        }
        #expect(throws: CajuSpatialError.zeroDirectionRay) {
            _ = try CajuRay(origin: CajuVec3.zero, direction: CajuVec3.zero)
        }
        #expect(throws: CajuSpatialError.invalidRayRange) {
            _ = try CajuRay(origin: SIMD3.zero, direction: SIMD3(1, 0, 0), tMin: -0.1, tMax: 10)
        }
        #expect(throws: CajuSpatialError.invalidRayRange) {
            _ = try CajuRay(origin: SIMD3.zero, direction: SIMD3(1, 0, 0), tMin: 5, tMax: 2)
        }
    }

    @Test func aabbOperationsAndZeroVolume() throws {
        let point = try CajuAABB(min: SIMD3(1, 2, 1.5), max: SIMD3(1, 2, 1.5))
        #expect(point.surfaceArea == 0)
        #expect(point.center == SIMD3(1, 2, 1.5))
        #expect(point.contains(point))
        #expect(point.overlaps(point))

        let flat = try CajuAABB(min: SIMD3(0, 0, 0), max: SIMD3(2, 3, 0))
        #expect(flat.surfaceArea == 12)
        #expect(flat.center == SIMD3(1, 1.5, 0))

        let box = try CajuAABB(min: SIMD3(0, 0, 0), max: SIMD3(2, 2, 2))
        #expect(box.contains(point))
        #expect(box.contains(SIMD3(1, 2, 1.5)))
        #expect(box.overlaps(flat))

        // Raio tocando exatamente a aresta da caixa
        let edgeRay = try CajuRay(origin: SIMD3(-2, 0, 0), direction: SIMD3(1, 0, 0))
        let edgeHit = try #require(box.intersect(ray: edgeRay))
        #expect(close(edgeHit.tEnter, 2))
        #expect(close(edgeHit.tExit, 4))

        let grown = box.enlarged(margin: 0.5)
        #expect(grown.min == SIMD3(-0.5, -0.5, -0.5))
        #expect(grown.max == SIMD3(2.5, 2.5, 2.5))

        let shrunkToCenter = box.enlarged(margin: -5)
        #expect(shrunkToCenter.min == box.center)
        #expect(shrunkToCenter.max == box.center)
    }

    @Test func robustSlabHandlesParallelZeroInfAndInsideOrigin() throws {
        let box = try CajuAABB(min: SIMD3(0, 0, 0), max: SIMD3(2, 2, 2))

        // Origem dentro da caixa -> tEnter = 0
        let insideRay = try CajuRay(origin: SIMD3(1, 1, 1), direction: SIMD3(1, 0, 0))
        let insideHit = try #require(box.intersect(ray: insideRay))
        #expect(insideHit.tEnter == 0)
        #expect(close(insideHit.tExit, 1))

        // Raio paralelo exatamente na face mínima (0 * inf = NaN se não tratado)
        let onMinFace = try CajuRay(origin: SIMD3(0, 0, -3), direction: SIMD3(0, 0, 1))
        let minFaceHit = try #require(box.intersect(ray: onMinFace))
        #expect(close(minFaceHit.tEnter, 3))
        #expect(close(minFaceHit.tExit, 5))

        // Raio paralelo exatamente na face máxima com -0.0
        let onMaxFace = try CajuRay(origin: SIMD3(2, 2, -3), direction: SIMD3(-0.0, 0, 1))
        let maxFaceHit = try #require(box.intersect(ray: onMaxFace))
        #expect(close(maxFaceHit.tEnter, 3))
        #expect(close(maxFaceHit.tExit, 5))

        // Raio paralelo fora da caixa
        let outsideParallel = try CajuRay(origin: SIMD3(2.01, 1, -3), direction: SIMD3(0, 0, 1))
        #expect(box.intersect(ray: outsideParallel) == nil)

        // Caixa de volume zero (plano em z = 4)
        let plane = try CajuAABB(min: SIMD3(0, 0, 4), max: SIMD3(2, 2, 4))
        let hitPlane = try CajuRay(origin: SIMD3(1, 1, 0), direction: SIMD3(0, 0, 1))
        let planeRes = try #require(plane.intersect(ray: hitPlane))
        #expect(close(planeRes.tEnter, 4))
        #expect(close(planeRes.tExit, 4))

        // Raio paralelo coplanar dentro de caixa de volume zero
        let coplanar = try CajuRay(origin: SIMD3(-2, 1, 4), direction: SIMD3(1, 0, 0))
        let coplanarRes = try #require(plane.intersect(ray: coplanar))
        #expect(close(coplanarRes.tEnter, 2))
        #expect(close(coplanarRes.tExit, 4))
    }
}

@Suite("CajuBVH dinâmica")
struct CajuBVHTests {
    @Test func emptyAndSingleElementBVH() throws {
        var bvh = CajuBVH<UInt32>()
        #expect(bvh.isEmpty)
        #expect(bvh.count == 0)
        #expect(bvh.bounds == nil)
        #expect(bvh.validate())

        let ray = try CajuRay(origin: SIMD3(0, 0, -5), direction: SIMD3(0, 0, 1))
        #expect(bvh.raycastFirst(ray: ray) == nil)
        var visited = 0
        bvh.raycastAll(ray: ray) { _ in
            visited += 1
            return true
        }
        bvh.query(overlapping: try CajuAABB(min: .zero, max: SIMD3(1, 1, 1))) { _, _ in
            visited += 1
            return true
        }
        try bvh.query(sphereCenter: .zero, radius: 5) { _, _ in
            visited += 1
            return true
        }
        try bvh.query(
            sweptAABB: try CajuAABB(min: .zero, max: SIMD3(1, 1, 1)),
            displacement: SIMD3(1, 0, 0)
        ) { _ in
            visited += 1
            return true
        }
        #expect(visited == 0)

        let box = try CajuAABB(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1))
        let p = try bvh.insert(aabb: box, userData: 42)
        #expect(bvh.count == 1)
        #expect(bvh.validate())
        let hit = try #require(bvh.raycastFirst(ray: ray))
        #expect(hit.proxy == p)
        #expect(hit.userData == 42)
        #expect(close(hit.t, 4))

        let removedData = try bvh.remove(p)
        #expect(removedData == 42)
        #expect(bvh.isEmpty)
        #expect(bvh.validate())
    }

    @Test func invalidHandlesAndCapacityAndErrors() throws {
        var bvh = try CajuBVH<UInt32>(fatMargin: 0.2, maxCapacity: 2)
        let box = try CajuAABB(min: .zero, max: SIMD3(1, 1, 1))
        let p1 = try bvh.insert(aabb: box, userData: 1)
        let p2 = try bvh.insert(aabb: box, userData: 2)

        #expect(throws: CajuSpatialError.capacityExceeded) {
            _ = try bvh.insert(aabb: box, userData: 3)
        }

        // Remove p1 e reinsere para reutilizar o mesmo slot com geração incrementada
        _ = try bvh.remove(p1)
        let p3 = try bvh.insert(aabb: box, userData: 3)
        #expect(!bvh.contains(p1))
        #expect(bvh.contains(p2))
        #expect(bvh.contains(p3))

        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.remove(p1)
        }
        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.update(p1, aabb: box)
        }
        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.bounds(of: p1)
        }
        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.userData(for: p1)
        }

        // build(from:) invalida handles antigos
        let built = try bvh.build(from: [(aabb: box, userData: 10)])
        #expect(built.count == 1)
        #expect(!bvh.contains(p2))
        #expect(!bvh.contains(p3))
        #expect(bvh.validate())

        #expect(throws: CajuSpatialError.capacityExceeded) {
            _ = try bvh.build(from: [(box, 1), (box, 2), (box, 3)])
        }

        #expect(throws: CajuSpatialError.nonFiniteVector) {
            _ = try bvh.update(built[0], aabb: box, displacement: SIMD3(.nan, 0, 0))
        }
        #expect(throws: CajuSpatialError.nonFiniteSphere) {
            try bvh.query(sphereCenter: SIMD3(.infinity, 0, 0), radius: 1) { _, _ in true }
        }
        #expect(throws: CajuSpatialError.invalidRadius) {
            try bvh.query(sphereCenter: .zero, radius: -0.01) { _, _ in true }
        }
        #expect(throws: CajuSpatialError.invalidBounds) {
            _ = try CajuBVH<UInt32>(fatMargin: -0.1)
        }
    }

    @Test func fatAABBUpdateAvoidsReinsertInsideMarginAndReinsertsWhenEscaped() throws {
        var bvh = try CajuBVH<UInt32>(fatMargin: 0.5)
        let p = try bvh.insert(aabb: try CajuAABB(min: SIMD3(0, 0, 0), max: SIMD3(1, 1, 1)), userData: 99)

        // Movimento dentro da margem (fat = [-0.5, 1.5]) não reinserirá
        let movedInside = try CajuAABB(min: SIMD3(0.2, 0.2, 0.2), max: SIMD3(1.2, 1.2, 1.2))
        let reinserted1 = try bvh.update(p, aabb: movedInside)
        #expect(!reinserted1)
        #expect(try bvh.bounds(of: p) == movedInside)

        // Movimento além da margem deve reinserir
        let movedOutside = try CajuAABB(min: SIMD3(2, 2, 2), max: SIMD3(3, 3, 3))
        let reinserted2 = try bvh.update(p, aabb: movedOutside)
        #expect(reinserted2)
        #expect(try bvh.bounds(of: p) == movedOutside)
        #expect(bvh.validate())

        // Consultas devem refletir bounds exatos (não a AABB gorda)
        let missRay = try CajuRay(origin: SIMD3(1.7, 2.5, -2), direction: SIMD3(0, 0, 1))
        #expect(bvh.raycastFirst(ray: missRay) == nil)
        let hitRay = try CajuRay(origin: SIMD3(2.5, 2.5, -2), direction: SIMD3(0, 0, 1))
        #expect(bvh.raycastFirst(ray: hitRay)?.proxy == p)
    }

    @Test func identicalElementsAndDeepOverflowStack() throws {
        let identical = try CajuAABB(min: SIMD3(1, 1, 1), max: SIMD3(2, 2, 2))
        let items = (0..<200).map { (aabb: identical, userData: UInt32($0)) }

        var bvh = CajuBVH<UInt32>()
        let proxies = try bvh.build(from: items)
        #expect(proxies.count == 200)
        #expect(bvh.validate())

        let ray = try CajuRay(origin: SIMD3(1.5, 1.5, -3), direction: SIMD3(0, 0, 1))
        var hits: [UInt32] = []
        var stack = CajuBVHTraversalStack()
        bvh.raycastAll(ray: ray, stack: &stack) { hit in
            hits.append(hit.userData)
            return true
        }
        #expect(Set(hits) == Set(0..<200))

        // Parada antecipada no visitor
        var earlyCount = 0
        bvh.raycastAll(ray: ray, stack: &stack) { _ in
            earlyCount += 1
            return earlyCount < 5
        }
        #expect(earlyCount == 5)
    }

    @Test func fuzzQueriesAgainstBruteForceWithDynamicOps() throws {
        var bvh = try CajuBVH<UInt32>(fatMargin: 0.25)
        var truth: [UInt32: (proxy: CajuBVHProxy, aabb: CajuAABB)] = [:]
        var nextID: UInt32 = 1
        var stack = CajuBVHTraversalStack()

        var initRng = CajuPCG32(seed: 0xBEEF)
        var initialItems: [(aabb: CajuAABB, userData: UInt32)] = []
        for _ in 0..<48 {
            let box = try randomAABB(&initRng)
            initialItems.append((box, nextID))
            nextID += 1
        }
        let builtProxies = try bvh.build(from: initialItems)
        for (idx, item) in initialItems.enumerated() {
            truth[item.userData] = (builtProxies[idx], item.aabb)
        }
        #expect(bvh.validate())

        var keys = Array(truth.keys).sorted()
        try CajuFuzz.run(seed: 0x51A7, iterations: 10_000) { rng, iter in
            if iter % 4 == 0 {
                let op = rng.nextUInt32() % 5
                if op == 0 || truth.count < 16 {
                    let box = try randomAABB(&rng)
                    let id = nextID
                    nextID += 1
                    let proxy = try bvh.insert(aabb: box, userData: id)
                    truth[id] = (proxy, box)
                    keys.append(id)
                } else if op == 1, !keys.isEmpty {
                    let kIdx = Int(rng.nextUInt32() % UInt32(keys.count))
                    let id = keys.remove(at: kIdx)
                    if let entry = truth.removeValue(forKey: id) {
                        _ = try bvh.remove(entry.proxy)
                    }
                } else if !keys.isEmpty {
                    let kIdx = Int(rng.nextUInt32() % UInt32(keys.count))
                    let id = keys[kIdx]
                    if let entry = truth[id] {
                        let delta = SIMD3(
                            rng.nextFloat(in: -0.6...0.6),
                            rng.nextFloat(in: -0.6...0.6),
                            rng.nextFloat(in: -0.6...0.6)
                        )
                        let moved = try CajuAABB(min: entry.aabb.min + delta, max: entry.aabb.max + delta)
                        _ = try bvh.update(entry.proxy, aabb: moved, displacement: delta)
                        truth[id] = (entry.proxy, moved)
                    }
                }
                if iter % 200 == 0 {
                    bvh.refit()
                    #expect(bvh.validate())
                }
            }

            let kind = iter % 4
            if kind == 0 {
                let ray = try randomRay(&rng)
                let gotFirst = bvh.raycastFirst(ray: ray, stack: &stack)
                var bruteBestT = ray.tMax
                var bruteBestID: UInt32?
                for id in keys {
                    guard let entry = truth[id] else { continue }
                    if let hit = entry.aabb.intersect(ray: ray) {
                        if bruteBestID == nil || hit.tEnter < bruteBestT {
                            bruteBestT = hit.tEnter
                            bruteBestID = id
                        }
                    }
                }
                if let bruteBestID {
                    let got = try #require(gotFirst)
                    #expect(close(got.t, bruteBestT))
                    if let gotEntry = truth[got.userData] {
                        #expect(gotEntry.proxy == got.proxy)
                    } else {
                        Issue.record("Hit retornou userData inexistente \(got.userData)")
                    }
                    // Evita falso negativo apenas se houver empate exato numérico em t
                    if got.userData != bruteBestID {
                        let gotT = try #require(truth[got.userData]?.aabb.intersect(ray: ray)?.tEnter)
                        #expect(close(gotT, bruteBestT))
                    }
                } else {
                    #expect(gotFirst == nil)
                }

                var bvhAll: Set<CajuBVHProxy> = []
                bvh.raycastAll(ray: ray, stack: &stack) { hit in
                    bvhAll.insert(hit.proxy)
                    return true
                }
                var bruteAll: Set<CajuBVHProxy> = []
                for id in keys {
                    if let entry = truth[id], entry.aabb.intersect(ray: ray) != nil {
                        bruteAll.insert(entry.proxy)
                    }
                }
                #expect(bvhAll == bruteAll)
            } else if kind == 1 {
                let queryBox = try randomAABB(&rng, range: -22...22)
                var bvhSet: Set<CajuBVHProxy> = []
                bvh.query(overlapping: queryBox, stack: &stack) { proxy, _ in
                    bvhSet.insert(proxy)
                    return true
                }
                var bruteSet: Set<CajuBVHProxy> = []
                for id in keys {
                    if let entry = truth[id], entry.aabb.overlaps(queryBox) {
                        bruteSet.insert(entry.proxy)
                    }
                }
                #expect(bvhSet == bruteSet)
            } else if kind == 2 {
                let center = SIMD3(
                    rng.nextFloat(in: -22...22),
                    rng.nextFloat(in: -22...22),
                    rng.nextFloat(in: -22...22)
                )
                let radius = rng.nextFloat(in: 0.1...8.0)
                var bvhSet: Set<CajuBVHProxy> = []
                try bvh.query(sphereCenter: center, radius: radius, stack: &stack) { proxy, _ in
                    bvhSet.insert(proxy)
                    return true
                }
                var bruteSet: Set<CajuBVHProxy> = []
                for id in keys {
                    if let entry = truth[id],
                        entry.aabb.intersects(sphereCenter: center, radius: radius)
                    {
                        bruteSet.insert(entry.proxy)
                    }
                }
                #expect(bvhSet == bruteSet)
            } else {
                let sweptBox = try randomAABB(&rng, range: -15...15)
                let disp = SIMD3(
                    rng.nextFloat(in: -8...8),
                    rng.nextFloat(in: -8...8),
                    rng.nextFloat(in: -8...8)
                )
                var bvhHits: [CajuBVHProxy: Float] = [:]
                try bvh.query(sweptAABB: sweptBox, displacement: disp, stack: &stack) { hit in
                    bvhHits[hit.proxy] = hit.t
                    return true
                }
                var bruteHits: [CajuBVHProxy: Float] = [:]
                for id in keys {
                    guard let entry = truth[id] else { continue }
                    let expanded = try CajuAABB(
                        min: entry.aabb.min - sweptBox.max,
                        max: entry.aabb.max - sweptBox.min
                    )
                    let hitT: Float?
                    if disp == .zero {
                        hitT = sweptBox.overlaps(entry.aabb) ? 0 : nil
                    } else {
                        let ray = try CajuRay(origin: .zero, direction: disp, tMin: 0, tMax: 1)
                        hitT = expanded.intersect(ray: ray)?.tEnter
                    }
                    if let hitT {
                        bruteHits[entry.proxy] = hitT
                    }
                }
                #expect(Set(bvhHits.keys) == Set(bruteHits.keys))
                for (proxy, t) in bruteHits {
                    let gotT = try #require(bvhHits[proxy])
                    #expect(close(gotT, t))
                }
            }
        }
        #expect(bvh.validate())
    }
}
