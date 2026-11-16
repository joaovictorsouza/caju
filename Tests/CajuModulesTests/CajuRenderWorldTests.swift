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

@Suite("CajuRender: quadro completo no dispositivo null (R-1a)")
struct CajuSceneRendererNullTests {
    @Test func ecsToDrawListThroughNullDevice() throws {
        let assets = FakeAssetServer()
        let world = CajuWorld()
        let cube = assets.put(CajuMeshAsset.cube())
        let sphere = assets.pending(CajuMeshAsset.self)  // ainda carregando: não desenha
        let material = assets.put(CajuMaterialAsset(model: .unlit))
        let pendingMaterial = assets.pending(CajuMaterialAsset.self)  // usa o substituto
        _ = try world.spawn(
            CajuGlobalTransform(.translation(CajuVec3(0, 0, -4))),
            CajuRenderMesh(mesh: cube, material: material))
        _ = try world.spawn(
            CajuGlobalTransform(.translation(CajuVec3(1, 0, -4))),
            CajuRenderMesh(mesh: cube, material: pendingMaterial))
        _ = try world.spawn(
            CajuGlobalTransform(.translation(CajuVec3(-1, 0, -4))),
            CajuRenderMesh(mesh: sphere, material: material))
        _ = try world.spawn(CajuGlobalTransform(.identity), CajuCamera())

        let device = CajuNullDevice()
        let renderer = try CajuSceneRenderer(device: device, colorFormat: .bgra8UnormSRGB)
        let render = CajuRenderWorld(capacity: 16)
        let target = try device.createTexture(
            CajuTextureDescriptor(format: .bgra8UnormSRGB, width: 32, height: 32, usage: .renderTarget))
        for _ in 0..<3 {
            try render.extract(from: world, assets: assets)
            try renderer.prepare(world: render, assets: assets)
            var commands = try device.queue.makeCommandBuffer(label: "quadro")
            try renderer.record(world: render, into: &commands, target: target, width: 32, height: 32)
            try device.queue.submit(commands)
        }
        #expect(render.count == 3)
        #expect(renderer.drawList.items.count == 2)
        #expect(renderer.residentMeshCount == 1)
        #expect(renderer.pipelineCount == 2)  // PBR substituto + unlit
        #expect(renderer.lastDrawCalls == 2)
    }

    /// 100 cubos com a mesma malha e material viram 1 draw call (instancing, R-1b).
    @Test func identicalItemsAreInstanced() throws {
        let assets = FakeAssetServer()
        let cube = assets.put(CajuMeshAsset.cube())
        let material = assets.put(CajuMaterialAsset())
        let other = assets.put(CajuMaterialAsset(baseColor: CajuColor(r: 1, g: 0, b: 0)))
        let render = CajuRenderWorld(capacity: 128)
        render.camera = (.identity, CajuCamera(far: 500))
        for i in 0..<100 {
            try render.append(
                world: .translation(CajuVec3(Float(i % 10) - 5, Float(i / 10) - 5, -20)),
                localBounds: CajuMeshAsset.cube().bounds, mesh: cube, material: material)
        }
        try render.append(
            world: .translation(CajuVec3(0, 0, -10)), localBounds: CajuMeshAsset.cube().bounds, mesh: cube,
            material: other)
        let device = CajuNullDevice()
        let renderer = try CajuSceneRenderer(device: device, colorFormat: .bgra8UnormSRGB)
        let target = try device.createTexture(
            CajuTextureDescriptor(format: .bgra8UnormSRGB, width: 32, height: 32, usage: .renderTarget))
        try renderer.prepare(world: render, assets: assets)
        var commands = try device.queue.makeCommandBuffer(label: "quadro")
        try renderer.record(world: render, into: &commands, target: target, width: 32, height: 32)
        #expect(renderer.drawList.items.count == 101)
        #expect(renderer.lastDrawCalls == 2)
        #expect(!renderer.lastFrameHadShadow)  // sem luz no quadro

        render.light = CajuDirectionalLight(direction: CajuVec3(0, -1, 0), castsShadow: true)
        try renderer.record(world: render, into: &commands, target: target, width: 32, height: 32)
        #expect(renderer.lastFrameHadShadow)
    }
}

#if canImport(Darwin)
    import Darwin

    @Suite("CajuRender: sem alocação no quadro estável (R-1a)")
    struct CajuRenderAllocationTests {
        private func liveBlocks() -> UInt32 {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return stats.blocks_in_use
        }

        /// Extração e draw list de 500 entidades, 200 quadros depois do aquecimento: os blocos vivos do
        /// `malloc` não crescem (quadro estável sem alocação; `performance.md` regra 1). Fica a menor de 3
        /// rodadas (testes paralelos mexem no heap); um vazamento de 1 bloco por quadro daria 200.
        @Test func extractionAndDrawListDoNotGrowTheHeap() throws {
            let assets = FakeAssetServer()
            let mesh = assets.put(CajuMeshAsset.cube())
            let material = assets.put(CajuMaterialAsset())
            let world = CajuWorld()
            for i in 0..<500 {
                _ = try world.spawn(
                    CajuGlobalTransform(.translation(CajuVec3(Float(i % 25) - 12, 0, -Float(i / 25) - 2))),
                    CajuRenderMesh(mesh: mesh, material: material))
            }
            _ = try world.spawn(CajuGlobalTransform(.identity), CajuCamera(far: 500))
            let render = CajuRenderWorld(capacity: 512)
            var list = CajuDrawList(capacity: 512)
            func frame() throws {
                try render.extract(from: world, assets: assets)
                guard let view = render.makeView(aspect: 1) else { return }
                try list.build(from: render, view: view) { mesh, material in
                    CajuResolvedDraw(
                        mesh: CajuRenderMeshID(index: mesh.index, generation: 1),
                        material: CajuRenderMaterialID(index: material.index, generation: 1), queue: .opaque,
                        pipeline: 0)
                }
            }
            for _ in 0..<5 { try frame() }
            // Outros testes rodam em paralelo e mexem no heap: fica a menor variação de 3 rodadas.
            var smallest = Int.max
            for _ in 0..<3 {
                let before = liveBlocks()
                for _ in 0..<200 { try frame() }
                smallest = min(smallest, Int(liveBlocks()) - Int(before))
            }
            #expect(smallest < 100, "menor variação de blocos vivos em 200 quadros: \(smallest)")
            #expect(list.items.count > 0)
        }
    }
#endif
