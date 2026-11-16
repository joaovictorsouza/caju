import CajuAssets
import CajuMath
import CajuRHI

/// Renderer de cena da R-1a (ADR 0023): residência na GPU dos assets de render, cache de PSO em memória,
/// draw list e passe `main` forward com MSAA transitório resolvido no alvo.
///
/// Uso por quadro, na *thread* do jogo: `renderWorld.extract(...)`, `renderer.prepare(world:assets:)` (eventos
/// de asset e uploads sob o orçamento) e `renderer.record(world:into:target:)` dentro do *command buffer*.
/// Genérico no dispositivo (Metal, Vulkan, null): os shaders vêm em MSL ou SPIR-V conforme o backend.
public final class CajuSceneRenderer<Device: CajuRenderDevice> {
    public let device: Device
    public let colorFormat: CajuPixelFormat
    public let sampleCount: Int
    public let depthFormat: CajuPixelFormat = .depth32Float
    /// Orçamento de upload por quadro (malhas e texturas novas); o que não couber espera o próximo quadro.
    public var uploadBudget = CajuUploadBudget(bytesPerFrame: 4 << 20)
    public private(set) var drawList: CajuDrawList

    private let vertex: CajuShaderFunction
    private let fragment: CajuShaderFunction
    private let whiteTexture: CajuTextureHandle
    private let sampler: CajuSamplerHandle

    /// Sombra da luz direcional (R-1b): mapa de profundidade único, passe `shadow` antes do `main`.
    public let shadowMapSize: Int
    private let shadowMap: CajuTextureHandle
    private let shadowSampler: CajuSamplerHandle
    private var shadowPipeline = CajuRenderPipelineHandle.null
    private var shadowBatches: [(first: Int, count: Int, mesh: Int)] = []
    private var shadowInstances: [InstanceData] = []
    private var shadowMapInitialized = false
    /// `true` se o último `record` desenhou o passe de sombra.
    public private(set) var lastFrameHadShadow = false

    private struct PipelineKey: Hashable {
        var model: CajuMaterialModel
        var alphaMode: CajuAlphaMode
        var doubleSided: Bool
    }
    private var pipelineIndex: [PipelineKey: UInt32] = [:]
    private var pipelines: [CajuRenderPipelineHandle] = []

    private struct ResidentMesh {
        var generation: UInt32
        var vertexBuffer: CajuBufferHandle
        var indexBuffer: CajuBufferHandle
        var indexCount: Int
    }
    private struct ResidentMaterial {
        var generation: UInt32
        var asset: CajuMaterialAsset
        var texture: CajuTextureHandle
        var pipeline: UInt32
        var queue: CajuRenderQueue
    }
    private struct ResidentTexture {
        var generation: UInt32
        var texture: CajuTextureHandle
    }
    /// Indexados pelo índice do handle do asset (capacidade fixa; ver `capacityExceeded`).
    private var meshes: [ResidentMesh?]
    /// Posição 0 = material substituto; o asset de índice `i` fica em `i + 1`.
    private var materials: [ResidentMaterial?]
    private var textures: [ResidentTexture?]

    /// Instancing (R-1b): matrizes do quadro num buffer `storage` por quadro em voo (3, rotativos); itens
    /// consecutivos da draw list com a mesma malha e material viram um `drawIndexed(instanceCount:)`.
    static var framesInFlight: Int { 3 }
    private var instanceBuffers: [CajuBufferHandle] = []
    private var instanceData: [InstanceData] = []
    private var batches: [(first: Int, count: Int, item: Int)] = []
    private var frameIndex = 0
    /// Draw calls do último `record` (orçamento de 300 por quadro de cena; `performance.md`).
    public private(set) var lastDrawCalls = 0

    public init(
        device: Device, colorFormat: CajuPixelFormat, sampleCount: Int = 4, drawCapacity: Int = 4096,
        residentCapacity: Int = 1024, shadowMapSize: Int = 1024
    ) throws(CajuRenderError) {
        self.shadowMapSize = max(shadowMapSize, 16)
        self.device = device
        self.colorFormat = colorFormat
        self.sampleCount = device.capabilities.sampleCounts.supports(sampleCount) ? sampleCount : 1
        drawList = CajuDrawList(capacity: drawCapacity)
        meshes = Array(repeating: nil, count: residentCapacity)
        materials = Array(repeating: nil, count: residentCapacity + 1)
        textures = Array(repeating: nil, count: residentCapacity)
        instanceData.reserveCapacity(drawList.capacity)
        batches.reserveCapacity(drawList.capacity)
        shadowBatches.reserveCapacity(drawList.capacity)
        shadowInstances.reserveCapacity(drawList.capacity)
        do {
            let shaders: (vertex: CajuShaderModuleDescriptor, fragment: CajuShaderModuleDescriptor)
            if device.capabilities.backendName == "Vulkan" {
                shaders = (
                    CajuShaderModuleDescriptor(
                        format: .spirv, code: Self.bytes(CajuSceneShaderSPIRV.vertex), label: "scene.vert"),
                    CajuShaderModuleDescriptor(
                        format: .spirv, code: Self.bytes(CajuSceneShaderSPIRV.fragment), label: "scene.frag")
                )
            } else {
                let msl = CajuShaderModuleDescriptor(
                    format: .metalSource, code: Array(CajuSceneShaderMSL.source.utf8), label: "scene")
                shaders = (msl, msl)
            }
            let vertexModule = try device.createShaderModule(shaders.vertex)
            let fragmentModule =
                shaders.vertex == shaders.fragment
                ? vertexModule : try device.createShaderModule(shaders.fragment)
            let isMetal = shaders.vertex == shaders.fragment
            vertex = CajuShaderFunction(module: vertexModule, entryPoint: isMetal ? "caju_scene_vs" : "main")
            fragment = CajuShaderFunction(
                module: fragmentModule, entryPoint: isMetal ? "caju_scene_fs" : "main")
            let white = try device.createTexture(
                CajuTextureDescriptor(
                    format: .rgba8Unorm, width: 1, height: 1, usage: [.sampled, .copyDestination],
                    label: "white"))
            try Self.writeTexture(device, white, width: 1, height: 1, pixels: [255, 255, 255, 255])
            whiteTexture = white
            for _ in 0..<Self.framesInFlight {
                instanceBuffers.append(
                    try device.createBuffer(
                        CajuBufferDescriptor(
                            // Metade para o passe main, metade para os que projetam sombra.
                            size: 2 * drawCapacity * MemoryLayout<InstanceData>.stride, usage: .storage,
                            storage: .shared,
                            label: "scene.instances")))
            }
            sampler = try device.createSampler(
                CajuSamplerDescriptor(addressU: .repeat, addressV: .repeat, addressW: .repeat))
            shadowMap = try device.createTexture(
                CajuTextureDescriptor(
                    format: .depth32Float, width: self.shadowMapSize, height: self.shadowMapSize,
                    usage: [.renderTarget, .sampled], label: "scene.shadowMap"))
            shadowSampler = try device.createSampler(
                CajuSamplerDescriptor(minFilter: .nearest, magFilter: .nearest, mipFilter: .nearest))
            shadowPipeline = try device.createRenderPipeline(
                CajuRenderPipelineDescriptor(
                    vertex: vertex, fragment: nil,
                    vertexAttributes: Self.vertexAttributes,
                    vertexLayouts: [
                        CajuVertexBufferLayout(bufferIndex: 0, stride: CajuMeshVertexLayout.stride)
                    ],
                    colorTargets: [], depth: CajuDepthState(format: .depth32Float, compare: .lessEqual),
                    cullMode: .none, sampleCount: 1, label: "scene.shadow"))
        } catch {
            throw .rhi(error)
        }
        materials[0] = ResidentMaterial(
            generation: 0, asset: .fallback, texture: whiteTexture, pipeline: 0, queue: .opaque)
        materials[0]?.pipeline = try pipeline(for: CajuMaterialAsset.fallback)
    }

    deinit {
        for buffer in instanceBuffers { device.destroy(buffer) }
        for index in meshes.indices { evictMesh(index: index) }
        for index in textures.indices { evictTexture(index: index) }
        for pipeline in pipelines { device.destroy(pipeline) }
        device.destroy(whiteTexture)
        device.destroy(sampler)
        device.destroy(shadowPipeline)
        device.destroy(shadowMap)
        device.destroy(shadowSampler)
        device.destroy(vertex.module)
        if fragment.module != vertex.module { device.destroy(fragment.module) }
    }

    /// Projeção ortográfica da luz que cobre a caixa de todos os itens do quadro (cascata única).
    static func lightViewProjection(world: CajuRenderWorld, direction: CajuVec3) -> CajuMat4? {
        guard world.count > 0 else { return nil }
        var bounds = world.worldBounds[0]
        for i in 1..<world.count {
            bounds = CajuAABB(
                min: CajuVec3.min(bounds.min, world.worldBounds[i].min),
                max: CajuVec3.max(bounds.max, world.worldBounds[i].max))
        }
        let center = (bounds.min + bounds.max) * 0.5
        let radius = max((bounds.max - bounds.min).length * 0.5, 0.01)
        guard let forward = direction.normalized() else { return nil }
        let up = abs(forward.y) > 0.99 ? CajuVec3(1, 0, 0) : CajuVec3(0, 1, 0)
        guard let view = CajuMat4.lookAt(eye: center - forward * (2 * radius), target: center, up: up),
            let projection = CajuMat4.orthographic(
                left: -radius, right: radius, bottom: -radius, top: radius, near: radius * 0.5,
                far: radius * 3.5)
        else { return nil }
        return projection * view
    }

    private static var vertexAttributes: [CajuVertexAttribute] {
        [
            CajuVertexAttribute(location: 0, format: .float3, offset: 0, bufferIndex: 0),
            CajuVertexAttribute(location: 1, format: .float3, offset: 12, bufferIndex: 0),
            CajuVertexAttribute(location: 2, format: .float2, offset: 24, bufferIndex: 0),
        ]
    }

    private static func bytes(_ words: [UInt32]) -> [UInt8] { words.withUnsafeBytes { [UInt8]($0) } }

    // Os *closures* de `withUnsafeBytes` não lançam erro tipado: converter um `throws(CajuRHIError)` para o
    // `throws` sem tipo derruba o compilador do Swift 6.2 (CI). O erro sai por variável capturada.
    private static func writeBuffer<T>(
        _ device: Device, _ buffer: CajuBufferHandle, _ values: [T], offset: Int = 0
    ) throws(CajuRHIError) {
        var failure: CajuRHIError?
        values.withUnsafeBytes { raw in
            do throws(CajuRHIError) { try device.writeBuffer(buffer, offset: offset, bytes: raw) } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    private static func writeTexture(
        _ device: Device, _ texture: CajuTextureHandle, width: Int, height: Int, pixels: [UInt8]
    ) throws(CajuRHIError) {
        var failure: CajuRHIError?
        pixels.withUnsafeBytes { raw in
            do throws(CajuRHIError) {
                try device.writeTexture(
                    texture, mipLevel: 0, slice: 0, width: width, height: height, bytesPerRow: width * 4,
                    bytes: raw)
            } catch { failure = error }
        }
        if let failure { throw failure }
    }

    // MARK: Pipelines (cache em memória)

    private func pipeline(for material: CajuMaterialAsset) throws(CajuRenderError) -> UInt32 {
        let key = PipelineKey(
            model: material.model, alphaMode: material.alphaMode, doubleSided: material.doubleSided)
        if let index = pipelineIndex[key] { return index }
        let blended = material.alphaMode == .blend
        let descriptor = CajuRenderPipelineDescriptor(
            vertex: vertex, fragment: fragment,
            vertexAttributes: Self.vertexAttributes,
            vertexLayouts: [CajuVertexBufferLayout(bufferIndex: 0, stride: CajuMeshVertexLayout.stride)],
            colorTargets: [CajuColorTargetState(format: colorFormat, blend: blended ? .alpha : nil)],
            depth: CajuDepthState(format: depthFormat, compare: .less, writesDepth: !blended),
            cullMode: material.doubleSided ? .none : .back, frontFace: .counterClockwise,
            sampleCount: sampleCount,
            label: "scene")
        let handle: CajuRenderPipelineHandle
        do { handle = try device.createRenderPipeline(descriptor) } catch { throw .rhi(error) }
        let index = UInt32(pipelines.count)
        pipelines.append(handle)
        pipelineIndex[key] = index
        return index
    }

    /// Pipelines criados até agora (o cenário de referência os cria na primeira carga).
    public var pipelineCount: Int { pipelines.count }

    // MARK: Residência

    /// Aplica os eventos de asset (descarte e recarga) e sobe na GPU o que o quadro usa e ainda não está lá,
    /// dentro de `uploadBudget`.
    public func prepare(world: CajuRenderWorld, assets: some CajuAssetServing) throws(CajuRenderError) {
        assets.drainEvents { event in
            guard event.kind == .unloaded || event.kind == .reloaded else { return }
            if let handle = event.asset.typed(as: CajuMeshAsset.self) { evictMesh(index: Int(handle.index)) }
            if let handle = event.asset.typed(as: CajuMaterialAsset.self) {
                evictMaterial(index: Int(handle.index) + 1)
            }
            if let handle = event.asset.typed(as: CajuTextureAsset.self) {
                evictTexture(index: Int(handle.index))
            }
        }
        uploadBudget.beginFrame()
        for i in 0..<world.count {
            try makeResident(mesh: world.meshes[i], assets: assets)
            try makeResident(material: world.materials[i], assets: assets)
        }
    }

    private func makeResident(mesh handle: CajuAssetHandle<CajuMeshAsset>, assets: some CajuAssetServing)
        throws(CajuRenderError)
    {
        let slot = Int(handle.index)
        guard slot < meshes.count else { throw .capacityExceeded(.residentMeshes) }
        if let resident = meshes[slot], resident.generation == handle.generation { return }
        guard let mesh = assets.value(of: handle), mesh.isValid else { return }
        let vertexBytes = mesh.vertices.count * MemoryLayout<Float>.stride
        let indexBytes = mesh.indices.count * MemoryLayout<UInt32>.stride
        guard uploadBudget.reserve(vertexBytes + indexBytes) else { return }
        evictMesh(index: slot)
        do {
            let vertexBuffer = try device.createBuffer(
                CajuBufferDescriptor(
                    size: vertexBytes, usage: .vertex, storage: .shared, label: "mesh.vertices"))
            let indexBuffer = try device.createBuffer(
                CajuBufferDescriptor(size: indexBytes, usage: .index, storage: .shared, label: "mesh.indices")
            )
            try Self.writeBuffer(device, vertexBuffer, mesh.vertices)
            try Self.writeBuffer(device, indexBuffer, mesh.indices)
            meshes[slot] = ResidentMesh(
                generation: handle.generation, vertexBuffer: vertexBuffer, indexBuffer: indexBuffer,
                indexCount: mesh.indices.count)
        } catch {
            throw .rhi(error)
        }
    }

    private func makeResident(
        material handle: CajuAssetHandle<CajuMaterialAsset>, assets: some CajuAssetServing
    )
        throws(CajuRenderError)
    {
        let slot = Int(handle.index) + 1
        guard slot < materials.count else { throw .capacityExceeded(.residentMaterials) }
        if let resident = materials[slot], resident.generation == handle.generation { return }
        guard handle.generation != 0, let material = assets.value(of: handle) else { return }
        var texture = whiteTexture
        if material.baseColorTexture.generation != 0 {
            guard let resident = try makeResident(texture: material.baseColorTexture, assets: assets) else {
                return  // textura ainda não está na GPU: fica no substituto mais um quadro
            }
            texture = resident
        }
        let queue: CajuRenderQueue =
            switch material.alphaMode {
            case .opaque: .opaque
            case .mask: .mask
            case .blend: .blend
            }
        materials[slot] = ResidentMaterial(
            generation: handle.generation, asset: material, texture: texture,
            pipeline: try pipeline(for: material), queue: queue)
    }

    private func makeResident(
        texture handle: CajuAssetHandle<CajuTextureAsset>, assets: some CajuAssetServing
    )
        throws(CajuRenderError) -> CajuTextureHandle?
    {
        let slot = Int(handle.index)
        guard slot < textures.count else { throw .capacityExceeded(.residentMaterials) }
        if let resident = textures[slot], resident.generation == handle.generation { return resident.texture }
        guard let asset = assets.value(of: handle), asset.isValid, uploadBudget.reserve(asset.pixels.count)
        else { return nil }
        evictTexture(index: slot)
        do {
            let texture = try device.createTexture(
                CajuTextureDescriptor(
                    format: asset.isSRGB ? .rgba8UnormSRGB : .rgba8Unorm, width: asset.width,
                    height: asset.height,
                    usage: [.sampled, .copyDestination], label: "material.baseColor"))
            try Self.writeTexture(
                device, texture, width: asset.width, height: asset.height, pixels: asset.pixels)
            textures[slot] = ResidentTexture(generation: handle.generation, texture: texture)
            return texture
        } catch {
            throw .rhi(error)
        }
    }

    private func evictMesh(index: Int) {
        guard index < meshes.count, let resident = meshes[index] else { return }
        device.destroy(resident.vertexBuffer)
        device.destroy(resident.indexBuffer)
        meshes[index] = nil
    }

    private func evictMaterial(index: Int) {
        guard index > 0, index < materials.count else { return }
        materials[index] = nil
    }

    private func evictTexture(index: Int) {
        guard index < textures.count, let resident = textures[index] else { return }
        device.destroy(resident.texture)
        textures[index] = nil
        // Materiais que usavam a textura voltam a ser resolvidos (sobem de novo com a textura nova).
        for i in 1..<materials.count where materials[i]?.texture == resident.texture { materials[i] = nil }
    }

    /// Recursos da cena residentes (diagnóstico de vazamento).
    public var residentMeshCount: Int { meshes.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    // MARK: Quadro

    /// Grava o passe `main` no alvo (`target`: textura de 1 amostra com `renderTarget`, por exemplo a imagem
    /// do *swapchain*). Sem câmera, só limpa com preto.
    public func record(
        world: CajuRenderWorld, into commands: inout Device.Queue.CommandBuffer, target: CajuTextureHandle,
        width: Int, height: Int
    ) throws(CajuRenderError) {
        let aspect = Float(max(width, 1)) / Float(max(height, 1))
        let view = world.makeView(aspect: aspect)
        if let view {
            let meshes = self.meshes
            let materials = self.materials
            try drawList.build(from: world, view: view) { meshHandle, materialHandle in
                let meshSlot = Int(meshHandle.index)
                guard meshSlot < meshes.count, let mesh = meshes[meshSlot],
                    mesh.generation == meshHandle.generation
                else { return nil }
                _ = mesh
                var materialSlot = Int(materialHandle.index) + 1
                if materialSlot >= materials.count
                    || materials[materialSlot]?.generation != materialHandle.generation
                    || materialHandle.generation == 0
                {
                    materialSlot = 0
                }
                guard let material = materials[materialSlot] else { return nil }
                return CajuResolvedDraw(
                    mesh: CajuRenderMeshID(index: meshHandle.index, generation: meshHandle.generation),
                    material: CajuRenderMaterialID(index: UInt32(materialSlot), generation: 1),
                    queue: material.queue, pipeline: material.pipeline)
            }
        }

        // Alvos do passe: com MSAA, cor e profundidade multiamostradas transitórias (memoryless quando o
        // aparelho deixa) resolvidas no alvo; sem MSAA, desenha direto no alvo.
        let transientStorage: CajuStorageMode =
            device.capabilities.supportsMemoryless ? .memoryless : .privateGPU
        let clear = view?.clearColor ?? CajuColor(r: 0, g: 0, b: 0)
        let clearValue = SIMD4<Float>(clear.r, clear.g, clear.b, clear.a)
        var color = CajuColorAttachment(texture: .texture(target), load: .clear(clearValue), store: .store)
        let depthTexture: CajuTextureHandle
        do {
            if sampleCount > 1 {
                let msaa = try device.transientTexture(
                    CajuTextureDescriptor(
                        format: colorFormat, width: width, height: height, sampleCount: sampleCount,
                        usage: .renderTarget, storage: transientStorage, label: "scene.color.msaa"),
                    slot: -1)
                color = CajuColorAttachment(
                    texture: .texture(msaa), load: .clear(clearValue), store: .resolve,
                    resolveTexture: .texture(target))
            }
            depthTexture = try device.transientTexture(
                CajuTextureDescriptor(
                    format: depthFormat, width: width, height: height, sampleCount: sampleCount,
                    usage: .renderTarget, storage: transientStorage, label: "scene.depth"),
                slot: -2)
        } catch {
            throw .rhi(error)
        }

        // Lotes de instâncias: itens consecutivos (já ordenados) com a mesma malha e material.
        instanceData.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        let sortedItems = drawList.items
        for (i, item) in sortedItems.enumerated() {
            let model = world.worldMatrices[Int(item.instanceIndex)]
            instanceData.append(
                InstanceData(model: model, normalMatrix: model.inverseAffine?.transposed ?? model))
            if let last = batches.last, sortedItems[last.item].mesh == item.mesh,
                sortedItems[last.item].material == item.material
            {
                batches[batches.count - 1].count += 1
            } else {
                batches.append((first: i, count: 1, item: i))
            }
        }
        let instanceBuffer = instanceBuffers[frameIndex % Self.framesInFlight]
        frameIndex &+= 1
        if !instanceData.isEmpty {
            do { try Self.writeBuffer(device, instanceBuffer, instanceData) } catch { throw .rhi(error) }
        }
        lastDrawCalls = view == nil ? 0 : batches.count

        // Passe `shadow` (R-1b): profundidade vista da luz, de tudo que projeta sombra (mesmo fora da tela).
        shadowInstances.removeAll(keepingCapacity: true)
        shadowBatches.removeAll(keepingCapacity: true)
        var lightViewProjection = CajuMat4.identity
        var shadowEnabled = false
        if view != nil, let light = world.light, light.castsShadow,
            let lightVP = Self.lightViewProjection(world: world, direction: light.direction)
        {
            lightViewProjection = lightVP
            for i in 0..<world.count where world.castsShadow[i] {
                let handle = world.meshes[i]
                let slot = Int(handle.index)
                guard slot < meshes.count, let resident = meshes[slot],
                    resident.generation == handle.generation,
                    shadowInstances.count < drawList.capacity
                else { continue }
                let model = world.worldMatrices[i]
                shadowInstances.append(InstanceData(model: model, normalMatrix: model))
                if let last = shadowBatches.last, last.mesh == slot {
                    shadowBatches[shadowBatches.count - 1].count += 1
                } else {
                    shadowBatches.append((first: shadowInstances.count - 1, count: 1, mesh: slot))
                }
            }
            shadowEnabled = !shadowInstances.isEmpty
        }
        lastFrameHadShadow = shadowEnabled
        let shadowOffset = drawList.capacity * MemoryLayout<InstanceData>.stride
        if shadowEnabled || !shadowMapInitialized {
            do {
                if !shadowInstances.isEmpty {
                    try Self.writeBuffer(device, instanceBuffer, shadowInstances, offset: shadowOffset)
                }
                let shadowPass = CajuRenderPassDescriptor(
                    colorAttachments: [],
                    depthAttachment: CajuDepthAttachment(
                        texture: .texture(shadowMap), load: .clear(SIMD4(1, 0, 0, 0)), store: .store),
                    label: "shadow")
                let shadowPipeline = self.shadowPipeline
                let shadowBatches = self.shadowBatches
                let meshes = self.meshes
                try commands.withRenderPass(shadowPass) { encoder in
                    guard !shadowBatches.isEmpty else { return }
                    var lightVP = lightViewProjection
                    encoder.setPipeline(shadowPipeline)
                    withUnsafeBytes(of: &lightVP) { encoder.setBytes($0, index: 0, stage: .vertex) }
                    encoder.setBuffer(instanceBuffer, offset: shadowOffset, index: 1, stage: .vertex)
                    for batch in shadowBatches {
                        guard let mesh = meshes[batch.mesh] else { continue }
                        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                        encoder.drawIndexed(
                            indexCount: mesh.indexCount, instanceCount: batch.count,
                            indexBuffer: mesh.indexBuffer,
                            indexType: .uint32, indexOffset: 0, baseVertex: 0, firstInstance: batch.first)
                    }
                }
                shadowMapInitialized = true
            } catch {
                throw .rhi(error)
            }
        }

        let pass = CajuRenderPassDescriptor(
            colorAttachments: [color],
            depthAttachment: CajuDepthAttachment(
                texture: .texture(depthTexture), load: .clear(SIMD4(1, 0, 0, 0))),
            label: "main")
        let light = world.light
        let ambient = world.ambient
        let pipelines = self.pipelines
        let meshes = self.meshes
        let materials = self.materials
        let sampler = self.sampler
        let batches = self.batches
        let shadowMap = self.shadowMap
        let shadowSampler = self.shadowSampler
        let shadowParams = SIMD4<Float>(shadowEnabled ? 1 : 0, 0.002, 1 / Float(shadowMapSize), 0)
        do {
            try commands.withRenderPass(pass) { encoder in
                guard let view else { return }
                var boundPipeline = UInt32.max
                var frame = view.viewProjection
                var materialUniforms = MaterialUniforms()
                materialUniforms.ambient = SIMD4(ambient.r, ambient.g, ambient.b, 0)
                materialUniforms.cameraPosition = SIMD4(view.position.storage, 1)
                materialUniforms.shadowParams = shadowParams
                materialUniforms.lightViewProjection = lightViewProjection
                if let light {
                    let toLight = -light.direction
                    materialUniforms.lightDirection = SIMD4(toLight.storage, 1)
                    materialUniforms.lightColor = SIMD4(
                        light.color.r * light.intensity, light.color.g * light.intensity,
                        light.color.b * light.intensity, 0)
                }
                for batch in batches {
                    let item = sortedItems[batch.item]
                    guard let mesh = meshes[Int(item.mesh.index)],
                        let material = materials[Int(item.material.index)]
                    else { continue }
                    if material.pipeline != boundPipeline {
                        encoder.setPipeline(pipelines[Int(material.pipeline)])
                        boundPipeline = material.pipeline
                        withUnsafeBytes(of: &frame) { encoder.setBytes($0, index: 0, stage: .vertex) }
                        encoder.setBuffer(instanceBuffer, offset: 0, index: 1, stage: .vertex)
                    }
                    let asset = material.asset
                    materialUniforms.baseColor = SIMD4(
                        asset.baseColor.r, asset.baseColor.g, asset.baseColor.b, asset.baseColor.a)
                    materialUniforms.emissive = SIMD4(asset.emissive.r, asset.emissive.g, asset.emissive.b, 0)
                    materialUniforms.params = SIMD4(
                        asset.metallic, asset.roughness, asset.alphaMode == .mask ? asset.alphaCutoff : 0,
                        asset.model == .pbr ? 1 : 0)
                    encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                    withUnsafeBytes(of: &materialUniforms) {
                        encoder.setBytes($0, index: 0, stage: .fragment)
                    }
                    encoder.setTexture(material.texture, index: 0, stage: .fragment)
                    encoder.setSampler(sampler, index: 0, stage: .fragment)
                    encoder.setTexture(shadowMap, index: 1, stage: .fragment)
                    encoder.setSampler(shadowSampler, index: 1, stage: .fragment)
                    encoder.drawIndexed(
                        indexCount: mesh.indexCount, instanceCount: batch.count,
                        indexBuffer: mesh.indexBuffer,
                        indexType: .uint32, indexOffset: 0, baseVertex: 0, firstInstance: batch.first)
                }
            }
        } catch {
            throw .rhi(error)
        }
    }
}

/// `Instance` dos shaders de cena (2 × `float4x4`, 128 bytes, layout std430).
struct InstanceData {
    var model: CajuMat4
    var normalMatrix: CajuMat4
}

/// `MaterialUniforms` dos shaders de cena (8 × `float4` + `float4x4`, 192 bytes).
struct MaterialUniforms {
    var baseColor = SIMD4<Float>(1, 1, 1, 1)
    var emissive = SIMD4<Float>(0, 0, 0, 0)
    var params = SIMD4<Float>(0, 1, 0, 1)
    var lightDirection = SIMD4<Float>(0, 0, 0, 0)
    var lightColor = SIMD4<Float>(0, 0, 0, 0)
    var ambient = SIMD4<Float>(0, 0, 0, 0)
    var cameraPosition = SIMD4<Float>(0, 0, 0, 1)
    var shadowParams = SIMD4<Float>(0, 0, 0, 0)
    var lightViewProjection = CajuMat4.identity
}
