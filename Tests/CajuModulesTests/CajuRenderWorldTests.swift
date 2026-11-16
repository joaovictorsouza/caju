import CajuAssets
import CajuCore
import CajuMath
import CajuRHI
import CajuScene
import Testing

@testable import CajuRender

/// Servidor de assets falso para testes headless do render: valores postos à mão, sem carga.
final class FakeAssetServer: CajuAssetServing {
    private var values: [CajuAnyAssetHandle: any CajuAsset] = [:]
    private var next: UInt32 = 1

    func put<A: CajuAsset>(_ value: A) -> CajuAssetHandle<A> {
        let handle = CajuAssetHandle<A>(index: next, generation: 1)
        next += 1
        values[handle.erased] = value
        return handle
    }

    func pending<A: CajuAsset>(_: A.Type) -> CajuAssetHandle<A> {
        defer { next += 1 }
        return CajuAssetHandle<A>(index: next, generation: 1)
    }

    func load<A: CajuAsset>(_ type: A.Type, path: CajuAssetPath) -> CajuAssetHandle<A> { pending(type) }
    func state<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetState {
        values[handle.erased] == nil ? .loading : .loaded
    }
    func value<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> A? { values[handle.erased] as? A }
    func error<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetError? { nil }
    func revision<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> UInt32 {
        values[handle.erased] == nil ? 0 : 1
    }
    func retain<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool { true }
    func release<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool { true }
    func reload(path: CajuAssetPath) {}
    func applyCompletions() {}
    func drainEvents(_ body: (CajuAssetEvent) -> Void) {}
}

@Suite("CajuRender: mundo de render, extração e draw list (R-1a)")
struct CajuRenderWorldTests {
    let assets = FakeAssetServer()

    private func camera(at position: CajuVec3, priority: Int32 = 0) -> (CajuGlobalTransform, CajuCamera) {
        (CajuGlobalTransform(.translation(position)), CajuCamera(near: 0.1, far: 100, priority: priority))
    }

    @Test func proceduralMeshesAreValid() {
        #expect(CajuMeshAsset.cube().isValid)
        #expect(CajuMeshAsset.cube().vertexCount == 24)
        #expect(CajuMeshAsset.sphere(segments: 8, rings: 4).isValid)
        var broken = CajuMeshAsset.cube()
        broken.indices[0] = 999
        #expect(!broken.isValid)
    }

    @Test func extractionCopiesMeshesCameraAndBrightestLight() throws {
        let world = CajuWorld()
        let cube = assets.put(CajuMeshAsset.cube(size: 2))
        let material = assets.put(CajuMaterialAsset())
        _ = try world.spawn(
            CajuGlobalTransform(.translation(CajuVec3(0, 0, -5))),
            CajuRenderMesh(mesh: cube, material: material))
        _ = try world.spawn(CajuRenderMesh(mesh: cube, material: material))  // sem transform: não é desenhada
        let low = camera(at: CajuVec3(0, 0, 0))
        let high = camera(at: CajuVec3(0, 1, 0), priority: 5)
        _ = try world.spawn(low.0, low.1)
        _ = try world.spawn(high.0, high.1)
        _ = try world.spawn(CajuDirectionalLightSource(direction: CajuVec3(0, -1, 0), intensity: 1))
        _ = try world.spawn(CajuDirectionalLightSource(direction: CajuVec3(1, 0, 0), intensity: 3))

        let render = CajuRenderWorld(capacity: 8)
        try render.extract(from: world, assets: assets)
        #expect(render.count == 1)
        #expect(render.worldBounds[0] == CajuAABB(min: CajuVec3(-1, -1, -6), max: CajuVec3(1, 1, -4)))
        #expect(render.camera?.camera.priority == 5)
        #expect(render.light?.intensity == 3)
        #expect(render.light?.direction == CajuVec3(1, 0, 0))
    }

    @Test func extractionReportsCapacityOverflow() throws {
        let world = CajuWorld()
        let mesh = assets.put(CajuMeshAsset.cube())
        let material = assets.put(CajuMaterialAsset())
        for _ in 0..<3 {
            _ = try world.spawn(
                CajuGlobalTransform(.identity), CajuRenderMesh(mesh: mesh, material: material))
        }
        let render = CajuRenderWorld(capacity: 2)
        #expect(throws: CajuRenderError.capacityExceeded(.meshes)) {
            try render.extract(from: world, assets: assets)
        }
    }

    @Test func drawListCullsLayersAndUnresolvedAndSortsByKey() throws {
        let render = CajuRenderWorld(capacity: 16)
        let ready = assets.put(CajuMeshAsset.cube())
        let loading = assets.pending(CajuMeshAsset.self)
        let opaque = assets.put(CajuMaterialAsset())
        let blend = assets.put(CajuMaterialAsset(alphaMode: .blend))
        let unit = CajuMeshAsset.cube().bounds
        render.camera = (.identity, CajuCamera(near: 0.1, far: 100))
        func at(_ z: Float) -> CajuMat4 { .translation(CajuVec3(0, 0, z)) }
        try render.append(world: at(-10), localBounds: unit, mesh: ready, material: opaque)  // 0
        try render.append(world: at(-3), localBounds: unit, mesh: ready, material: opaque)  // 1
        try render.append(world: at(-5), localBounds: unit, mesh: ready, material: blend)  // 2
        try render.append(world: at(-8), localBounds: unit, mesh: ready, material: blend)  // 3
        try render.append(world: at(+10), localBounds: unit, mesh: ready, material: opaque)  // 4: atrás
        try render.append(world: at(-4), localBounds: unit, mesh: loading, material: opaque)  // 5: carregando
        try render.append(world: at(-4), localBounds: unit, mesh: ready, material: opaque, layerMask: 0)  // 6

        let view = try #require(render.makeView(aspect: 1))
        var list = CajuDrawList(capacity: 16)
        try list.build(from: render, view: view) { mesh, material in
            guard assets.value(of: mesh) != nil, let m = assets.value(of: material) else { return nil }
            return CajuResolvedDraw(
                mesh: CajuRenderMeshID(index: mesh.index, generation: 1),
                material: CajuRenderMaterialID(index: material.index, generation: 1),
                queue: m.alphaMode == .blend ? .blend : .opaque, pipeline: m.alphaMode == .blend ? 1 : 0)
        }
        // Opacos de frente para trás (1, 0), depois transparentes de trás para frente (3, 2).
        #expect(list.items.map(\.instanceIndex) == [1, 0, 3, 2])
    }

    @Test func radixSortMatchesComparisonOracle() {
        var list = CajuDrawList(capacity: 512)
        var state: UInt64 = 0x1234_5678
        var keys: [CajuDrawKey] = []
        for i in 0..<500 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            keys.append(CajuDrawKey(bits: state))
            _ = i
        }
        list.replaceForTesting(keys)
        list.sort()
        #expect(list.items.map(\.key) == keys.sorted())
    }
}
