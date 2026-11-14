import CajuMath
import CajuRHI
import CajuRHIMetal
import Foundation

/// Uniformes do cubo; o layout casa com `CubeUniforms` em `Shaders/demo.slang` (colunas de `float4`).
struct CajuCubeUniforms {
    var mvp: CajuMat4
    var model: CajuMat4
    var lightDirection: SIMD4<Float>
    var baseColor: SIMD4<Float>
}

struct CajuUIVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Recursos de GPU e desenho da demo M2: cubo iluminado (MSAA 4x memoryless + depth memoryless, resolvido
/// no backbuffer) e UI (botão com texto) num segundo passe do frame graph.
final class CajuDemoGPU {
    static let sampleCount = 4
    let device: CajuMetalDevice
    private(set) var swapchain: CajuMetalSwapchain
    private var surface: CajuSurfaceDescriptor

    private let cubePipeline: CajuRenderPipelineHandle
    private let uiPipeline: CajuRenderPipelineHandle
    private let cubeVertices: CajuBufferHandle
    private let cubeIndices: CajuBufferHandle
    private let uiBuffers: [CajuBufferHandle]
    private let atlas: CajuTextureHandle
    private let sampler: CajuSamplerHandle

    private var graph = CajuFrameGraphBuilder()
    private var compiled: CajuCompiledFrameGraph?
    private var executor = CajuFrameGraphExecutor()
    private var backbuffer = CajuFrameGraphResource(index: 0)
    private var frameNumber = 0
    private var uiVertexCount = 0

    /// Retângulo do botão em pixels (x, y, largura, altura), atualizado a cada quadro para o toque.
    private(set) var buttonRect = SIMD4<Float>(0, 0, 0, 0)

    init(surface: CajuSurfaceDescriptor) throws {
        let device = try CajuMetalDevice.makeSystemDefault()
        self.device = device
        self.surface = surface
        swapchain = try device.createSwapchain(surface)

        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
            let data = try? Data(contentsOf: url)
        else { throw CajuRHIError.invalidDescriptor(.missingShader) }
        let module = try device.createShaderModule(
            CajuShaderModuleDescriptor(format: .metalLibrary, code: [UInt8](data), label: "demo"))

        let format = surface.preferredFormat
        cubePipeline = try device.createRenderPipeline(
            CajuRenderPipelineDescriptor(
                vertex: CajuShaderFunction(module: module, entryPoint: "cubeVertex"),
                fragment: CajuShaderFunction(module: module, entryPoint: "cubeFragment"),
                vertexAttributes: [
                    CajuVertexAttribute(location: 0, format: .float3, offset: 0, bufferIndex: 0),
                    CajuVertexAttribute(location: 1, format: .float3, offset: 12, bufferIndex: 0),
                    CajuVertexAttribute(location: 2, format: .float2, offset: 24, bufferIndex: 0),
                ],
                vertexLayouts: [CajuVertexBufferLayout(bufferIndex: 0, stride: 32)],
                colorTargets: [CajuColorTargetState(format: format)],
                depth: CajuDepthState(format: .depth32Float), sampleCount: Self.sampleCount, label: "cube"))
        uiPipeline = try device.createRenderPipeline(
            CajuRenderPipelineDescriptor(
                vertex: CajuShaderFunction(module: module, entryPoint: "uiVertex"),
                fragment: CajuShaderFunction(module: module, entryPoint: "uiFragment"),
                vertexAttributes: [
                    CajuVertexAttribute(location: 0, format: .float2, offset: 0, bufferIndex: 0),
                    CajuVertexAttribute(location: 1, format: .float2, offset: 8, bufferIndex: 0),
                    CajuVertexAttribute(location: 2, format: .float4, offset: 16, bufferIndex: 0),
                ],
                vertexLayouts: [CajuVertexBufferLayout(bufferIndex: 0, stride: 32)],
                colorTargets: [CajuColorTargetState(format: format, blend: .alpha)],
                cullMode: .none, label: "ui"))

        // Geometria do cubo (24 vértices, 36 índices).
        var vertices: [Float] = []
        var indices: [UInt16] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)), (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)), (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
        ]
        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        for (n, u, v) in faces {
            let base = UInt16(vertices.count / 8)
            for (cu, cv) in corners {
                let p = (n + u * cu + v * cv) * 0.5
                vertices += [p.x, p.y, p.z, n.x, n.y, n.z, (cu + 1) / 2, (cv + 1) / 2]
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let vb = try device.createBuffer(
            CajuBufferDescriptor(size: vertices.count * 4, usage: .vertex, label: "cube.vertices"))
        let ib = try device.createBuffer(
            CajuBufferDescriptor(size: indices.count * 2, usage: .index, label: "cube.indices"))
        try vertices.withUnsafeBytes { try device.writeBuffer(vb, offset: 0, bytes: $0) }
        try indices.withUnsafeBytes { try device.writeBuffer(ib, offset: 0, bytes: $0) }
        cubeVertices = vb
        cubeIndices = ib

        var ui: [CajuBufferHandle] = []
        for i in 0..<3 {
            ui.append(try device.createBuffer(CajuBufferDescriptor(size: 4096, usage: .vertex, label: "ui.\(i)")))
        }
        uiBuffers = ui

        let atlasTexture = try device.createTexture(
            CajuTextureDescriptor(
                format: .r8Unorm, width: CajuDemoFont.atlasWidth, height: CajuDemoFont.atlasHeight,
                usage: .sampled, storage: .shared, label: "font.atlas"))
        let pixels = CajuDemoFont.makeAtlas()
        try pixels.withUnsafeBytes {
            try device.writeTexture(
                atlasTexture, mipLevel: 0, slice: 0, width: CajuDemoFont.atlasWidth, height: CajuDemoFont.atlasHeight,
                bytesPerRow: CajuDemoFont.atlasWidth, bytes: $0)
        }
        atlas = atlasTexture
        sampler = try device.createSampler(
            CajuSamplerDescriptor(minFilter: .nearest, magFilter: .nearest, mipFilter: .nearest))
        try rebuildGraph()
    }

    // MARK: Superfície

    func recreateSurface(_ new: CajuSurfaceDescriptor) throws {
        surface = new
        try swapchain.recreate(new)
        try rebuildGraph()
    }

    func releaseSurface() {
        swapchain.releaseSurface()
        device.releaseTransients()
    }

    private func rebuildGraph() throws {
        var g = CajuFrameGraphBuilder()
        let back = g.importTexture(format: surface.preferredFormat, name: "backbuffer")
        let msaa = g.createTransient(
            CajuTextureDescriptor(
                format: surface.preferredFormat, width: surface.pixelWidth, height: surface.pixelHeight,
                sampleCount: Self.sampleCount, usage: .renderTarget, label: "msaa"), name: "msaa")
        let depth = g.createTransient(
            CajuTextureDescriptor(
                format: .depth32Float, width: surface.pixelWidth, height: surface.pixelHeight,
                sampleCount: Self.sampleCount, usage: .renderTarget, label: "depth"), name: "depth")
        g.addPass(
            CajuFrameGraphPass(
                name: "scene",
                render: CajuRenderPassDescriptor(
                    colorAttachments: [
                        CajuColorAttachment(
                            texture: .resource(msaa), load: .clear(SIMD4(0.06, 0.07, 0.1, 1)), store: .resolve,
                            resolveTexture: .resource(back))
                    ],
                    depthAttachment: CajuDepthAttachment(texture: .resource(depth), store: .dontCare),
                    label: "scene")))
        g.addPass(
            CajuFrameGraphPass(
                name: "ui",
                render: CajuRenderPassDescriptor(
                    colorAttachments: [CajuColorAttachment(texture: .resource(back), load: .load, store: .store)],
                    label: "ui")))
        let c = try g.compile(capabilities: device.capabilities)
        graph = g
        compiled = c
        backbuffer = back
        executor = CajuFrameGraphExecutor()
        executor.prepare(c)
    }

    var graphStats: CajuFrameGraphStats? { compiled?.stats }

    // MARK: Quadro

    /// Desenha um quadro. `angle` em radianos, `pressed` muda a cor do botão.
    func renderFrame(angle: Float, spinning: Bool) throws {
        guard let compiled else { return }
        let image: CajuSwapchainImage
        do { image = try swapchain.acquireNextImage() } catch {
            switch error {
            case .surfaceOutOfDate:
                try recreateSurface(surface)
                return
            default: return  // `surfaceLost`: a plataforma entrega nova superfície depois
            }
        }
        executor.bind(backbuffer, to: image.texture)

        let w = Float(surface.pixelWidth)
        let h = Float(surface.pixelHeight)
        let aspect = w / h
        let fov: Float = 0.9
        let f = 1 / tanf(fov / 2)
        let near: Float = 0.1
        let far: Float = 20
        let proj = CajuMat4(
            columns: SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0))
        let view = CajuMat4.translation(CajuVec3(0, 0.25, -3.2))
        let axis = CajuVec3(0.4, 1, 0.2).normalized() ?? CajuVec3(0, 1, 0)
        let rotation = CajuQuat(axis: axis, radians: angle) ?? .identity
        let model = CajuMat4.rotation(rotation)
        let uniforms = CajuCubeUniforms(
            mvp: proj * view * model, model: model, lightDirection: SIMD4(-0.5, -0.8, -0.6, 0),
            baseColor: spinning ? SIMD4(0.95, 0.55, 0.2, 1) : SIMD4(0.4, 0.8, 0.5, 1))

        buildUI(width: w, height: h, spinning: spinning)
        let uiBuffer = uiBuffers[frameNumber % 3]
        frameNumber += 1

        var cb = try device.queue.makeCommandBuffer(label: "frame")
        try executor.execute(
            compiled, device: device, commandBuffer: &cb,
            render: { id, encoder in
                if id.index == 0 {
                    encoder.setPipeline(cubePipeline)
                    encoder.setVertexBuffer(cubeVertices, offset: 0, index: 0)
                    withUnsafeBytes(of: uniforms) {
                        encoder.setBytes($0, index: 0, stage: .vertex)
                        encoder.setBytes($0, index: 0, stage: .fragment)
                    }
                    encoder.drawIndexed(
                        indexCount: 36, instanceCount: 1, indexBuffer: cubeIndices, indexType: .uint16,
                        indexOffset: 0, baseVertex: 0, firstInstance: 0)
                } else {
                    encoder.setPipeline(uiPipeline)
                    encoder.setVertexBuffer(uiBuffer, offset: 0, index: 0)
                    var size = SIMD2<Float>(w, h)
                    withUnsafeBytes(of: &size) { encoder.setBytes($0, index: 1, stage: .vertex) }
                    encoder.setTexture(atlas, index: 0, stage: .fragment)
                    encoder.setSampler(sampler, index: 0, stage: .fragment)
                    encoder.draw(vertexCount: uiVertexCount, instanceCount: 1, firstVertex: 0, firstInstance: 0)
                }
            })
        try cb.present(image)
        try device.queue.submit(cb)
    }

    // MARK: UI

    private func buildUI(width w: Float, height h: Float, spinning: Bool) {
        let scale = max(w / 390, 1)
        let bw = 250 * scale
        let bh = 58 * scale
        let bx = (w - bw) / 2
        let by = h - bh - 64 * scale
        buttonRect = SIMD4(bx, by, bw, bh)

        var verts: [CajuUIVertex] = []
        let solid = CajuDemoFont.solidUV
        func quad(_ x: Float, _ y: Float, _ qw: Float, _ qh: Float, _ uv: (Float, Float, Float, Float), _ c: SIMD4<Float>) {
            let (u0, v0, u1, v1) = uv
            let a = CajuUIVertex(position: SIMD2(x, y), uv: SIMD2(u0, v0), color: c)
            let b = CajuUIVertex(position: SIMD2(x + qw, y), uv: SIMD2(u1, v0), color: c)
            let d = CajuUIVertex(position: SIMD2(x + qw, y + qh), uv: SIMD2(u1, v1), color: c)
            let e = CajuUIVertex(position: SIMD2(x, y + qh), uv: SIMD2(u0, v1), color: c)
            verts += [a, b, d, a, d, e]
        }
        let solidRect = (solid.0, solid.1, solid.0, solid.1)
        let border: Float = 3 * scale
        quad(bx - border, by - border, bw + 2 * border, bh + 2 * border, solidRect, SIMD4(1, 1, 1, 0.9))
        quad(bx, by, bw, bh, solidRect, spinning ? SIMD4(0.12, 0.42, 0.92, 1) : SIMD4(0.85, 0.35, 0.12, 1))

        let label = "GIRAR CUBO"
        let ps = 3 * scale
        let textWidth = Float(label.count) * 6 * ps - ps
        var x = bx + (bw - textWidth) / 2
        let y = by + (bh - 7 * ps) / 2
        for ch in label {
            if let uv = CajuDemoFont.uv(of: ch) { quad(x, y, 5 * ps, 7 * ps, uv, SIMD4(1, 1, 1, 1)) }
            x += 6 * ps
        }
        uiVertexCount = verts.count
        let buffer = uiBuffers[frameNumber % 3]
        verts.withUnsafeBytes { try? device.writeBuffer(buffer, offset: 0, bytes: $0) }
    }
}
