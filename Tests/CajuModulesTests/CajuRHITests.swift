import CajuRHI
import Testing

// `#expect` não aceita chamadas mutantes na expressão: estes auxiliares recebem o valor já avaliado.
private func expectEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a == b, sourceLocation: sourceLocation)
}
private func expectTrue(_ a: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a, sourceLocation: sourceLocation)
}

@Suite("CajuRHI: handles, formatos, orçamento")
struct CajuRHIBasicsTests {
    @Test func handlePoolRejectsStaleHandles() {
        var pool = CajuHandlePool<CajuBufferTag, Int>()
        let a = pool.insert(10)
        #expect(pool.value(for: a) == 10)
        expectEqual(pool.remove(a), 10)
        #expect(pool.value(for: a) == nil)
        let b = pool.insert(20)  // reutiliza a posição com outra geração
        #expect(b.index == a.index)
        #expect(b.generation != a.generation)
        #expect(pool.value(for: a) == nil)
        #expect(pool.value(for: b) == 20)
        #expect(pool.value(for: .null) == nil)
        #expect(pool.count == 1)
    }

    @Test func formatSizes() {
        #expect(CajuPixelFormat.rgba8Unorm.byteSize(width: 4, height: 4) == 64)
        #expect(CajuPixelFormat.astc4x4.byteSize(width: 8, height: 8) == 64)
        #expect(CajuPixelFormat.astc8x8.byteSize(width: 9, height: 9) == 64)  // 2x2 blocos
        #expect(CajuPixelFormat.astc6x6SRGB.isSRGB && CajuPixelFormat.astc6x6SRGB.isCompressed)
        #expect(CajuPixelFormat.depth32FloatStencil8.hasStencil)
        #expect(CajuSampleCounts([.x1, .x4]).supports(4))
        #expect(!CajuSampleCounts([.x1, .x4]).supports(2))
    }

    @Test func uploadBudget() {
        var budget = CajuUploadBudget(bytesPerFrame: 100)
        expectTrue(budget.reserve(60))
        expectTrue(!budget.reserve(60))
        expectTrue(budget.reserve(40))
        budget.beginFrame()
        expectTrue(budget.reserve(500))  // upload maior que o orçamento passa sozinho (sem inanição)
        expectTrue(!budget.reserve(1))
        #expect(budget.remaining == 0)
    }

    @Test func memorylessTextureHasNoBackingBytes() {
        let d = CajuTextureDescriptor(
            format: .rgba8Unorm, width: 256, height: 256, sampleCount: 4, usage: .renderTarget,
            storage: .memoryless)
        #expect(d.estimatedByteSize == 0)
        var backed = d
        backed.storage = .privateGPU
        #expect(backed.estimatedByteSize == 256 * 256 * 4 * 4)
    }
}

@Suite("CajuRHI: backend null")
struct CajuNullDeviceTests {
    @Test func rejectsInvalidDescriptors() throws {
        let device = CajuNullDevice()
        #expect(throws: CajuRHIError.invalidDescriptor(.zeroSize)) {
            try device.createBuffer(CajuBufferDescriptor(size: 0, usage: .vertex))
        }
        #expect(throws: CajuRHIError.invalidDescriptor(.emptyUsage)) {
            try device.createBuffer(CajuBufferDescriptor(size: 4, usage: []))
        }
        #expect(throws: CajuRHIError.unsupported(.sampleCount(8))) {
            try device.createTexture(
                CajuTextureDescriptor(
                    format: .rgba8Unorm, width: 8, height: 8, sampleCount: 8, usage: .renderTarget))
        }
        #expect(throws: CajuRHIError.invalidDescriptor(.incompatibleUsage)) {
            try device.createTexture(
                CajuTextureDescriptor(
                    format: .rgba8Unorm, width: 8, height: 8, usage: [.renderTarget, .sampled],
                    storage: .memoryless))
        }
        #expect(throws: CajuRHIError.invalidDescriptor(.invalidMipCount)) {
            try device.createTexture(
                CajuTextureDescriptor(format: .rgba8Unorm, width: 8, height: 8, mipLevels: 9, usage: .sampled)
            )
        }
    }

    @Test func destroyedHandlesAreRejected() throws {
        let device = CajuNullDevice()
        let buffer = try device.createBuffer(CajuBufferDescriptor(size: 16, usage: .uniform))
        let bytes: [UInt8] = [1, 2, 3, 4]
        try bytes.withUnsafeBytes { try device.writeBuffer(buffer, offset: 4, bytes: $0) }
        #expect(device.contents(of: buffer)?[4...7] == [1, 2, 3, 4])
        device.destroy(buffer)
        #expect(throws: CajuRHIError.self) {
            try bytes.withUnsafeBytes { try device.writeBuffer(buffer, offset: 0, bytes: $0) }
        }
        #expect(device.liveResourceCount == 0)
    }

    @Test func memorylessAttachmentMustNotPersist() throws {
        let device = CajuNullDevice()
        let msaa = try device.createTexture(
            CajuTextureDescriptor(
                format: .bgra8Unorm, width: 64, height: 64, sampleCount: 4, usage: .renderTarget,
                storage: .memoryless))
        let resolve = try device.createTexture(
            CajuTextureDescriptor(format: .bgra8Unorm, width: 64, height: 64, usage: .renderTarget))
        let queue = device.queue

        var cb = try queue.makeCommandBuffer(label: "t")
        // Válido: limpa e resolve, a textura multiamostrada é descartada.
        try cb.withRenderPass(
            CajuRenderPassDescriptor(colorAttachments: [
                CajuColorAttachment(
                    texture: .texture(msaa), load: .clear(SIMD4(0, 0, 0, 1)), store: .resolve,
                    resolveTexture: .texture(resolve))
            ])
        ) { _ in }
        // Inválido: gravar o conteúdo de uma textura sem memória.
        #expect(throws: CajuRHIError.invalidUsage(.memorylessMustNotPersist)) {
            try cb.withRenderPass(
                CajuRenderPassDescriptor(colorAttachments: [
                    CajuColorAttachment(texture: .texture(msaa), load: .dontCare, store: .store)
                ])
            ) { _ in }
        }
        // Inválido: ler (load) de uma textura sem memória.
        #expect(throws: CajuRHIError.invalidUsage(.memorylessMustNotPersist)) {
            try cb.withRenderPass(
                CajuRenderPassDescriptor(colorAttachments: [
                    CajuColorAttachment(texture: .texture(msaa), load: .load, store: .dontCare)
                ])
            ) { _ in }
        }
        try queue.submit(cb)
    }

    @Test func drawWithoutPipelineIsDeferredError() throws {
        let device = CajuNullDevice()
        let target = try device.createTexture(
            CajuTextureDescriptor(format: .bgra8Unorm, width: 8, height: 8, usage: .renderTarget))
        var cb = try device.queue.makeCommandBuffer(label: "t")
        #expect(throws: CajuRHIError.invalidUsage(.noPipelineBound)) {
            try cb.withRenderPass(
                CajuRenderPassDescriptor(colorAttachments: [CajuColorAttachment(texture: .texture(target))])
            ) { encoder in encoder.draw(vertexCount: 3) }
        }
    }

    @Test func swapchainRecreation() throws {
        let device = CajuNullDevice()
        let surface = CajuSurfaceDescriptor(
            kind: .headless, nativeHandle: 0, pixelWidth: 320, pixelHeight: 200)
        let swapchain = try device.createSwapchain(surface)
        let before = device.liveResourceCount
        let image = try swapchain.acquireNextImage()
        #expect(image.width == 320 && image.height == 200)
        var cb = try device.queue.makeCommandBuffer(label: "frame")
        try cb.present(image)
        try device.queue.submit(cb)
        #expect(device.presentCount == 1)

        swapchain.simulateOutOfDate()
        #expect(throws: CajuRHIError.surfaceOutOfDate) { _ = try swapchain.acquireNextImage() }
        var bigger = surface
        bigger.pixelWidth = 640
        try swapchain.recreate(bigger)
        #expect(try swapchain.acquireNextImage().width == 640)

        swapchain.releaseSurface()
        #expect(throws: CajuRHIError.surfaceLost) { _ = try swapchain.acquireNextImage() }
        try swapchain.recreate(bigger)
        #expect(device.liveResourceCount == before)  // sem vazamento de imagens
    }

    @Test func recreateRejectsUnsupportedPresentMode() throws {
        let device = CajuNullDevice()
        var surface = CajuSurfaceDescriptor(kind: .headless, nativeHandle: 0, pixelWidth: 8, pixelHeight: 8)
        let swapchain = try device.createSwapchain(surface)
        surface.presentMode = .immediate
        #expect(throws: CajuRHIError.unsupported(.presentMode(.immediate))) {
            try swapchain.recreate(surface)
        }
    }
}
