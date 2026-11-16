// Harness de benchmark do Caju (M0). Saída em JSON no stdout para versionar e comparar no CI.
// Uso: swift run -c release caju-bench
import CajuAssets
import CajuCore
import CajuMath
import CajuPhysicsSpatial
import CajuRender
import CajuScene
import CajuUILayout

#if canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    import Android
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    import Musl
#endif

struct Result {
    let name: String
    let iterations: Int
    let nanosecondsPerOp: Double
}

/// Mede `body` por `iterations` repetições, após uma rodada de aquecimento.
/// Devolve a menor de 5 amostras (menos ruído).
func measure(_ name: String, iterations: Int, _ body: (Int) -> Float) -> Result {
    var sink: Float = 0
    for i in 0..<(iterations / 10) { sink += body(i) }
    var best = Double.infinity
    let clock = ContinuousClock()
    for _ in 0..<5 {
        let elapsed = clock.measure {
            for i in 0..<iterations { sink += body(i) }
        }
        let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
        best = min(best, ns / Double(iterations))
    }
    // Impede que o otimizador remova o laço.
    if sink == 12345.678 { print("") }
    return Result(name: name, iterations: iterations, nanosecondsPerOp: best)
}

let q = CajuQuat(axis: CajuVec3(1, 2, 3), radians: 0.7) ?? .identity
let m = CajuMat4.rotation(q) * CajuMat4.translation(CajuVec3(1, 2, 3))
let n = 1_000_000
let benchBox = CajuAABB(min: CajuVec3(0, 0, 0), max: CajuVec3(8, 1, 1))
let benchA = CajuVec3(0, 0, 0)
let benchB = CajuVec3(1, 0, 0)
let benchC = CajuVec3(0, 1, 0)

/// Árvore de UI de ~1 000 nós (50 linhas × 19 folhas + `Spacer`) para o NFR-009.
func makeLayoutTree() -> CajuLayoutTree {
    var tree = CajuLayoutTree(capacity: 1_100)
    guard let root = try? tree.add(.vStack(spacing: 2)) else { return tree }
    for _ in 0..<50 {
        guard let row = try? tree.add(.hStack(spacing: 2), to: root) else { continue }
        for column in 0..<19 {
            if column == 9 { _ = try? tree.add(.spacer(), to: row) }
            _ = try? tree.add(.leaf(.fixed(CajuVec2(20, 20))), to: row)
        }
    }
    return tree
}
var layoutTree = makeLayoutTree()
layoutTree.layout(in: CajuVec2(1000, 2000))

let mathResults = [
    measure("vec3.cross", iterations: n) { i in
        let a = CajuVec3(Float(i & 7), 1, 2)
        return a.cross(CajuVec3(3, Float(i & 3), 1)).x
    },
    measure("quat.rotate", iterations: n) { i in
        q.rotate(CajuVec3(Float(i & 7), 1, 2)).y
    },
    measure("mat4.mul", iterations: n) { i in
        (m * CajuMat4.translation(CajuVec3(Float(i & 7), 0, 0))).c3.x
    },
    measure("mat4.inverse", iterations: n) { i in
        let a = m * CajuMat4.translation(CajuVec3(Float(i & 7), 0, 0))
        return a.inverse?.c3.x ?? 0
    },
    measure("mat4.inverseAffine", iterations: n) { i in
        let a = m * CajuMat4.translation(CajuVec3(Float(i & 7), 0, 0))
        return a.inverseAffine?.c3.x ?? 0
    },
    measure("quat.slerp", iterations: n) { i in
        CajuQuat.slerp(.identity, q, t: Float(i & 15) / 16).x
    },
    measure("ray.intersects(aabb)", iterations: n) { i in
        let ray = CajuRay(origin: CajuVec3(Float(i & 7), -5, 0.5), direction: CajuVec3(0, 1, 0))
        return ray.intersects(benchBox) ?? 0
    },
    measure("ray.intersectsTriangle", iterations: n) { i in
        let ray = CajuRay(origin: CajuVec3(0.1 + Float(i & 3) * 0.1, 0.2, -1), direction: CajuVec3(0, 0, 1))
        return ray.intersectsTriangle(benchA, benchB, benchC, backfaceCulling: false)?.t ?? 0
    },
]

let layoutResults = [
    // Relayout completo (árvore invalidada a cada iteração) de ~1 000 nós.
    measure("uilayout.relayout_1000_nodes", iterations: 2_000) { i in
        layoutTree.invalidate()
        layoutTree.layout(in: CajuVec2(1000, 2000))
        return Float(i & 1)
    }
]

// MARK: ECS (NFR-008: ≥ 100 000 entidades × 3 componentes por consulta em < 2 ms no aparelho alto (?))

struct BPos: CajuComponent {
    static let componentID = CajuComponentID(20)
    var x: Float, y: Float, z: Float
}
struct BVel: CajuComponent {
    static let componentID = CajuComponentID(21)
    var x: Float, y: Float, z: Float
}
struct BMass: CajuComponent {
    static let componentID = CajuComponentID(22)
    var m: Float
}

/// Mede `ops` operações por passada de `body` (menor de 5 passadas, após 1 de aquecimento).
func measureBatch(_ name: String, ops: Int, _ body: () -> Float) -> Result {
    var sink = body()
    var best = Double.infinity
    let clock = ContinuousClock()
    for _ in 0..<5 {
        let elapsed = clock.measure { sink += body() }
        let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
        best = min(best, ns / Double(ops))
    }
    if sink == 12345.678 { print("") }
    return Result(name: name, iterations: ops, nanosecondsPerOp: best)
}

let entities = 100_000
let world = CajuWorld()
world.reserve(entities: entities)
var ecsResults: [Result] = []
do {
    let spawnWorld = CajuWorld()
    spawnWorld.reserve(entities: 1_000_000)
    ecsResults.append(
        measureBatch("ecs.spawn(3 componentes)", ops: 1_000_000) {
            for i in 0..<1_000_000 {
                _ = try? spawnWorld.spawn(BPos(x: Float(i), y: 0, z: 0), BVel(x: 1, y: 1, z: 1), BMass(m: 1))
            }
            return Float(spawnWorld.entityCount)
        })
    for i in 0..<entities {
        _ = try? world.spawn(BPos(x: Float(i), y: 0, z: 0), BVel(x: 1, y: 1, z: 1), BMass(m: 1))
    }
    ecsResults.append(
        measureBatch("ecs.query.arity3(100k)", ops: entities) {
            var acc: Float = 0
            world.forEach(CajuWrite<BPos>.self, CajuRead<BVel>.self, CajuRead<BMass>.self) { p, v, m in
                p.value.x += v.x * m.m * 0.016
                acc += p.value.x
            }
            return acc
        })
    ecsResults.append(
        measureBatch("ecs.query.pack3(100k)", ops: entities) {
            var acc: Float = 0
            world.forEachPack(CajuWrite<BPos>.self, CajuRead<BVel>.self, CajuRead<BMass>.self) { p, v, m in
                p.value.x += v.x * m.m * 0.016
                acc += p.value.x
            }
            return acc
        })
}

// BVH (P-3): cena determinística de 10 000 AABBs (xorshift32 com semente fixa).
var spatialResults: [Result] = []
do {
    var rngState: UInt32 = 0x9E37_79B9
    func rand01() -> Float {
        rngState ^= rngState << 13
        rngState ^= rngState >> 17
        rngState ^= rngState << 5
        return Float(rngState >> 8) / Float(1 << 24)
    }
    let boxCount = 10_000
    var entries: [(bounds: CajuAABB, userData: UInt32)] = []
    entries.reserveCapacity(boxCount)
    for i in 0..<boxCount {
        let lo = CajuVec3(rand01() * 200 - 100, rand01() * 200 - 100, rand01() * 200 - 100)
        let size = CajuVec3(0.2 + rand01() * 2, 0.2 + rand01() * 2, 0.2 + rand01() * 2)
        entries.append((CajuAABB(min: lo, max: lo + size), UInt32(i)))
    }
    spatialResults.append(
        measureBatch("bvh.build(10k, SAH)", ops: boxCount) {
            guard var tree = try? CajuBVH() else { return 0 }
            return Float((try? tree.build(from: entries))?.count ?? 0)
        })
    spatialResults.append(
        measureBatch("bvh.insert(10k)", ops: boxCount) {
            guard var tree = try? CajuBVH() else { return 0 }
            for e in entries { _ = try? tree.insert(bounds: e.bounds, userData: e.userData) }
            return Float(tree.count)
        })
    if var tree = try? CajuBVH(), (try? tree.build(from: entries)) != nil {
        var rays: [CajuRayQuery] = []
        for _ in 0..<1_000 {
            let origin = SIMD3<Float>(rand01() * 200 - 100, rand01() * 200 - 100, rand01() * 200 - 100)
            let dir = SIMD3<Float>(rand01() - 0.5, rand01() - 0.5, rand01() - 0.5)
            if let r = try? CajuRayQuery(origin: origin, direction: dir, tMax: 500) { rays.append(r) }
        }
        var stack = CajuBVHTraversalStack()
        spatialResults.append(
            measureBatch("bvh.raycastFirst(10k, 1k raios)", ops: rays.count) {
                var acc: Float = 0
                for r in rays { acc += tree.raycastFirst(r, stack: &stack)?.t ?? 0 }
                return acc
            })
        let probe = CajuAABB(min: CajuVec3(-5, -5, -5), max: CajuVec3(5, 5, 5))
        spatialResults.append(
            measureBatch("bvh.query.overlap(10k, caixa 10³)", ops: 1_000) {
                var hits = 0
                for _ in 0..<1_000 {
                    try? tree.query(overlapping: probe, stack: &stack) { _, _ in
                        hits += 1
                        return true
                    }
                }
                return Float(hits)
            })
    }
    // BVH de triângulos: grade 100×100 de quads no plano z = 0 (20 000 triângulos).
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    let side = 100
    for y in 0...side { for x in 0...side { positions.append(SIMD3<Float>(Float(x), Float(y), 0)) } }
    for y in 0..<side {
        for x in 0..<side {
            let a = UInt32(y * (side + 1) + x)
            let b = a + 1
            let c = a + UInt32(side + 1)
            indices += [a, b, c, b, c + 1, c]
        }
    }
    spatialResults.append(
        measureBatch("triangleBVH.build(20k tri)", ops: indices.count / 3) {
            Float((try? CajuTriangleBVH(positions: positions, indices: indices))?.triangleCount ?? 0)
        })
    if let mesh = try? CajuTriangleBVH(positions: positions, indices: indices) {
        var rays: [CajuRayQuery] = []
        for _ in 0..<1_000 {
            let origin = SIMD3<Float>(rand01() * 100, rand01() * 100, 5)
            if let r = try? CajuRayQuery(origin: origin, direction: SIMD3<Float>(0, 0, -1), tMax: 50) {
                rays.append(r)
            }
        }
        var stack = CajuBVHTraversalStack()
        spatialResults.append(
            measureBatch("triangleBVH.raycastFirst(20k tri, 1k raios)", ops: rays.count) {
                var acc: Float = 0
                for r in rays { acc += mesh.raycastFirst(r, stack: &stack)?.t ?? 0 }
                return acc
            })
    }
}

// MARK: - CajuRender: extração e draw list (R-1a; ADR 0023)

/// Servidor de assets fixo para o benchmark (sem carga).
final class BenchAssets: CajuAssetServing {
    let mesh = CajuMeshAsset.cube()
    let material = CajuMaterialAsset()
    func load<A: CajuAsset>(_ type: A.Type, path: CajuAssetPath) -> CajuAssetHandle<A> { .invalid }
    func state<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetState { .loaded }
    func value<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> A? {
        if A.self == CajuMeshAsset.self { return mesh as? A }
        return material as? A
    }
    func error<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetError? { nil }
    func revision<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> UInt32 { 1 }
    func retain<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool { true }
    func release<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool { true }
    func reload(path: CajuAssetPath) {}
    func applyCompletions() {}
    func drainEvents(_ body: (CajuAssetEvent) -> Void) {}
}

var renderResults: [Result] = []
do {
    let assets = BenchAssets()
    for count in [1_000, 10_000] {
        let scene = CajuWorld()
        scene.reserve(entities: count + 1)
        for i in 0..<count {
            let x = Float(i % 100) - 50
            let z = -Float(i / 100) - 2
            _ = try? scene.spawn(
                CajuGlobalTransform(.translation(CajuVec3(x, 0, z))),
                CajuRenderMesh(
                    mesh: CajuAssetHandle(index: 0, generation: 1),
                    material: CajuAssetHandle(index: UInt32(i % 8), generation: 1)))
        }
        _ = try? scene.spawn(CajuGlobalTransform(.identity), CajuCamera(far: 1000))
        let render = CajuRenderWorld(capacity: count)
        renderResults.append(
            measureBatch("render.extract(\(count))", ops: count) {
                try? render.extract(from: scene, assets: assets)
                return Float(render.count)
            })
        var list = CajuDrawList(capacity: count)
        if let view = render.makeView(aspect: 1) {
            renderResults.append(
                measureBatch("render.drawList(cull+sort, \(count))", ops: count) {
                    try? list.build(from: render, view: view) { mesh, material in
                        CajuResolvedDraw(
                            mesh: CajuRenderMeshID(index: mesh.index, generation: 1),
                            material: CajuRenderMaterialID(index: material.index, generation: 1),
                            queue: .opaque,
                            pipeline: material.index % 2)
                    }
                    return Float(list.items.count)
                })
        }
    }
}

func emit(_ suite: String, _ results: [Result], last: Bool) {
    print("{\"suite\":\"\(suite)\",\"results\":[")
    for (i, r) in results.enumerated() {
        let comma = i == results.count - 1 ? "" : ","
        print(
            "  {\"name\":\"\(r.name)\",\"iterations\":\(r.iterations),\"ns_per_op\":\(r.nanosecondsPerOp)}\(comma)"
        )
    }
    print("]}")
}
emit("CajuMath", mathResults, last: false)
emit("CajuUILayout", layoutResults, last: false)
emit("CajuCore", ecsResults, last: false)
emit("CajuPhysicsSpatial", spatialResults, last: false)
emit("CajuRender", renderResults, last: true)
