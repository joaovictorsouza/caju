// Command buffer, encoders e swapchain do backend null.

public struct CajuNullCommandBuffer: CajuCommandBuffer, ~Copyable {
    public typealias RenderEncoder = CajuNullRenderEncoder
    public typealias ComputeEncoder = CajuNullComputeEncoder
    public typealias CopyEncoder = CajuNullCopyEncoder

    unowned let device: CajuNullDevice
    let label: String
    var commands: [CajuNullCommand] = []
    var pendingPresents = 0

    init(device: CajuNullDevice, label: String) {
        self.device = device
        self.label = label
    }

    public mutating func withRenderPass(
        _ descriptor: CajuRenderPassDescriptor, _ body: (inout CajuNullRenderEncoder) -> Void
    ) throws(CajuRHIError) {
        try validate(descriptor)
        commands.append(
            .beginRenderPass(
                label: descriptor.label, colorAttachments: descriptor.colorAttachments.count,
                hasDepth: descriptor.depthAttachment != nil))
        var encoder = CajuNullRenderEncoder(device: device)
        body(&encoder)
        commands.append(contentsOf: encoder.commands)
        commands.append(.endRenderPass)
        if let error = encoder.error { throw error }
    }

    public mutating func withComputePass(label: String, _ body: (inout CajuNullComputeEncoder) -> Void)
        throws(CajuRHIError)
    {
        guard device.capabilities.supportsCompute else { throw .unsupported(.computePipelines) }
        commands.append(.computePass(label: label))
        var encoder = CajuNullComputeEncoder()
        body(&encoder)
        commands.append(contentsOf: encoder.commands)
        if let error = encoder.error { throw error }
    }

    public mutating func withCopyPass(label: String, _ body: (inout CajuNullCopyEncoder) -> Void)
        throws(CajuRHIError)
    {
        commands.append(.copyPass(label: label))
        var encoder = CajuNullCopyEncoder(device: device)
        body(&encoder)
        commands.append(contentsOf: encoder.commands)
        if let error = encoder.error { throw error }
    }

    public mutating func present(_ image: consuming CajuSwapchainImage) throws(CajuRHIError) {
        guard device.textures.value(for: image.texture) != nil else {
            throw .invalidHandle(index: image.texture.index, generation: image.texture.generation)
        }
        commands.append(.present(texture: image.texture.index))
        pendingPresents += 1
    }

    /// Regras de validação de um passe (as mesmas que um backend real precisa aplicar).
    private func validate(_ d: CajuRenderPassDescriptor) throws(CajuRHIError) {
        guard d.colorAttachments.count <= device.capabilities.maxColorAttachments else {
            throw .invalidDescriptor(.tooManyAttachments)
        }
        guard !d.colorAttachments.isEmpty || d.depthAttachment != nil else {
            throw .invalidDescriptor(.emptyUsage)
        }
        var size: (Int, Int)?
        var samples: Int?
        func check(
            _ t: CajuAttachmentTexture, load: CajuLoadAction, store: CajuStoreAction,
            resolve: CajuAttachmentTexture?
        ) throws(CajuRHIError) {
            guard case .texture(let h) = t else {
                if case .resource(let r) = t { throw .invalidFrameGraph(.unknownResource(index: r.index)) }
                return
            }
            guard let td = device.textures.value(for: h) else {
                throw .invalidHandle(index: h.index, generation: h.generation)
            }
            guard td.usage.contains(.renderTarget) else { throw .invalidDescriptor(.incompatibleUsage) }
            if let size, size != (td.width, td.height) { throw .invalidUsage(.attachmentSizeMismatch) }
            size = (td.width, td.height)
            if let samples, samples != td.sampleCount { throw .invalidUsage(.attachmentSizeMismatch) }
            samples = td.sampleCount
            if td.storage == .memoryless {
                if case .load = load { throw .invalidUsage(.memorylessMustNotPersist) }
                switch store {
                case .store, .storeAndResolve: throw .invalidUsage(.memorylessMustNotPersist)
                case .dontCare, .resolve: break
                }
            }
            switch store {
            case .resolve, .storeAndResolve:
                guard td.sampleCount > 1, let resolve, case .texture(let rh) = resolve,
                    let rd = device.textures.value(for: rh), rd.sampleCount == 1,
                    (rd.width, rd.height) == (td.width, td.height)
                else { throw .invalidUsage(.resolveTargetNotSingleSample) }
            case .store, .dontCare: break
            }
        }
        for c in d.colorAttachments {
            try check(c.texture, load: c.load, store: c.store, resolve: c.resolveTexture)
        }
        if let depth = d.depthAttachment {
            try check(depth.texture, load: depth.load, store: depth.store, resolve: nil)
        }
    }
}

public struct CajuNullRenderEncoder: CajuRenderEncoder, ~Copyable {
    unowned let device: CajuNullDevice
    var commands: [CajuNullCommand] = []
    var error: CajuRHIError?
    private var pipelineBound = false

    init(device: CajuNullDevice) { self.device = device }

    private mutating func fail(_ e: CajuRHIError) { if error == nil { error = e } }

    public mutating func setPipeline(_ pipeline: CajuRenderPipelineHandle) {
        guard device.renderPipelines.value(for: pipeline) != nil else {
            fail(.invalidHandle(index: pipeline.index, generation: pipeline.generation))
            return
        }
        pipelineBound = true
        commands.append(.setPipeline(index: pipeline.index))
    }

    public mutating func setViewport(_ viewport: CajuViewport) { commands.append(.setViewport) }
    public mutating func setScissor(_ rect: CajuScissorRect) { commands.append(.setScissor) }

    public mutating func setBuffer(
        _ buffer: CajuBufferHandle, offset: Int, index: Int, stage: CajuShaderStage
    ) {
        guard device.buffers.value(for: buffer) != nil else {
            fail(.invalidHandle(index: buffer.index, generation: buffer.generation))
            return
        }
        commands.append(.setBuffer(index: index))
    }

    public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int, stage: CajuShaderStage) {
        commands.append(.setBytes(count: bytes.count))
    }

    public mutating func setTexture(_ texture: CajuTextureHandle, index: Int, stage: CajuShaderStage) {
        guard device.textures.value(for: texture) != nil else {
            fail(.invalidHandle(index: texture.index, generation: texture.generation))
            return
        }
        commands.append(.setTexture(index: index))
    }

    public mutating func setSampler(_ sampler: CajuSamplerHandle, index: Int, stage: CajuShaderStage) {
        guard device.samplers.value(for: sampler) != nil else {
            fail(.invalidHandle(index: sampler.index, generation: sampler.generation))
            return
        }
        commands.append(.setSampler(index: index))
    }

    public mutating func draw(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int) {
        guard pipelineBound else { return fail(.invalidUsage(.noPipelineBound)) }
        commands.append(.draw(vertexCount: vertexCount, instanceCount: instanceCount))
    }

    public mutating func drawIndexed(
        indexCount: Int, instanceCount: Int, indexBuffer: CajuBufferHandle, indexType: CajuIndexType,
        indexOffset: Int, baseVertex: Int, firstInstance: Int
    ) {
        guard pipelineBound else { return fail(.invalidUsage(.noPipelineBound)) }
        guard device.buffers.value(for: indexBuffer) != nil else {
            return fail(.invalidHandle(index: indexBuffer.index, generation: indexBuffer.generation))
        }
        commands.append(.drawIndexed(indexCount: indexCount, instanceCount: instanceCount))
    }
}

public struct CajuNullComputeEncoder: CajuComputeEncoder, ~Copyable {
    var commands: [CajuNullCommand] = []
    var error: CajuRHIError?

    public mutating func setPipeline(_ pipeline: CajuComputePipelineHandle) {
        commands.append(.setPipeline(index: pipeline.index))
    }
    public mutating func setBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int) {
        commands.append(.setBuffer(index: index))
    }
    public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int) {
        commands.append(.setBytes(count: bytes.count))
    }
    public mutating func setTexture(_ texture: CajuTextureHandle, index: Int) {
        commands.append(.setTexture(index: index))
    }
    public mutating func dispatch(
        groupsX: Int, groupsY: Int, groupsZ: Int, threadsPerGroupX: Int, threadsPerGroupY: Int,
        threadsPerGroupZ: Int
    ) {
        commands.append(.dispatch(groupsX: groupsX, groupsY: groupsY, groupsZ: groupsZ))
    }
}

public struct CajuNullCopyEncoder: CajuCopyEncoder, ~Copyable {
    unowned let device: CajuNullDevice
    var commands: [CajuNullCommand] = []
    var error: CajuRHIError?

    init(device: CajuNullDevice) { self.device = device }

    public mutating func copyBuffer(
        from source: CajuBufferHandle, sourceOffset: Int, to destination: CajuBufferHandle,
        destinationOffset: Int, size: Int
    ) {
        guard let s = device.buffers.value(for: source), let d = device.buffers.value(for: destination),
            sourceOffset >= 0, destinationOffset >= 0, size >= 0, sourceOffset + size <= s.size,
            destinationOffset + size <= d.size
        else {
            if error == nil { error = .invalidDescriptor(.exceedsDeviceLimit) }
            return
        }
        commands.append(.copyBuffer(size: size))
    }

    public mutating func copyBufferToTexture(
        _ buffer: CajuBufferHandle, bufferOffset: Int, bytesPerRow: Int, to texture: CajuTextureHandle,
        mipLevel: Int, slice: Int, width: Int, height: Int
    ) {
        guard device.buffers.value(for: buffer) != nil, device.textures.value(for: texture) != nil else {
            if error == nil { error = .invalidHandle(index: texture.index, generation: texture.generation) }
            return
        }
        commands.append(.copyBufferToTexture(width: width, height: height))
    }

    public mutating func generateMipmaps(for texture: CajuTextureHandle) {
        guard device.textures.value(for: texture) != nil else {
            if error == nil { error = .invalidHandle(index: texture.index, generation: texture.generation) }
            return
        }
        commands.append(.generateMipmaps)
    }
}

/// Swapchain falso, com injeção de perda/obsolescência para testar a recriação da superfície.
public final class CajuNullSwapchain: CajuSwapchain {
    unowned let device: CajuNullDevice
    public private(set) var format: CajuPixelFormat = .bgra8UnormSRGB
    public private(set) var pixelWidth = 0
    public private(set) var pixelHeight = 0
    private var images: [CajuTextureHandle] = []
    private var next = 0
    private var surfaceReleased = true
    private var outOfDate = false
    /// Quantas vezes a superfície foi (re)criada (testes de ciclo de vida).
    public private(set) var recreateCount = 0
    public let imageCount = 3

    init(device: CajuNullDevice) { self.device = device }

    /// Simula a plataforma mudando o tamanho da superfície: o próximo `acquireNextImage` falha com
    /// `.surfaceOutOfDate` até `recreate`.
    public func simulateOutOfDate() { outOfDate = true }

    public func acquireNextImage() throws(CajuRHIError) -> CajuSwapchainImage {
        if surfaceReleased { throw .surfaceLost }
        if outOfDate { throw .surfaceOutOfDate }
        let handle = images[next % images.count]
        let index = next % images.count
        next += 1
        return CajuSwapchainImage(
            texture: handle, width: pixelWidth, height: pixelHeight, format: format, imageIndex: index)
    }

    public func recreate(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError) {
        guard surface.pixelWidth > 0, surface.pixelHeight > 0 else { throw .invalidDescriptor(.zeroSize) }
        guard surface.pixelWidth <= device.capabilities.maxTextureDimension2D,
            surface.pixelHeight <= device.capabilities.maxTextureDimension2D
        else { throw .invalidDescriptor(.exceedsDeviceLimit) }
        guard device.capabilities.presentModes.contains(surface.presentMode) else {
            throw .unsupported(.presentMode(surface.presentMode))
        }
        destroyImages()
        let descriptor = CajuTextureDescriptor(
            format: surface.preferredFormat, width: surface.pixelWidth, height: surface.pixelHeight,
            usage: .renderTarget, label: "swapchain")
        var created: [CajuTextureHandle] = []
        for _ in 0..<imageCount {
            do { created.append(try device.createTexture(descriptor)) } catch {
                for h in created { device.destroy(h) }
                throw error
            }
        }
        images = created
        format = surface.preferredFormat
        pixelWidth = surface.pixelWidth
        pixelHeight = surface.pixelHeight
        next = 0
        surfaceReleased = false
        outOfDate = false
        recreateCount += 1
    }

    public func releaseSurface() {
        destroyImages()
        surfaceReleased = true
    }

    private func destroyImages() {
        for h in images { device.destroy(h) }
        images.removeAll()
    }

    deinit {}
}
