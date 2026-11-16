#if canImport(Metal)
    import CajuRHI
    import CajuRHIConformance
    import CajuRHIMetal
    import Darwin
    import Metal
    import QuartzCore
    import Testing

    private let metalAvailable = MTLCreateSystemDefaultDevice() != nil

    private let testShaders = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 position [[position]]; };
        vertex VOut vs(uint vid [[vertex_id]]) {
            float2 p[3] = { float2(-0.6, -0.6), float2(0.6, -0.6), float2(0.0, 0.7) };
            VOut o; o.position = float4(p[vid], 0.0, 1.0); return o;
        }
        fragment float4 fs() { return float4(1.0, 0.0, 0.0, 1.0); }
        """

    /// Memória residente do processo em bytes (`mach_task_basic_info`).
    private func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private struct Scene {
        let device: CajuMetalDevice
        let pipeline: CajuRenderPipelineHandle
    }

    private func makeScene(sampleCount: Int = 4) throws -> Scene {
        let device = try CajuMetalDevice.makeSystemDefault()
        let module = try device.createShaderModule(
            CajuShaderModuleDescriptor(format: .metalSource, code: Array(testShaders.utf8), label: "test"))
        let pipeline = try device.createRenderPipeline(
            CajuRenderPipelineDescriptor(
                vertex: CajuShaderFunction(module: module, entryPoint: "vs"),
                fragment: CajuShaderFunction(module: module, entryPoint: "fs"),
                colorTargets: [CajuColorTargetState(format: .bgra8Unorm)], cullMode: .none,
                sampleCount: sampleCount))
        return Scene(device: device, pipeline: pipeline)
    }

    private func pixel(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> (
        b: UInt8, g: UInt8, r: UInt8, a: UInt8
    ) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    /// Backend Metal da suíte genérica de conformidade (`CajuRHIConformance`).
    private struct MetalConformanceBackend: CajuConformanceBackend {
        let device: CajuMetalDevice

        func makeTriangleShaders() throws(CajuRHIError) -> (
            vertex: CajuShaderFunction, fragment: CajuShaderFunction
        ) {
            let module = try device.createShaderModule(
                CajuShaderModuleDescriptor(format: .metalSource, code: Array(testShaders.utf8), label: "test")
            )
            return (
                CajuShaderFunction(module: module, entryPoint: "vs"),
                CajuShaderFunction(module: module, entryPoint: "fs")
            )
        }

        func readTexture(_ texture: CajuTextureHandle) throws(CajuRHIError) -> [UInt8] {
            try device.readTexture(texture)
        }
    }

    @Suite("CajuRHIMetal: suíte genérica de conformidade", .enabled(if: metalAvailable))
    struct CajuMetalGenericConformanceTests {
        @Test func sharedSuitePasses() throws {
            let backend = MetalConformanceBackend(device: try CajuMetalDevice.makeSystemDefault())
            let report = CajuRHIConformance.run(backend)
            #expect(report.failures.isEmpty, "\(report.failures)")
            #expect(report.passed.count == 6)
        }
    }

    @Suite("CajuRHIMetal: conformidade e goldens", .enabled(if: metalAvailable))
    struct CajuMetalConformanceTests {
        /// Golden: triângulo vermelho sobre fundo azul-escuro, MSAA 4x memoryless resolvido em 64x64.
        @Test func msaaMemorylessResolveGolden() throws {
            let scene = try makeScene()
            let device = scene.device
            try #require(device.capabilities.supportsMemoryless)
            let msaa = try device.createTexture(
                CajuTextureDescriptor(
                    format: .bgra8Unorm, width: 64, height: 64, sampleCount: 4, usage: .renderTarget,
                    storage: .memoryless))
            let out = try device.createTexture(
                CajuTextureDescriptor(
                    format: .bgra8Unorm, width: 64, height: 64, usage: [.renderTarget, .sampled],
                    storage: .shared))
            var cb = try device.queue.makeCommandBuffer(label: "golden")
            try cb.withRenderPass(
                CajuRenderPassDescriptor(colorAttachments: [
                    CajuColorAttachment(
                        texture: .texture(msaa), load: .clear(SIMD4(0, 0, 0.5, 1)), store: .resolve,
                        resolveTexture: .texture(out))
                ])
            ) { encoder in
                encoder.setPipeline(scene.pipeline)
                encoder.draw(vertexCount: 3)
            }
            try device.queue.submit(cb)
            try device.queue.waitUntilIdle()
            let bytes = try device.readTexture(out)
            let corner = pixel(bytes, x: 2, y: 2, width: 64)
            #expect(corner == (b: 128, g: 0, r: 0, a: 255))  // fundo
            let center = pixel(bytes, x: 32, y: 36, width: 64)
            #expect(center == (b: 0, g: 0, r: 255, a: 255))  // dentro do triângulo
            // A borda tem pixels mistos: prova que o MSAA resolveu (amostras diferentes no mesmo pixel).
            var blended = 0
            for y in 0..<64 {
                for x in 0..<64 {
                    let p = pixel(bytes, x: x, y: y, width: 64)
                    if p.r > 10, p.r < 245 { blended += 1 }
                }
            }
            #expect(blended > 20)
        }

        /// Conformidade de erros: Metal e null recusam as mesmas violações de memoryless/resolve.
        @Test func validationMatchesNullBackend() throws {
            let metal = try CajuMetalDevice.makeSystemDefault()
            let null = CajuNullDevice()
            let descriptor = CajuTextureDescriptor(
                format: .bgra8Unorm, width: 32, height: 32, sampleCount: 4, usage: .renderTarget,
                storage: .memoryless)
            let resolveDescriptor = CajuTextureDescriptor(
                format: .bgra8Unorm, width: 32, height: 32, usage: .renderTarget)

            func run<D: CajuRenderDevice>(_ device: D) throws -> [CajuRHIError?] {
                let msaa = try device.createTexture(descriptor)
                let resolve = try device.createTexture(resolveDescriptor)
                let cases: [CajuColorAttachment] = [
                    CajuColorAttachment(texture: .texture(msaa), load: .dontCare, store: .store),
                    CajuColorAttachment(texture: .texture(msaa), load: .load, store: .dontCare),
                    CajuColorAttachment(texture: .texture(msaa), load: .dontCare, store: .resolve),
                    CajuColorAttachment(
                        texture: .texture(msaa), load: .dontCare, store: .resolve,
                        resolveTexture: .texture(resolve)),
                ]
                var results: [CajuRHIError?] = []
                for attachment in cases {
                    var cb = try device.queue.makeCommandBuffer(label: "v")
                    do {
                        try cb.withRenderPass(CajuRenderPassDescriptor(colorAttachments: [attachment])) { _ in
                        }
                        results.append(nil)
                    } catch { results.append(error) }
                    try device.queue.submit(cb)
                }
                return results
            }
            let a = try run(metal)
            let b = try run(null)
            #expect(a == b)
            #expect(a[0] == .invalidUsage(.memorylessMustNotPersist))
            #expect(a[1] == .invalidUsage(.memorylessMustNotPersist))
            #expect(a[2] == .invalidUsage(.resolveTargetNotSingleSample))
            #expect(a[3] == nil)
        }

        @Test func handlesAreInvalidAfterDestroy() throws {
            let device = try CajuMetalDevice.makeSystemDefault()
            let buffer = try device.createBuffer(CajuBufferDescriptor(size: 64, usage: .uniform))
            device.destroy(buffer)
            #expect(throws: CajuRHIError.self) {
                try [UInt8](repeating: 0, count: 4).withUnsafeBytes {
                    try device.writeBuffer(buffer, offset: 0, bytes: $0)
                }
            }
            #expect(device.liveResourceCount == 0)
        }

        /// Frame graph no Metal: MSAA e profundidade viram memoryless e os transientes são reutilizados.
        @Test func frameGraphExecutesWithStableMemory() throws {
            let scene = try makeScene()
            let device = scene.device
            var g = CajuFrameGraphBuilder()
            let out = g.importTexture(format: .bgra8Unorm, name: "out")
            let msaa = g.createTransient(
                CajuTextureDescriptor(
                    format: .bgra8Unorm, width: 64, height: 64, sampleCount: 4, usage: .renderTarget),
                name: "msaa")
            g.addPass(
                CajuFrameGraphPass(
                    name: "scene",
                    render: CajuRenderPassDescriptor(colorAttachments: [
                        CajuColorAttachment(
                            texture: .resource(msaa), load: .clear(SIMD4(0, 0, 0.5, 1)), store: .resolve,
                            resolveTexture: .resource(out))
                    ])))
            let graph = try g.compile(capabilities: device.capabilities)
            #expect(graph.stats.memorylessTextures == 1)
            let target = try device.createTexture(
                CajuTextureDescriptor(
                    format: .bgra8Unorm, width: 64, height: 64, usage: [.renderTarget, .sampled],
                    storage: .shared))
            var executor = CajuFrameGraphExecutor()
            executor.prepare(graph)
            var transients = -1
            var allocated = -1
            for frame in 0..<100 {
                executor.bind(out, to: target)
                var cb = try device.queue.makeCommandBuffer(label: "f")
                try executor.execute(graph, device: device, commandBuffer: &cb) { _, encoder in
                    encoder.setPipeline(scene.pipeline)
                    encoder.draw(vertexCount: 3)
                }
                try device.queue.submit(cb)
                if frame == 20 {
                    transients = device.transientTextureCount
                    allocated = device.allocatedBytes
                }
            }
            try device.queue.waitUntilIdle()
            #expect(device.transientTextureCount == transients)
            // O driver aloca memória interna de comandos nos primeiros quadros: após o aquecimento, ≤ 1 MiB.
            #expect(device.allocatedBytes - allocated <= 1 << 20)
            let bytes = try device.readTexture(target)
            #expect(pixel(bytes, x: 32, y: 36, width: 64).r == 255)
        }
    }

    @Suite("CajuRHIMetal: ciclos de superfície", .enabled(if: metalAvailable), .serialized)
    @MainActor
    struct CajuMetalSurfaceCycleTests {
        private func surface(for layer: CAMetalLayer, size: Int) -> CajuSurfaceDescriptor {
            CajuSurfaceDescriptor(
                kind: .metalLayer, nativeHandle: UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque()),
                pixelWidth: size, pixelHeight: size, preferredFormat: .bgra8Unorm, presentMode: .fifo)
        }

        private func renderFrame(_ scene: Scene, _ swapchain: CajuMetalSwapchain) throws {
            let image = try swapchain.acquireNextImage()
            var cb = try scene.device.queue.makeCommandBuffer(label: "frame")
            try cb.withRenderPass(
                CajuRenderPassDescriptor(colorAttachments: [
                    CajuColorAttachment(texture: .texture(image.texture), load: .clear(SIMD4(0, 0, 0.5, 1)))
                ])
            ) { encoder in
                // Pipeline MSAA 4x é incompatível com o alvo de 1 amostra: só limpa o alvo.
                encoder.setViewport(CajuViewport(width: 256, height: 256))
            }
            try cb.present(image)
            try scene.device.queue.submit(cb)
        }

        /// Gate do ADR 0006: 50 ciclos de recriação/background sem vazar recursos (ΔRSS ≤ 1 MB).
        @Test func fiftyBackgroundResumeCycles() throws {
            let scene = try makeScene()
            let layer = CAMetalLayer()
            var descriptor = surface(for: layer, size: 256)
            let swapchain = try scene.device.createSwapchain(descriptor)
            // Aquecimento: caches do driver e do pool de drawables.
            for _ in 0..<5 {
                try renderFrame(scene, swapchain)
                swapchain.releaseSurface()
                scene.device.releaseTransients()
                try swapchain.recreate(descriptor)
            }
            try scene.device.queue.waitUntilIdle()
            let resourcesBefore = scene.device.liveResourceCount
            let rssBefore = residentBytes()
            for cycle in 0..<50 {
                try renderFrame(scene, swapchain)
                try scene.device.queue.waitUntilIdle()
                swapchain.releaseSurface()  // vai para segundo plano
                scene.device.releaseTransients()
                #expect(throws: CajuRHIError.surfaceLost) { _ = try swapchain.acquireNextImage() }
                // Volta com tamanho alternado (rotação): 256 <-> 320.
                descriptor.pixelWidth = cycle % 2 == 0 ? 320 : 256
                descriptor.pixelHeight = descriptor.pixelWidth
                try swapchain.recreate(descriptor)
            }
            try scene.device.queue.waitUntilIdle()
            let deltaMB = Double(residentBytes() - rssBefore) / 1_048_576
            print(
                "TB-2 50 ciclos: ΔRSS = \(deltaMB) MB; recursos vivos \(resourcesBefore) -> \(scene.device.liveResourceCount)"
            )
            #expect(scene.device.liveResourceCount == resourcesBefore)
            #expect(swapchain.recreateCount == 5 + 1 + 50 + 1 - 1 + 1 - 1)
            #expect(deltaMB <= 1.0)
        }

        @Test func outOfDateAfterLayerResize() throws {
            let scene = try makeScene()
            let layer = CAMetalLayer()
            let descriptor = surface(for: layer, size: 128)
            let swapchain = try scene.device.createSwapchain(descriptor)
            layer.drawableSize = CGSize(width: 200, height: 200)  // a plataforma mudou o tamanho
            #expect(throws: CajuRHIError.surfaceOutOfDate) { _ = try swapchain.acquireNextImage() }
            try swapchain.recreate(surface(for: layer, size: 200))
            #expect(try swapchain.acquireNextImage().width == 200)
        }
    }
#endif
