import CajuMath
import CajuPhysicsSpatial
import CajuTesting
import Testing

private let fuzzIterations = 10_000
private let relTolerance: Float = 1e-4

private func closeRelative(_ a: Float, _ b: Float, tolerance: Float = relTolerance) -> Bool {
    abs(a - b) <= tolerance * max(1.0, abs(a), abs(b))
}

private func makeAABB(_ min: SIMD3<Float>, _ max: SIMD3<Float>) -> CajuAABB {
    CajuAABB(min: CajuVec3(storage: min), max: CajuVec3(storage: max))
}

private func makeSphere(_ center: SIMD3<Float>, _ radius: Float) -> CajuSphere {
    CajuSphere(center: CajuVec3(storage: center), radius: radius)
}

private func randomBox(_ rng: inout CajuPCG32, range: ClosedRange<Float> = -25...25) -> CajuAABB {
    let minP = SIMD3<Float>(
        rng.nextFloat(in: range),
        rng.nextFloat(in: range),
        rng.nextFloat(in: range)
    )
    let size = SIMD3<Float>(
        rng.nextUInt32() % 12 == 0 ? 0 : rng.nextFloat(in: 0.1...5.0),
        rng.nextUInt32() % 12 == 0 ? 0 : rng.nextFloat(in: 0.1...5.0),
        rng.nextUInt32() % 12 == 0 ? 0 : rng.nextFloat(in: 0.1...5.0)
    )
    return makeAABB(minP, minP + size)
}

private func randomRay(_ rng: inout CajuPCG32, range: ClosedRange<Float> = -35...35) throws -> CajuRayQuery {
    let origin = SIMD3<Float>(
        rng.nextFloat(in: range),
        rng.nextFloat(in: range),
        rng.nextFloat(in: range)
    )
    var dir = SIMD3<Float>(
        rng.nextFloat(in: -2...2),
        rng.nextFloat(in: -2...2),
        rng.nextFloat(in: -2...2)
    )
    let zeroPick = rng.nextUInt32() % 10
    if zeroPick == 0 { dir.x = 0 }
    if zeroPick == 1 { dir.y = 0 }
    if zeroPick == 2 { dir.z = 0 }
    if abs(dir.x) < 0.05 && dir.x != 0 { dir.x = dir.x >= 0 ? 0.5 : -0.5 }
    if abs(dir.y) < 0.05 && dir.y != 0 { dir.y = dir.y >= 0 ? 0.5 : -0.5 }
    if abs(dir.z) < 0.05 && dir.z != 0 { dir.z = dir.z >= 0 ? 0.5 : -0.5 }
    if dir == .zero { dir.x = 1 }

    let tMin = rng.nextUInt32() % 5 == 0 ? rng.nextFloat(in: 0.05...2.0) : 0
    let tMax = tMin + rng.nextFloat(in: 1.0...100.0)
    return try CajuRayQuery(origin: origin, direction: dir, tMin: tMin, tMax: tMax)
}

/// Oráculo em precisão dupla para raio x AABB (usado para detectar empates de borda).
private func doubleRayAABB(
    ray: CajuRayQuery,
    box: CajuAABB
) -> (hit: Bool, nearBoundary: Bool, t: Float) {
    var t0 = Double(ray.tMin)
    var t1 = Double(ray.tMax)
    var nearBoundary = false

    let o = [Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)]
    let d = [Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)]
    let bMin = [Double(box.min.x), Double(box.min.y), Double(box.min.z)]
    let bMax = [Double(box.max.x), Double(box.max.y), Double(box.max.z)]

    for axis in 0..<3 {
        let dir = d[axis]
        if abs(dir) == 0 {
            let eps = 1e-4 * max(1.0, abs(bMin[axis]), abs(bMax[axis]))
            if abs(o[axis] - bMin[axis]) < eps || abs(o[axis] - bMax[axis]) < eps {
                nearBoundary = true
            }
            if o[axis] < bMin[axis] || o[axis] > bMax[axis] {
                return (false, nearBoundary, 0)
            }
        } else {
            let inv = 1.0 / dir
            var near = (bMin[axis] - o[axis]) * inv
            var far = (bMax[axis] - o[axis]) * inv
            if near > far {
                swap(&near, &far)
            }
            t0 = max(t0, near)
            t1 = min(t1, far)
        }
    }

    let margin = 1e-4 * max(1.0, abs(t0), abs(t1))
    if abs(t0 - t1) < margin {
        nearBoundary = true
    }
    return (t0 <= t1, nearBoundary, Float(t0))
}

private func doubleSphereOverlapsAABB(
    center: SIMD3<Float>,
    radius: Float,
    box: CajuAABB
) -> (hit: Bool, nearBoundary: Bool) {
    let cx = max(Double(box.min.x), min(Double(center.x), Double(box.max.x)))
    let cy = max(Double(box.min.y), min(Double(center.y), Double(box.max.y)))
    let cz = max(Double(box.min.z), min(Double(center.z), Double(box.max.z)))
    let dx = Double(center.x) - cx
    let dy = Double(center.y) - cy
    let dz = Double(center.z) - cz
    let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
    let r = Double(radius)
    let margin = 1e-4 * max(1.0, r, dist)
    return (dist <= r, abs(dist - r) < margin)
}

private func doubleSweptAABB(
    moving: CajuAABB,
    displacement: SIMD3<Float>,
    target: CajuAABB
) -> (hit: Bool, nearBoundary: Bool, t: Float) {
    if displacement == .zero {
        let overlaps = moving.intersects(target)
        let nearX =
            abs(Double(moving.min.x) - Double(target.max.x)) < 1e-4
            || abs(Double(moving.max.x) - Double(target.min.x)) < 1e-4
        let nearY =
            abs(Double(moving.min.y) - Double(target.max.y)) < 1e-4
            || abs(Double(moving.max.y) - Double(target.min.y)) < 1e-4
        let nearZ =
            abs(Double(moving.min.z) - Double(target.max.z)) < 1e-4
            || abs(Double(moving.max.z) - Double(target.min.z)) < 1e-4
        return (overlaps, nearX || nearY || nearZ, 0)
    }

    var t0 = 0.0
    var t1 = 1.0
    var nearBoundary = false
    let d = [Double(displacement.x), Double(displacement.y), Double(displacement.z)]
    let mMin = [Double(moving.min.x), Double(moving.min.y), Double(moving.min.z)]
    let mMax = [Double(moving.max.x), Double(moving.max.y), Double(moving.max.z)]
    let tMin = [Double(target.min.x), Double(target.min.y), Double(target.min.z)]
    let tMax = [Double(target.max.x), Double(target.max.y), Double(target.max.z)]

    for axis in 0..<3 {
        let dir = d[axis]
        if abs(dir) == 0 {
            let eps = 1e-4 * max(1.0, abs(tMin[axis]), abs(tMax[axis]), abs(mMin[axis]), abs(mMax[axis]))
            if abs(mMax[axis] - tMin[axis]) < eps || abs(mMin[axis] - tMax[axis]) < eps {
                nearBoundary = true
            }
            if mMax[axis] < tMin[axis] || mMin[axis] > tMax[axis] {
                return (false, nearBoundary, 0)
            }
        } else {
            let inv = 1.0 / dir
            var a = (tMin[axis] - mMax[axis]) * inv
            var b = (tMax[axis] - mMin[axis]) * inv
            if a > b { swap(&a, &b) }
            t0 = max(t0, a)
            t1 = min(t1, b)
        }
    }

    if abs(t0 - t1) < 1e-4 {
        nearBoundary = true
    }
    return (t0 <= t1, nearBoundary, Float(t0))
}

@Suite("CajuBVH")
struct CajuPhysicsSpatialBVHTests {
    @Test func initValidationAndEmptyBVH() throws {
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            _ = try CajuBVH(fatMargin: .nan)
        }
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            _ = try CajuBVH(fatMargin: .infinity)
        }
        #expect(throws: CajuSpatialError.invalidRadius) {
            _ = try CajuBVH(fatMargin: -0.01)
        }
        #expect(throws: CajuSpatialError.capacityExceeded) {
            _ = try CajuBVH(maxCapacity: -1)
        }
        #expect(throws: CajuSpatialError.capacityExceeded) {
            _ = try CajuBVH(maxCapacity: Int(Int32.max))
        }

        var bvh = try CajuBVH()
        #expect(bvh.isEmpty)
        #expect(bvh.count == 0)
        #expect(bvh.bounds == nil)
        #expect(bvh.validate())

        let ray = try CajuRayQuery(origin: SIMD3<Float>(0, 0, -5), direction: SIMD3<Float>(0, 0, 1))
        #expect(bvh.raycastFirst(ray) == nil)

        var rayHits: [CajuBVHRayHit] = []
        var stack = CajuBVHTraversalStack()
        bvh.raycastAll(ray, into: &rayHits, stack: &stack)
        #expect(rayHits.isEmpty)

        let queryBox = makeAABB(SIMD3<Float>(-1, -1, -1), SIMD3<Float>(1, 1, 1))
        var overlapHits: [CajuBVHProxy] = []
        try bvh.query(overlapping: queryBox, into: &overlapHits, stack: &stack)
        #expect(overlapHits.isEmpty)

        var sphereCount = 0
        try bvh.shapecast(sphere: makeSphere(.zero, 5)) { _, _ in
            sphereCount += 1
            return true
        }
        #expect(sphereCount == 0)

        var sweptCount = 0
        try bvh.shapecast(swept: queryBox, displacement: SIMD3<Float>(1, 0, 0)) { _ in
            sweptCount += 1
            return true
        }
        #expect(sweptCount == 0)

        let builtEmpty = try bvh.build(from: [])
        #expect(builtEmpty.isEmpty)
        #expect(bvh.validate())
    }

    @Test func bvhRejectsInvalidAABBsInAllAPIs() throws {
        var bvh = try CajuBVH()
        let valid = makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        let proxy = try bvh.insert(bounds: valid, userData: 1)

        let nonFiniteBoxes = [
            makeAABB(SIMD3<Float>(.nan, 0, 0), SIMD3<Float>(1, 1, 1)),
            makeAABB(SIMD3<Float>(0, .infinity, 0), SIMD3<Float>(1, 1, 1)),
            makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, -.infinity)),
        ]
        let invertedBoxes = [
            makeAABB(SIMD3<Float>(2, 0, 0), SIMD3<Float>(1, 1, 1)),
            makeAABB(SIMD3<Float>(0, 2, 0), SIMD3<Float>(1, 1, 1)),
            makeAABB(SIMD3<Float>(0, 0, 2), SIMD3<Float>(1, 1, 1)),
        ]

        var stack = CajuBVHTraversalStack()
        var results: [CajuBVHProxy] = []

        for bad in nonFiniteBoxes {
            #expect(throws: CajuSpatialError.nonFiniteBounds) {
                _ = try bvh.insert(bounds: bad, userData: 2)
            }
            #expect(throws: CajuSpatialError.nonFiniteBounds) {
                _ = try bvh.update(proxy, bounds: bad)
            }
            #expect(throws: CajuSpatialError.nonFiniteBounds) {
                _ = try bvh.build(from: [(valid, 1), (bad, 2)])
            }
            #expect(throws: CajuSpatialError.nonFiniteBounds) {
                try bvh.query(overlapping: bad) { _, _ in true }
            }
            #expect(throws: CajuSpatialError.nonFiniteBounds) {
                try bvh.query(overlapping: bad, into: &results, stack: &stack)
            }
            #expect(throws: CajuSpatialError.nonFiniteBounds) {
                try bvh.shapecast(swept: bad, displacement: SIMD3<Float>(1, 0, 0)) { _ in true }
            }
            #expect(throws: CajuSpatialError.nonFiniteBounds) {
                try bvh.shapecast(swept: bad, displacement: .zero, stack: &stack) { _ in true }
            }
        }

        for bad in invertedBoxes {
            #expect(throws: CajuSpatialError.invalidBounds) {
                _ = try bvh.insert(bounds: bad, userData: 2)
            }
            #expect(throws: CajuSpatialError.invalidBounds) {
                _ = try bvh.update(proxy, bounds: bad)
            }
            #expect(throws: CajuSpatialError.invalidBounds) {
                _ = try bvh.build(from: [(valid, 1), (bad, 2)])
            }
            #expect(throws: CajuSpatialError.invalidBounds) {
                try bvh.query(overlapping: bad) { _, _ in true }
            }
            #expect(throws: CajuSpatialError.invalidBounds) {
                try bvh.query(overlapping: bad, into: &results, stack: &stack)
            }
            #expect(throws: CajuSpatialError.invalidBounds) {
                try bvh.shapecast(swept: bad, displacement: SIMD3<Float>(1, 0, 0)) { _ in true }
            }
            #expect(throws: CajuSpatialError.invalidBounds) {
                try bvh.shapecast(swept: bad, displacement: .zero, stack: &stack) { _ in true }
            }
        }

        // Falha de build não corrompe estado existente.
        #expect(bvh.count == 1)
        #expect(bvh.isValid(proxy))
        #expect(bvh.validate())
    }

    @Test func singleElementLifecycleUpdateRefitAndHandleReuse() throws {
        var bvh = try CajuBVH(fatMargin: 0.5, maxCapacity: 2)
        let box0 = makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        let p0 = try bvh.insert(bounds: box0, userData: 42)
        #expect(bvh.count == 1)
        #expect(!bvh.isEmpty)
        #expect(bvh.validate())
        #expect(bvh.isValid(p0))
        #expect(try bvh.bounds(for: p0) == box0)
        #expect(try bvh.userData(for: p0) == 42)

        // Movimento dentro da AABB gorda (margem 0.5): não reinserir.
        let smallMove = makeAABB(SIMD3<Float>(0.2, 0.1, 0), SIMD3<Float>(1.2, 1.1, 1))
        let reinsertedSmall = try bvh.update(p0, bounds: smallMove)
        #expect(!reinsertedSmall)
        #expect(try bvh.bounds(for: p0) == smallMove)
        #expect(bvh.validate())

        // Movimento que escapa da AABB gorda: reinserir com deslocamento.
        let farMove = makeAABB(SIMD3<Float>(10, 0, 0), SIMD3<Float>(11, 1, 1))
        let reinsertedFar = try bvh.update(
            p0,
            bounds: farMove,
            displacement: SIMD3<Float>(9.8, 0, 0)
        )
        #expect(reinsertedFar)
        #expect(try bvh.bounds(for: p0) == farMove)
        #expect(bvh.validate())

        bvh.refit()
        #expect(bvh.validate())

        let p1 = try bvh.insert(bounds: box0, userData: 99)
        #expect(bvh.count == 2)
        #expect(bvh.validate())

        // Capacidade máxima atingida.
        #expect(throws: CajuSpatialError.capacityExceeded) {
            _ = try bvh.insert(bounds: box0, userData: 100)
        }
        #expect(throws: CajuSpatialError.capacityExceeded) {
            _ = try bvh.build(from: [(box0, 1), (box0, 2), (box0, 3)])
        }

        // Remove p0 e reutiliza o slot; handle antigo p0 deve continuar inválido.
        try bvh.remove(p0)
        #expect(!bvh.isValid(p0))
        #expect(bvh.count == 1)
        #expect(bvh.validate())

        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.bounds(for: p0)
        }
        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.userData(for: p0)
        }
        #expect(throws: CajuSpatialError.invalidHandle) {
            try bvh.remove(p0)
        }
        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.update(p0, bounds: box0)
        }

        let p2 = try bvh.insert(bounds: box0, userData: 77)
        #expect(p2.index == p0.index)
        #expect(p2.generation != p0.generation)
        #expect(!bvh.isValid(p0))
        #expect(bvh.isValid(p2))
        #expect(bvh.validate())

        // clear() e build(from:) invalidam handles antigos e rejeitam consulta com invalidHandle.
        bvh.clear()
        #expect(!bvh.isValid(p1))
        #expect(!bvh.isValid(p2))
        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.bounds(for: p1)
        }
        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.userData(for: p2)
        }
        #expect(bvh.isEmpty)
        #expect(bvh.validate())

        // Handle de outra BVH com índice fora dos limites é rejeitado com invalidHandle.
        var otherBVH = try CajuBVH()
        var otherHandles: [CajuBVHProxy] = []
        for i in 0..<6 {
            otherHandles.append(try otherBVH.insert(bounds: box0, userData: UInt32(i)))
        }
        let outOfRangeHandle = otherHandles[5]
        #expect(!bvh.isValid(outOfRangeHandle))
        #expect(throws: CajuSpatialError.invalidHandle) {
            try bvh.remove(outOfRangeHandle)
        }
        #expect(throws: CajuSpatialError.invalidHandle) {
            _ = try bvh.update(outOfRangeHandle, bounds: box0)
        }

        let rebuilt = try bvh.build(from: [(box0, 10), (farMove, 20)])
        #expect(rebuilt.count == 2)
        #expect(bvh.validate())
        _ = try bvh.build(from: [(box0, 30)])
        #expect(!bvh.isValid(rebuilt[0]))
        #expect(!bvh.isValid(rebuilt[1]))
    }

    @Test func identicalElementsAndDeepTreeStackOverflow() throws {
        // Muitos elementos idênticos (mesma AABB).
        var bvh = try CajuBVH(fatMargin: 0.05)
        let sameBox = makeAABB(SIMD3<Float>(-1, -1, -1), SIMD3<Float>(1, 1, 1))
        let entries = (0..<80).map { (bounds: sameBox, userData: UInt32($0)) }
        let proxies = try bvh.build(from: entries)
        #expect(bvh.count == 80)
        #expect(bvh.validate())

        let ray = try CajuRayQuery(origin: SIMD3<Float>(0, 0, -5), direction: SIMD3<Float>(0, 0, 1))
        #expect(bvh.raycastFirst(ray)?.t == 4)
        var hits: [CajuBVHRayHit] = []
        var stack = CajuBVHTraversalStack()
        bvh.raycastAll(ray, into: &hits, stack: &stack)
        #expect(Set(hits.map(\.proxy)) == Set(proxies))

        var overlapSame: [CajuBVHProxy] = []
        try bvh.query(overlapping: sameBox, into: &overlapSame, stack: &stack)
        #expect(Set(overlapSame) == Set(proxies))

        var sphereSame = Set<CajuBVHProxy>()
        try bvh.shapecast(sphere: makeSphere(.zero, 0.5), stack: &stack) { proxy, _ in
            sphereSame.insert(proxy)
            return true
        }
        #expect(sphereSame == Set(proxies))

        let sweptProbe = makeAABB(SIMD3<Float>(-0.5, -0.5, -4), SIMD3<Float>(0.5, 0.5, -3))
        var sweptSame = Set<CajuBVHProxy>()
        try bvh.shapecast(swept: sweptProbe, displacement: SIMD3<Float>(0, 0, 5), stack: &stack) { hit in
            sweptSame.insert(hit.proxy)
            return true
        }
        #expect(sweptSame == Set(proxies))

        // Inserção em cadeia para forçar profundidade > 64 e testar overflow de CajuBVHTraversalStack.
        var deepBVH = try CajuBVH(fatMargin: 0.0)
        var deepProxies: [CajuBVHProxy] = []
        for i in 0..<150 {
            let x = Float(i) * 2.0
            let box = makeAABB(SIMD3<Float>(x, 0, 0), SIMD3<Float>(x + 1, 1, 1))
            deepProxies.append(try deepBVH.insert(bounds: box, userData: UInt32(i)))
        }
        #expect(deepBVH.validate())

        let wideQuery = makeAABB(SIMD3<Float>(-1, -1, -1), SIMD3<Float>(400, 2, 2))
        var visited: [CajuBVHProxy] = []
        try deepBVH.query(overlapping: wideQuery, into: &visited, stack: &stack)
        #expect(Set(visited) == Set(deepProxies))

        // Reuso da pilha após overflow deve funcionar normalmente.
        let singleQuery = makeAABB(SIMD3<Float>(19.5, 0, 0), SIMD3<Float>(21.5, 1, 1))
        visited.removeAll(keepingCapacity: true)
        try deepBVH.query(overlapping: singleQuery, into: &visited, stack: &stack)
        #expect(Set(visited) == [deepProxies[10]])
    }

    @Test func queryErrorsEarlyStopAndAnalyticalShapecasts() throws {
        var bvh = try CajuBVH(fatMargin: 0.1)
        let b0 = makeAABB(SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 2, 2))
        let b1 = makeAABB(SIMD3<Float>(4, 0, 0), SIMD3<Float>(6, 2, 2))
        let p0 = try bvh.insert(bounds: b0, userData: 1)
        let p1 = try bvh.insert(bounds: b1, userData: 2)

        // Erros tipados em update e shapecasts.
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            _ = try bvh.update(p0, bounds: b0, displacement: SIMD3<Float>(.nan, 0, 0))
        }
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            try bvh.shapecast(sphere: makeSphere(SIMD3<Float>(.infinity, 0, 0), 1)) { _, _ in true }
        }
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            try bvh.shapecast(sphere: makeSphere(.zero, .nan)) { _, _ in true }
        }
        #expect(throws: CajuSpatialError.invalidRadius) {
            try bvh.shapecast(sphere: makeSphere(.zero, -0.001)) { _, _ in true }
        }
        #expect(throws: CajuSpatialError.nonFiniteInput) {
            try bvh.shapecast(swept: b0, displacement: SIMD3<Float>(0, -.infinity, 0)) { _ in true }
        }

        // Visitor interrompendo cedo (retornando false).
        let ray = try CajuRayQuery(origin: SIMD3<Float>(-2, 1, 1), direction: SIMD3<Float>(1, 0, 0))
        var rayVisited = 0
        bvh.raycastAll(ray) { _ in
            rayVisited += 1
            return false
        }
        #expect(rayVisited == 1)

        let bigBox = makeAABB(SIMD3<Float>(-1, -1, -1), SIMD3<Float>(10, 10, 10))
        var overlapVisited = 0
        try bvh.query(overlapping: bigBox) { _, _ in
            overlapVisited += 1
            return false
        }
        #expect(overlapVisited == 1)

        var sphereVisited = 0
        try bvh.shapecast(sphere: makeSphere(SIMD3<Float>(3, 1, 1), 5)) { _, _ in
            sphereVisited += 1
            return false
        }
        #expect(sphereVisited == 1)

        var sweptVisited = 0
        let mover = makeAABB(SIMD3<Float>(-2, 0.5, 0.5), SIMD3<Float>(-1, 1.5, 1.5))
        try bvh.shapecast(swept: mover, displacement: SIMD3<Float>(10, 0, 0)) { _ in
            sweptVisited += 1
            return false
        }
        #expect(sweptVisited == 1)

        // Casos analíticos de esfera e swept AABB.
        var sphereHits: [CajuBVHProxy] = []
        // Esfera tocando exatamente a face x = 2 de b0 (centro (3, 1, 1), raio 1) e x = 4 de b1.
        try bvh.shapecast(sphere: makeSphere(SIMD3<Float>(3, 1, 1), 1)) { proxy, _ in
            sphereHits.append(proxy)
            return true
        }
        #expect(sphereHits.count == 2)

        // Esfera raio 0 dentro de b0 vs fora.
        sphereHits.removeAll()
        try bvh.shapecast(sphere: makeSphere(SIMD3<Float>(1, 1, 1), 0)) { proxy, _ in
            sphereHits.append(proxy)
            return true
        }
        #expect(sphereHits == [p0])

        sphereHits.removeAll()
        try bvh.shapecast(sphere: makeSphere(SIMD3<Float>(2.01, 1, 1), 0)) { proxy, _ in
            sphereHits.append(proxy)
            return true
        }
        #expect(sphereHits.isEmpty)

        // Swept AABB atingindo b0 em t = 0.2 e tocando exatamente b1 em t = 1.0 (deslocamento 5).
        var sweptHits: [CajuBVHSweptHit] = []
        try bvh.shapecast(swept: mover, displacement: SIMD3<Float>(5, 0, 0)) { hit in
            sweptHits.append(hit)
            return true
        }
        #expect(sweptHits.count == 2)
        let byProxy = Dictionary(uniqueKeysWithValues: sweptHits.map { ($0.proxy, $0.t) })
        #expect(closeRelative(try #require(byProxy[p0]), 0.2))
        #expect(closeRelative(try #require(byProxy[p1]), 1.0))

        // Deslocamento 4 atinge apenas b0 em t = 0.25 (para antes de b1).
        sweptHits.removeAll()
        try bvh.shapecast(swept: mover, displacement: SIMD3<Float>(4, 0, 0)) { hit in
            sweptHits.append(hit)
            return true
        }
        #expect(sweptHits.count == 1)
        let onlySwept = try #require(sweptHits.first)
        #expect(onlySwept.proxy == p0)
        #expect(closeRelative(onlySwept.t, 0.25))

        // Swept com deslocamento zero quando já sobrepõe b0.
        let overlappingMover = makeAABB(
            SIMD3<Float>(0.5, 0.5, 0.5),
            SIMD3<Float>(1.5, 1.5, 1.5)
        )
        sweptHits.removeAll()
        try bvh.shapecast(swept: overlappingMover, displacement: .zero) { hit in
            sweptHits.append(hit)
            return true
        }
        #expect(sweptHits.count == 1)
        #expect(sweptHits[0].proxy == p0)
        #expect(sweptHits[0].t == 0)
    }

    @Test func singleElementZeroVolumeAndInsideOriginQueries() throws {
        var bvh = try CajuBVH(fatMargin: 0.1)
        let pointBox = makeAABB(SIMD3<Float>(2, 3, 4), SIMD3<Float>(2, 3, 4))
        let pPoint = try bvh.insert(bounds: pointBox, userData: 11)
        #expect(bvh.validate())

        // 1 elemento (volume zero): todas as consultas e sobrecargas sem pilha.
        let toPoint = try CajuRayQuery(origin: SIMD3<Float>(0, 3, 4), direction: SIMD3<Float>(1, 0, 0))
        let firstPoint = try #require(bvh.raycastFirst(toPoint))
        #expect(firstPoint.proxy == pPoint)
        #expect(firstPoint.userData == 11)
        #expect(firstPoint.t == 2)

        var allPoint: [CajuBVHProxy] = []
        bvh.raycastAll(toPoint) { hit in
            allPoint.append(hit.proxy)
            return true
        }
        #expect(allPoint == [pPoint])

        var overlapPoint: [CajuBVHProxy] = []
        try bvh.query(overlapping: pointBox) { proxy, _ in
            overlapPoint.append(proxy)
            return true
        }
        #expect(overlapPoint == [pPoint])

        var spherePoint: [CajuBVHProxy] = []
        try bvh.shapecast(sphere: makeSphere(SIMD3<Float>(2, 3, 5), 1)) { proxy, _ in
            spherePoint.append(proxy)
            return true
        }
        #expect(spherePoint == [pPoint])

        let mover = makeAABB(SIMD3<Float>(-1, 2.5, 3.5), SIMD3<Float>(0, 3.5, 4.5))
        var sweptPoint: [CajuBVHSweptHit] = []
        try bvh.shapecast(swept: mover, displacement: SIMD3<Float>(4, 0, 0)) { hit in
            sweptPoint.append(hit)
            return true
        }
        #expect(sweptPoint.count == 1)
        #expect(sweptPoint[0].proxy == pPoint)
        #expect(closeRelative(sweptPoint[0].t, 0.5))

        // Plano de volume zero + origem de raio dentro de uma AABB.
        bvh.clear()
        let flatBox = makeAABB(SIMD3<Float>(0, 0, 5), SIMD3<Float>(4, 4, 5))
        let solidBox = makeAABB(SIMD3<Float>(-2, -2, -2), SIMD3<Float>(2, 2, 2))
        let pFlat = try bvh.insert(bounds: flatBox, userData: 1)
        let pSolid = try bvh.insert(bounds: solidBox, userData: 2)

        let insideRay = try CajuRayQuery(origin: SIMD3<Float>(1, 1, 0), direction: SIMD3<Float>(0, 0, 1))
        let insideFirst = try #require(bvh.raycastFirst(insideRay))
        #expect(insideFirst.proxy == pSolid)
        #expect(insideFirst.t == 0)

        var stack = CajuBVHTraversalStack()
        var bothHits: [CajuBVHRayHit] = []
        bvh.raycastAll(insideRay, into: &bothHits, stack: &stack)
        #expect(Set(bothHits.map(\.proxy)) == [pSolid, pFlat])
    }

    @Test func staticSAHBVHMatchesBruteForceFuzz() throws {
        var bvh = try CajuBVH(fatMargin: 0.05)
        var entries: [(proxy: CajuBVHProxy, bounds: CajuAABB, userData: UInt32)] = []
        var stack = CajuBVHTraversalStack()

        try CajuFuzz.run(seed: 0xB740_0001, iterations: fuzzIterations) { rng, i in
            if i % 40 == 0 {
                let count = Int(rng.nextUInt32() % 24) + 1
                var input: [(bounds: CajuAABB, userData: UInt32)] = []
                input.reserveCapacity(count)
                for idx in 0..<count {
                    input.append((randomBox(&rng), UInt32(idx)))
                }
                let handles = try bvh.build(from: input)
                #expect(bvh.validate())
                entries.removeAll(keepingCapacity: true)
                for idx in 0..<count {
                    entries.append((handles[idx], input[idx].bounds, input[idx].userData))
                }
            }

            // 1. Raycast first & all vs força bruta.
            let ray = try randomRay(&rng)
            var nearRayBoundary = false
            var expectedRayHits: [CajuBVHProxy: Float] = [:]
            var expectedBestT = Float.greatestFiniteMagnitude
            var expectedSecondT = Float.greatestFiniteMagnitude

            for entry in entries {
                let oracle = doubleRayAABB(ray: ray, box: entry.bounds)
                if oracle.nearBoundary {
                    nearRayBoundary = true
                    break
                }
                if oracle.hit {
                    expectedRayHits[entry.proxy] = oracle.t
                    if oracle.t < expectedBestT {
                        expectedSecondT = expectedBestT
                        expectedBestT = oracle.t
                    } else if oracle.t < expectedSecondT {
                        expectedSecondT = oracle.t
                    }
                }
            }

            if !nearRayBoundary {
                var actualRayHits: [CajuBVHRayHit] = []
                bvh.raycastAll(ray, into: &actualRayHits, stack: &stack)
                #expect(Set(actualRayHits.map(\.proxy)) == Set(expectedRayHits.keys))
                for hit in actualRayHits {
                    let expectedT = try #require(expectedRayHits[hit.proxy])
                    #expect(closeRelative(hit.t, expectedT))
                }

                let firstHit = bvh.raycastFirst(ray, stack: &stack)
                if expectedRayHits.isEmpty {
                    #expect(firstHit == nil)
                } else {
                    let hit = try #require(firstHit)
                    #expect(closeRelative(hit.t, expectedBestT))
                    if expectedSecondT - expectedBestT > 1e-3 * max(1, expectedBestT) {
                        let expectedWinner = expectedRayHits.min { $0.value < $1.value }?.key
                        #expect(hit.proxy == expectedWinner)
                    }
                }
            }

            // 2. Overlap AABB vs força bruta (comparação exata).
            let queryBox = randomBox(&rng, range: -30...30)
            let expectedOverlap = Set(
                entries.compactMap { $0.bounds.intersects(queryBox) ? $0.proxy : nil }
            )
            var actualOverlap: [CajuBVHProxy] = []
            try bvh.query(overlapping: queryBox, into: &actualOverlap, stack: &stack)
            #expect(Set(actualOverlap) == expectedOverlap)

            // 3. Shapecast esfera vs força bruta em Double.
            let center = SIMD3<Float>(
                rng.nextFloat(in: -30...30),
                rng.nextFloat(in: -30...30),
                rng.nextFloat(in: -30...30)
            )
            let radius = rng.nextFloat(in: 0.1...10.0)
            var nearSphereBoundary = false
            var expectedSphere = Set<CajuBVHProxy>()
            for entry in entries {
                let oracle = doubleSphereOverlapsAABB(center: center, radius: radius, box: entry.bounds)
                if oracle.nearBoundary {
                    nearSphereBoundary = true
                    break
                }
                if oracle.hit {
                    expectedSphere.insert(entry.proxy)
                }
            }
            if !nearSphereBoundary {
                var actualSphere = Set<CajuBVHProxy>()
                try bvh.shapecast(sphere: makeSphere(center, radius), stack: &stack) { proxy, _ in
                    actualSphere.insert(proxy)
                    return true
                }
                #expect(actualSphere == expectedSphere)
            }

            // 4. Shapecast swept AABB vs força bruta em Double.
            let mover = randomBox(&rng, range: -15...15)
            let disp =
                rng.nextUInt32() % 10 == 0
                ? SIMD3<Float>.zero
                : SIMD3<Float>(
                    rng.nextFloat(in: -10...10),
                    rng.nextFloat(in: -10...10),
                    rng.nextFloat(in: -10...10)
                )
            var nearSweptBoundary = false
            var expectedSwept: [CajuBVHProxy: Float] = [:]
            for entry in entries {
                let oracle = doubleSweptAABB(moving: mover, displacement: disp, target: entry.bounds)
                if oracle.nearBoundary {
                    nearSweptBoundary = true
                    break
                }
                if oracle.hit {
                    expectedSwept[entry.proxy] = oracle.t
                }
            }
            if !nearSweptBoundary {
                var actualSwept: [CajuBVHProxy: Float] = [:]
                try bvh.shapecast(swept: mover, displacement: disp, stack: &stack) { hit in
                    actualSwept[hit.proxy] = hit.t
                    return true
                }
                #expect(Set(actualSwept.keys) == Set(expectedSwept.keys))
                for (proxy, actualT) in actualSwept {
                    let expectedT = try #require(expectedSwept[proxy])
                    #expect(closeRelative(actualT, expectedT))
                }
            }
        }
    }

    @Test func dynamicMutationsMaintainInvariantsAndMatchBruteForceFuzz() throws {
        var bvh = try CajuBVH(fatMargin: 0.25)
        var mirror: [CajuBVHProxy: (bounds: CajuAABB, userData: UInt32)] = [:]
        var activeList: [CajuBVHProxy] = []
        var removedList: [CajuBVHProxy] = []
        var stack = CajuBVHTraversalStack()
        var nextTag: UInt32 = 1

        try CajuFuzz.run(seed: 0xD41A_0002, iterations: fuzzIterations) { rng, step in
            let op = rng.nextUInt32() % 100
            if activeList.isEmpty || (op < 35 && activeList.count < 48) {
                let box = randomBox(&rng, range: -20...20)
                let tag = nextTag
                nextTag &+= 1
                let proxy = try bvh.insert(bounds: box, userData: tag)
                mirror[proxy] = (box, tag)
                activeList.append(proxy)
            } else if op < 55 {
                let idx = Int(rng.nextUInt32()) % activeList.count
                let proxy = activeList.swapRemove(at: idx)
                try bvh.remove(proxy)
                mirror.removeValue(forKey: proxy)
                if removedList.count < 16 {
                    removedList.append(proxy)
                }
            } else if op < 95 {
                let idx = Int(rng.nextUInt32()) % activeList.count
                let proxy = activeList[idx]
                let old = try #require(mirror[proxy])
                let largeJump = rng.nextUInt32() % 3 == 0
                let delta =
                    largeJump
                    ? SIMD3<Float>(
                        rng.nextFloat(in: -5...5),
                        rng.nextFloat(in: -5...5),
                        rng.nextFloat(in: -5...5)
                    )
                    : SIMD3<Float>(
                        rng.nextFloat(in: -0.05...0.05),
                        rng.nextFloat(in: -0.05...0.05),
                        rng.nextFloat(in: -0.05...0.05)
                    )
                let moved = makeAABB(old.bounds.min.storage + delta, old.bounds.max.storage + delta)
                _ = try bvh.update(proxy, bounds: moved, displacement: delta)
                mirror[proxy] = (moved, old.userData)
            } else if op < 99 {
                bvh.refit()
            } else {
                let rebuiltEntries = activeList.compactMap { proxy in
                    mirror[proxy].map { (bounds: $0.bounds, userData: $0.userData) }
                }
                let newHandles = try bvh.build(from: rebuiltEntries)
                mirror.removeAll(keepingCapacity: true)
                activeList.removeAll(keepingCapacity: true)
                for (handle, entry) in zip(newHandles, rebuiltEntries) {
                    mirror[handle] = entry
                    activeList.append(handle)
                }
                removedList.removeAll(keepingCapacity: true)
            }

            #expect(bvh.count == mirror.count)
            #expect(bvh.validate())

            if let stale = removedList.first {
                #expect(!bvh.isValid(stale))
            }

            // Verifica consultas contra o espelho de força bruta a cada passo.
            let ray = try randomRay(&rng, range: -25...25)
            var nearRayBoundary = false
            var expectedRayHits: [CajuBVHProxy: Float] = [:]
            var expectedBestT = Float.greatestFiniteMagnitude
            for (proxy, entry) in mirror {
                let oracle = doubleRayAABB(ray: ray, box: entry.bounds)
                if oracle.nearBoundary {
                    nearRayBoundary = true
                    break
                }
                if oracle.hit {
                    expectedRayHits[proxy] = oracle.t
                    expectedBestT = min(expectedBestT, oracle.t)
                }
            }
            if !nearRayBoundary {
                var actualRay: [CajuBVHRayHit] = []
                bvh.raycastAll(ray, into: &actualRay, stack: &stack)
                #expect(Set(actualRay.map(\.proxy)) == Set(expectedRayHits.keys))

                let firstHit = bvh.raycastFirst(ray, stack: &stack)
                if expectedRayHits.isEmpty {
                    #expect(firstHit == nil)
                } else {
                    let hit = try #require(firstHit)
                    #expect(closeRelative(hit.t, expectedBestT))
                }
            }

            let qBox = randomBox(&rng, range: -25...25)
            let expectedOverlap = Set(
                mirror.compactMap { $0.value.bounds.intersects(qBox) ? $0.key : nil }
            )
            var actualOverlap: [CajuBVHProxy] = []
            try bvh.query(overlapping: qBox, into: &actualOverlap, stack: &stack)
            #expect(Set(actualOverlap) == expectedOverlap)

            let center = SIMD3<Float>(
                rng.nextFloat(in: -25...25),
                rng.nextFloat(in: -25...25),
                rng.nextFloat(in: -25...25)
            )
            let radius = rng.nextFloat(in: 0.2...8.0)
            var nearSphereBoundary = false
            var expectedSphere = Set<CajuBVHProxy>()
            for (proxy, entry) in mirror {
                let oracle = doubleSphereOverlapsAABB(
                    center: center,
                    radius: radius,
                    box: entry.bounds
                )
                if oracle.nearBoundary {
                    nearSphereBoundary = true
                    break
                }
                if oracle.hit {
                    expectedSphere.insert(proxy)
                }
            }
            if !nearSphereBoundary {
                var actualSphere = Set<CajuBVHProxy>()
                try bvh.shapecast(sphere: makeSphere(center, radius), stack: &stack) { proxy, _ in
                    actualSphere.insert(proxy)
                    return true
                }
                #expect(actualSphere == expectedSphere)
            }

            let mover = randomBox(&rng, range: -15...15)
            let disp =
                rng.nextUInt32() % 10 == 0
                ? SIMD3<Float>.zero
                : SIMD3<Float>(
                    rng.nextFloat(in: -10...10),
                    rng.nextFloat(in: -10...10),
                    rng.nextFloat(in: -10...10)
                )
            var nearSweptBoundary = false
            var expectedSwept: [CajuBVHProxy: Float] = [:]
            for (proxy, entry) in mirror {
                let oracle = doubleSweptAABB(moving: mover, displacement: disp, target: entry.bounds)
                if oracle.nearBoundary {
                    nearSweptBoundary = true
                    break
                }
                if oracle.hit {
                    expectedSwept[proxy] = oracle.t
                }
            }
            if !nearSweptBoundary {
                var actualSwept: [CajuBVHProxy: Float] = [:]
                try bvh.shapecast(swept: mover, displacement: disp, stack: &stack) { hit in
                    actualSwept[hit.proxy] = hit.t
                    return true
                }
                #expect(Set(actualSwept.keys) == Set(expectedSwept.keys))
                for (proxy, actualT) in actualSwept {
                    let expectedT = try #require(expectedSwept[proxy])
                    #expect(closeRelative(actualT, expectedT))
                }
            }
        }
    }
}

extension Array {
    fileprivate mutating func swapRemove(at index: Int) -> Element {
        if index != count - 1 {
            swapAt(index, count - 1)
        }
        return removeLast()
    }
}
