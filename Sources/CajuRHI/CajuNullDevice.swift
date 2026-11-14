// Backend "null": implementa o contrato do RHI sem GPU. Serve para testes headless do frame graph,
// do ciclo de vida e de código de render em Linux/CI. Valida descritores e passes como um backend real
// e registra os comandos para inspeção.

/// Comando registrado pelo backend null.
public enum CajuNullCommand: Sendable, Equatable {
    case beginRenderPass(label: String, colorAttachments: Int, hasDepth: Bool)
    case endRenderPass
    case setPipeline(index: UInt32)
    case setViewport
    case setScissor
    case setBuffer(index: Int)
    case setBytes(count: Int)
    case setTexture(index: Int)
    case setSampler(index: Int)
    case draw(vertexCount: Int, instanceCount: Int)
    case drawIndexed(indexCount: Int, instanceCount: Int)
    case computePass(label: String)
    case dispatch(groupsX: Int, groupsY: Int, groupsZ: Int)
    case copyPass(label: String)
    case copyBuffer(size: Int)
    case copyBufferToTexture(width: Int, height: Int)
    case generateMipmaps
    case present(texture: UInt32)
    case submit(label: String)
}

/// Dispositivo de GPU falso, determinístico e sem dependências.
///
/// Não é `Sendable` (como qualquer `CajuRenderDevice`): pertence à thread de jogo.
public final class CajuNullDevice: CajuRenderDevice {
    public typealias Queue = CajuNullQueue
    public typealias Swapchain = CajuNullSwapchain

    public let capabilities: CajuDeviceCapabilities
    public var queue: CajuNullQueue { CajuNullQueue(device: self) }

    // Estado observável nos testes.
    /// Comandos de todos os command buffers submetidos, em ordem.
    public private(set) var submittedCommands: [CajuNullCommand] = []
    public private(set) var submitCount = 0
    public private(set) var presentCount = 0

    var buffers = CajuHandlePool<CajuBufferTag, CajuBufferDescriptor>()
    var textures = CajuHandlePool<CajuTextureTag, CajuTextureDescriptor>()
    var samplers = CajuHandlePool<CajuSamplerTag, CajuSamplerDescriptor>()
    var shaders = CajuHandlePool<CajuShaderTag, CajuShaderModuleDescriptor>()
    var renderPipelines = CajuHandlePool<CajuRenderPipelineTag, CajuRenderPipelineDescriptor>()
    var computePipelines = CajuHandlePool<CajuComputePipelineTag, CajuComputePipelineDescriptor>()
    private var transients: [Int: [(descriptor: CajuTextureDescriptor, handle: CajuTextureHandle)]] = [:]
    private var bufferContents: [UInt32: [UInt8]] = [:]

    public init(capabilities: CajuDeviceCapabilities = CajuNullDevice.defaultCapabilities) {
        self.capabilities = capabilities
    }

    public static let defaultCapabilities = CajuDeviceCapabilities(
        backendName: "Null", deviceName: "Null device", presentModes: [.fifo, .mailbox])

    // MARK: Contabilidade

    /// Recursos vivos (excluindo transientes).
    public var liveResourceCount: Int {
        buffers.count + textures.count - transientTextureCount + samplers.count + shaders.count
            + renderPipelines.count + computePipelines.count
    }

    public var transientTextureCount: Int { transients.values.reduce(0) { $0 + $1.count } }

    /// Bytes de buffers vivos.
    public var bufferBytes: Int { bufferSizeLedger.values.reduce(0, +) }

    private var bufferSizeLedger: [UInt32: Int] = [:]

    /// Memória de texturas transitórias: soma, por slot, do maior ocupante (aliasing); `memoryless` conta 0.
    public var transientBytes: Int {
        transients.values.reduce(0) { $0 + ($1.map { $0.descriptor.estimatedByteSize }.max() ?? 0) }
    }

    /// Conteúdo gravado num buffer (para testes de upload).
    public func contents(of buffer: CajuBufferHandle) -> [UInt8]? {
        guard buffers.value(for: buffer) != nil else { return nil }
        return bufferContents[buffer.index]
    }

    // MARK: Criação de recursos

    public func createBuffer(_ d: CajuBufferDescriptor) throws(CajuRHIError) -> CajuBufferHandle {
        guard d.size > 0 else { throw .invalidDescriptor(.zeroSize) }
        guard d.size <= capabilities.maxBufferSize else { throw .invalidDescriptor(.exceedsDeviceLimit) }
        guard !d.usage.isEmpty else { throw .invalidDescriptor(.emptyUsage) }
        guard d.storage != .memoryless else { throw .invalidDescriptor(.incompatibleUsage) }
        let h = buffers.insert(d)
        bufferSizeLedger[h.index] = d.size
        if d.storage == .shared { bufferContents[h.index] = [UInt8](repeating: 0, count: d.size) }
        return h
    }

    public func createTexture(_ d: CajuTextureDescriptor) throws(CajuRHIError) -> CajuTextureHandle {
        try validate(d)
        return textures.insert(d)
    }

    private func validate(_ d: CajuTextureDescriptor) throws(CajuRHIError) {
        guard d.width > 0, d.height > 0, d.depthOrLayers > 0 else { throw .invalidDescriptor(.zeroSize) }
        guard d.width <= capabilities.maxTextureDimension2D, d.height <= capabilities.maxTextureDimension2D
        else { throw .invalidDescriptor(.exceedsDeviceLimit) }
        guard !d.usage.isEmpty else { throw .invalidDescriptor(.emptyUsage) }
        guard capabilities.supports(d.format) else { throw .unsupported(.pixelFormat(d.format)) }
        guard d.sampleCount == 1 || capabilities.sampleCounts.supports(d.sampleCount) else {
            throw d.sampleCount > 1 && [2, 4, 8].contains(d.sampleCount)
                ? .unsupported(.sampleCount(d.sampleCount)) : .invalidDescriptor(.invalidSampleCount)
        }
        if d.sampleCount > 1 {
            guard d.dimension == .type2D, d.mipLevels == 1, d.usage.contains(.renderTarget) else {
                throw .invalidDescriptor(.invalidSampleCount)
            }
        }
        var maxMips = 1
        var side = max(d.width, d.height)
        while side > 1 {
            side /= 2
            maxMips += 1
        }
        guard d.mipLevels >= 1, d.mipLevels <= maxMips else { throw .invalidDescriptor(.invalidMipCount) }
        if d.storage == .memoryless {
            guard capabilities.supportsMemoryless else { throw .unsupported(.memorylessAttachments) }
            guard d.usage == .renderTarget else { throw .invalidDescriptor(.incompatibleUsage) }
        }
        if d.format.isDepth, d.usage.contains(.storage) { throw .invalidDescriptor(.formatMismatch) }
    }

    public func createSampler(_ d: CajuSamplerDescriptor) throws(CajuRHIError) -> CajuSamplerHandle {
        guard d.maxAnisotropy >= 1, d.maxAnisotropy <= capabilities.maxAnisotropy else {
            throw .invalidDescriptor(.exceedsDeviceLimit)
        }
        return samplers.insert(d)
    }

    public func createShaderModule(_ d: CajuShaderModuleDescriptor) throws(CajuRHIError) -> CajuShaderHandle {
        guard !d.code.isEmpty else { throw .invalidDescriptor(.missingShader) }
        return shaders.insert(d)
    }

    public func createRenderPipeline(_ d: CajuRenderPipelineDescriptor) throws(CajuRHIError)
        -> CajuRenderPipelineHandle
    {
        guard shaders.value(for: d.vertex.module) != nil else {
            throw .invalidHandle(index: d.vertex.module.index, generation: d.vertex.module.generation)
        }
        if let f = d.fragment, shaders.value(for: f.module) == nil {
            throw .invalidHandle(index: f.module.index, generation: f.module.generation)
        }
        guard d.colorTargets.count <= capabilities.maxColorAttachments else {
            throw .invalidDescriptor(.tooManyAttachments)
        }
        guard d.vertexLayouts.count <= capabilities.maxVertexBuffers else {
            throw .invalidDescriptor(.tooManyAttachments)
        }
        guard d.sampleCount == 1 || capabilities.sampleCounts.supports(d.sampleCount) else {
            throw .unsupported(.sampleCount(d.sampleCount))
        }
        for c in d.colorTargets where !capabilities.supports(c.format) || c.format.isDepth {
            throw .invalidDescriptor(.formatMismatch)
        }
        if let depth = d.depth, !depth.format.isDepth { throw .invalidDescriptor(.formatMismatch) }
        return renderPipelines.insert(d)
    }

    public func createComputePipeline(_ d: CajuComputePipelineDescriptor) throws(CajuRHIError)
        -> CajuComputePipelineHandle
    {
        guard capabilities.supportsCompute else { throw .unsupported(.computePipelines) }
        guard shaders.value(for: d.function.module) != nil else {
            throw .invalidHandle(index: d.function.module.index, generation: d.function.module.generation)
        }
        return computePipelines.insert(d)
    }

    public func createSwapchain(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError) -> CajuNullSwapchain {
        let swapchain = CajuNullSwapchain(device: self)
        try swapchain.recreate(surface)
        return swapchain
    }

    // MARK: Destruição

    public func destroy(_ buffer: CajuBufferHandle) {
        if buffers.remove(buffer) != nil {
            bufferSizeLedger[buffer.index] = nil
            bufferContents[buffer.index] = nil
        }
    }
    public func destroy(_ texture: CajuTextureHandle) { textures.remove(texture) }
    public func destroy(_ sampler: CajuSamplerHandle) { samplers.remove(sampler) }
    public func destroy(_ shader: CajuShaderHandle) { shaders.remove(shader) }
    public func destroy(_ pipeline: CajuRenderPipelineHandle) { renderPipelines.remove(pipeline) }
    public func destroy(_ pipeline: CajuComputePipelineHandle) { computePipelines.remove(pipeline) }

    // MARK: Upload

    public func writeBuffer(_ buffer: CajuBufferHandle, offset: Int, bytes: UnsafeRawBufferPointer)
        throws(CajuRHIError)
    {
        guard let d = buffers.value(for: buffer) else {
            throw CajuHandlePool<CajuBufferTag, Int>.invalid(buffer)
        }
        guard d.storage == .shared else { throw .invalidDescriptor(.incompatibleUsage) }
        guard offset >= 0, offset + bytes.count <= d.size else {
            throw .invalidDescriptor(.exceedsDeviceLimit)
        }
        var data = bufferContents[buffer.index] ?? []
        for (i, byte) in bytes.enumerated() { data[offset + i] = byte }
        bufferContents[buffer.index] = data
    }

    public func writeTexture(
        _ texture: CajuTextureHandle, mipLevel: Int, slice: Int, width: Int, height: Int, bytesPerRow: Int,
        bytes: UnsafeRawBufferPointer
    ) throws(CajuRHIError) {
        guard let d = textures.value(for: texture) else {
            throw CajuHandlePool<CajuTextureTag, Int>.invalid(texture)
        }
        guard d.usage.contains(.copyDestination) || d.usage.contains(.sampled) else {
            throw .invalidDescriptor(.incompatibleUsage)
        }
        guard width > 0, height > 0, mipLevel >= 0, mipLevel < d.mipLevels, slice >= 0,
            slice < max(d.depthOrLayers, 1),
            bytesPerRow >= d.format.byteSize(width: width, height: 1)
        else { throw .invalidDescriptor(.zeroSize) }
        let rows = (height + d.format.blockHeight - 1) / d.format.blockHeight
        guard bytes.count >= bytesPerRow * rows else { throw .invalidDescriptor(.exceedsDeviceLimit) }
    }

    // MARK: Transientes

    public func transientTexture(_ descriptor: CajuTextureDescriptor, slot: Int) throws(CajuRHIError)
        -> CajuTextureHandle
    {
        if let entry = transients[slot]?.first(where: { $0.descriptor == descriptor }),
            textures.value(for: entry.handle) != nil
        {
            return entry.handle
        }
        try validate(descriptor)
        let handle = textures.insert(descriptor)
        transients[slot, default: []].append((descriptor, handle))
        return handle
    }

    public func releaseTransients() {
        for entries in transients.values { for e in entries { textures.remove(e.handle) } }
        transients.removeAll()
    }

    // MARK: Interno

    func record(_ commands: [CajuNullCommand]) {
        submittedCommands.append(contentsOf: commands)
    }

    func didSubmit() { submitCount += 1 }
    func didPresent() { presentCount += 1 }

    /// Limpa o registro de comandos (testes que medem um quadro por vez).
    public func clearRecordedCommands() { submittedCommands.removeAll(keepingCapacity: true) }
}

// MARK: - Fila

public struct CajuNullQueue: CajuQueue {
    public typealias CommandBuffer = CajuNullCommandBuffer
    unowned let device: CajuNullDevice

    public func makeCommandBuffer(label: String) throws(CajuRHIError) -> CajuNullCommandBuffer {
        CajuNullCommandBuffer(device: device, label: label)
    }

    public func submit(_ commandBuffer: CajuNullCommandBuffer) throws(CajuRHIError) {
        var commands = commandBuffer.commands
        commands.append(.submit(label: commandBuffer.label))
        device.record(commands)
        device.didSubmit()
        for _ in 0..<commandBuffer.pendingPresents { device.didPresent() }
    }

    public func waitUntilIdle() throws(CajuRHIError) {}
}
