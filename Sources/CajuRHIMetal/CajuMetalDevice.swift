#if canImport(Metal)
    import CajuRHI
    import Metal
    import QuartzCore

    /// Registros do backend: o recurso nativo e o descritor que o criou.
    struct MetalBuffer {
        var buffer: any MTLBuffer
        var descriptor: CajuBufferDescriptor
    }
    struct MetalTexture {
        var texture: any MTLTexture
        var descriptor: CajuTextureDescriptor
        /// Drawable do *swapchain* ligado a esta textura (apresentado no command buffer).
        var drawable: (any CAMetalDrawable)?
    }
    struct MetalShader {
        var library: any MTLLibrary
    }
    struct MetalRenderPipeline {
        var state: any MTLRenderPipelineState
        var depth: (any MTLDepthStencilState)?
        var cullMode: MTLCullMode
        var winding: MTLWinding
        var topology: MTLPrimitiveType
        var sampleCount: Int
    }

    /// Dispositivo Metal do RHI (ADR 0001, ADR 0015).
    ///
    /// Não é `Sendable`: pertence à thread do laço (no iOS/macOS, a principal, por *display link*).
    public final class CajuMetalDevice: CajuRenderDevice {
        public typealias Queue = CajuMetalQueue
        public typealias Swapchain = CajuMetalSwapchain

        public let capabilities: CajuDeviceCapabilities
        public let mtlDevice: any MTLDevice
        let mtlQueue: any MTLCommandQueue

        var buffers = CajuHandlePool<CajuBufferTag, MetalBuffer>()
        var textures = CajuHandlePool<CajuTextureTag, MetalTexture>()
        var samplers = CajuHandlePool<CajuSamplerTag, any MTLSamplerState>()
        var shaders = CajuHandlePool<CajuShaderTag, MetalShader>()
        var renderPipelines = CajuHandlePool<CajuRenderPipelineTag, MetalRenderPipeline>()
        var computePipelines = CajuHandlePool<CajuComputePipelineTag, any MTLComputePipelineState>()
        private var transients: [Int: [(descriptor: CajuTextureDescriptor, handle: CajuTextureHandle)]] = [:]

        /// Cria o dispositivo padrão do sistema.
        public static func makeSystemDefault() throws(CajuRHIError) -> CajuMetalDevice {
            guard let device = MTLCreateSystemDefaultDevice() else { throw .deviceLost }
            return try CajuMetalDevice(device: device)
        }

        public init(device: any MTLDevice) throws(CajuRHIError) {
            guard let queue = device.makeCommandQueue() else { throw .deviceLost }
            mtlDevice = device
            mtlQueue = queue
            var counts: CajuSampleCounts = [.x1]
            for (n, flag) in [(2, CajuSampleCounts.x2), (4, .x4), (8, .x8)]
            where device.supportsTextureSampleCount(n) { counts.insert(flag) }
            let apple = device.supportsFamily(.apple4)
            capabilities = CajuDeviceCapabilities(
                backendName: "Metal", deviceName: device.name,
                maxTextureDimension2D: device.supportsFamily(.apple3) ? 16384 : 8192,
                maxColorAttachments: 8, maxVertexBuffers: 31, maxBufferSize: device.maxBufferLength,
                maxAnisotropy: 16, uniformBufferAlignment: 256, sampleCounts: counts,
                supportsMemoryless: apple, supportsCompute: true,
                supportsASTC: device.supportsFamily(.apple2), presentModes: [.fifo, .immediate])
        }

        public var queue: CajuMetalQueue { CajuMetalQueue(device: self) }

        // MARK: Criação

        public func createBuffer(_ d: CajuBufferDescriptor) throws(CajuRHIError) -> CajuBufferHandle {
            guard d.size > 0 else { throw .invalidDescriptor(.zeroSize) }
            guard d.size <= capabilities.maxBufferSize else { throw .invalidDescriptor(.exceedsDeviceLimit) }
            guard !d.usage.isEmpty else { throw .invalidDescriptor(.emptyUsage) }
            guard d.storage != .memoryless else { throw .invalidDescriptor(.incompatibleUsage) }
            let options: MTLResourceOptions = d.storage == .shared ? .storageModeShared : .storageModePrivate
            guard let buffer = mtlDevice.makeBuffer(length: d.size, options: options) else {
                throw .outOfMemory
            }
            if !d.label.isEmpty { buffer.label = d.label }
            return buffers.insert(MetalBuffer(buffer: buffer, descriptor: d))
        }

        public func createTexture(_ d: CajuTextureDescriptor) throws(CajuRHIError) -> CajuTextureHandle {
            let texture = try makeTexture(d)
            return textures.insert(MetalTexture(texture: texture, descriptor: d, drawable: nil))
        }

        private func makeTexture(_ d: CajuTextureDescriptor) throws(CajuRHIError) -> any MTLTexture {
            guard d.width > 0, d.height > 0, d.depthOrLayers > 0 else { throw .invalidDescriptor(.zeroSize) }
            guard d.width <= capabilities.maxTextureDimension2D,
                d.height <= capabilities.maxTextureDimension2D
            else { throw .invalidDescriptor(.exceedsDeviceLimit) }
            guard !d.usage.isEmpty else { throw .invalidDescriptor(.emptyUsage) }
            guard capabilities.supports(d.format) else { throw .unsupported(.pixelFormat(d.format)) }
            guard d.sampleCount == 1 || capabilities.sampleCounts.supports(d.sampleCount) else {
                throw .unsupported(.sampleCount(d.sampleCount))
            }
            if d.sampleCount > 1,
                d.dimension != .type2D || d.mipLevels != 1 || !d.usage.contains(.renderTarget)
            {
                throw .invalidDescriptor(.invalidSampleCount)
            }
            if d.storage == .memoryless {
                guard capabilities.supportsMemoryless else { throw .unsupported(.memorylessAttachments) }
                guard d.usage == .renderTarget else { throw .invalidDescriptor(.incompatibleUsage) }
            }
            let md = MTLTextureDescriptor()
            md.pixelFormat = d.format.metal
            md.width = d.width
            md.height = d.height
            md.mipmapLevelCount = d.mipLevels
            md.sampleCount = d.sampleCount
            switch d.dimension {
            case .type2D: md.textureType = d.sampleCount > 1 ? .type2DMultisample : .type2D
            case .type2DArray:
                md.textureType = .type2DArray
                md.arrayLength = d.depthOrLayers
            case .cube: md.textureType = .typeCube
            case .type3D:
                md.textureType = .type3D
                md.depth = d.depthOrLayers
            }
            var usage: MTLTextureUsage = []
            if d.usage.contains(.sampled) { usage.insert(.shaderRead) }
            if d.usage.contains(.renderTarget) { usage.insert(.renderTarget) }
            if d.usage.contains(.storage) { usage.insert([.shaderRead, .shaderWrite]) }
            md.usage = usage
            switch d.storage {
            case .shared: md.storageMode = .shared
            case .privateGPU: md.storageMode = .private
            case .memoryless: md.storageMode = .memoryless
            }
            guard let texture = mtlDevice.makeTexture(descriptor: md) else { throw .outOfMemory }
            if !d.label.isEmpty { texture.label = d.label }
            return texture
        }

        public func createSampler(_ d: CajuSamplerDescriptor) throws(CajuRHIError) -> CajuSamplerHandle {
            guard d.maxAnisotropy >= 1, d.maxAnisotropy <= capabilities.maxAnisotropy else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }
            let sd = MTLSamplerDescriptor()
            sd.minFilter = d.minFilter.metal
            sd.magFilter = d.magFilter.metal
            sd.mipFilter = d.mipFilter.metalMip
            sd.sAddressMode = d.addressU.metal
            sd.tAddressMode = d.addressV.metal
            sd.rAddressMode = d.addressW.metal
            sd.maxAnisotropy = d.maxAnisotropy
            guard let sampler = mtlDevice.makeSamplerState(descriptor: sd) else { throw .outOfMemory }
            return samplers.insert(sampler)
        }

        public func createShaderModule(_ d: CajuShaderModuleDescriptor) throws(CajuRHIError)
            -> CajuShaderHandle
        {
            guard !d.code.isEmpty else { throw .invalidDescriptor(.missingShader) }
            let library: any MTLLibrary
            switch d.format {
            case .metalLibrary:
                let data = d.code.withUnsafeBytes { DispatchDataBox.make($0) }
                do { library = try mtlDevice.makeLibrary(data: data) } catch {
                    throw .backend(code: Int32(truncatingIfNeeded: (error as NSError).code))
                }
            case .metalSource:
                // Só para desenvolvimento/testes: o caminho de produção é `.metalLibrary` (offline).
                let source = String(decoding: d.code, as: UTF8.self)
                do { library = try mtlDevice.makeLibrary(source: source, options: nil) } catch {
                    throw .backend(code: Int32(truncatingIfNeeded: (error as NSError).code))
                }
            case .spirv:
                throw .unsupported(.pixelFormat(.rgba8Unorm))
            }
            return shaders.insert(MetalShader(library: library))
        }

        private func function(_ f: CajuShaderFunction) throws(CajuRHIError) -> any MTLFunction {
            guard let shader = shaders.value(for: f.module) else {
                throw .invalidHandle(index: f.module.index, generation: f.module.generation)
            }
            guard let fn = shader.library.makeFunction(name: f.entryPoint) else {
                throw .invalidDescriptor(.missingShader)
            }
            return fn
        }

        public func createRenderPipeline(_ d: CajuRenderPipelineDescriptor) throws(CajuRHIError)
            -> CajuRenderPipelineHandle
        {
            guard d.colorTargets.count <= capabilities.maxColorAttachments else {
                throw .invalidDescriptor(.tooManyAttachments)
            }
            guard d.sampleCount == 1 || capabilities.sampleCounts.supports(d.sampleCount) else {
                throw .unsupported(.sampleCount(d.sampleCount))
            }
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = try function(d.vertex)
            if let f = d.fragment { pd.fragmentFunction = try function(f) }
            pd.rasterSampleCount = d.sampleCount
            pd.inputPrimitiveTopology = d.topology.metalClass
            if !d.label.isEmpty { pd.label = d.label }
            if !d.vertexAttributes.isEmpty {
                let vd = MTLVertexDescriptor()
                for a in d.vertexAttributes {
                    vd.attributes[a.location].format = a.format.metal
                    vd.attributes[a.location].offset = a.offset
                    vd.attributes[a.location].bufferIndex = CajuBufferUsage.metalVertexSlot(a.bufferIndex)
                }
                for l in d.vertexLayouts {
                    let slot = CajuBufferUsage.metalVertexSlot(l.bufferIndex)
                    vd.layouts[slot].stride = l.stride
                    vd.layouts[slot].stepFunction = l.step == .perVertex ? .perVertex : .perInstance
                }
                pd.vertexDescriptor = vd
            }
            for (i, c) in d.colorTargets.enumerated() {
                guard !c.format.isDepth else { throw .invalidDescriptor(.formatMismatch) }
                let ca = pd.colorAttachments[i]
                ca?.pixelFormat = c.format.metal
                if !c.writesAllChannels { ca?.writeMask = [] }
                if let b = c.blend {
                    ca?.isBlendingEnabled = true
                    ca?.sourceRGBBlendFactor = b.sourceColor.metal
                    ca?.destinationRGBBlendFactor = b.destinationColor.metal
                    ca?.rgbBlendOperation = b.colorOperation.metal
                    ca?.sourceAlphaBlendFactor = b.sourceAlpha.metal
                    ca?.destinationAlphaBlendFactor = b.destinationAlpha.metal
                    ca?.alphaBlendOperation = b.alphaOperation.metal
                }
            }
            var depthState: (any MTLDepthStencilState)?
            if let depth = d.depth {
                guard depth.format.isDepth else { throw .invalidDescriptor(.formatMismatch) }
                pd.depthAttachmentPixelFormat = depth.format.metal
                if depth.format.hasStencil { pd.stencilAttachmentPixelFormat = depth.format.metal }
                let dd = MTLDepthStencilDescriptor()
                dd.depthCompareFunction = depth.compare.metal
                dd.isDepthWriteEnabled = depth.writesDepth
                depthState = mtlDevice.makeDepthStencilState(descriptor: dd)
            }
            let state: any MTLRenderPipelineState
            do { state = try mtlDevice.makeRenderPipelineState(descriptor: pd) } catch {
                throw .backend(code: Int32(truncatingIfNeeded: (error as NSError).code))
            }
            let cull: MTLCullMode =
                switch d.cullMode {
                case .none: .none
                case .front: .front
                case .back: .back
                }
            return renderPipelines.insert(
                MetalRenderPipeline(
                    state: state, depth: depthState, cullMode: cull,
                    winding: d.frontFace == .clockwise ? .clockwise : .counterClockwise,
                    topology: d.topology.metal, sampleCount: d.sampleCount))
        }

        public func createComputePipeline(_ d: CajuComputePipelineDescriptor) throws(CajuRHIError)
            -> CajuComputePipelineHandle
        {
            let fn = try function(d.function)
            do { return computePipelines.insert(try mtlDevice.makeComputePipelineState(function: fn)) } catch
            {
                throw .backend(code: Int32(truncatingIfNeeded: (error as NSError).code))
            }
        }

        public func createSwapchain(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError)
            -> CajuMetalSwapchain
        {
            let swapchain = CajuMetalSwapchain(device: self)
            try swapchain.recreate(surface)
            return swapchain
        }

        // MARK: Destruição

        public func destroy(_ buffer: CajuBufferHandle) { buffers.remove(buffer) }
        public func destroy(_ texture: CajuTextureHandle) { textures.remove(texture) }
        public func destroy(_ sampler: CajuSamplerHandle) { samplers.remove(sampler) }
        public func destroy(_ shader: CajuShaderHandle) { shaders.remove(shader) }
        public func destroy(_ pipeline: CajuRenderPipelineHandle) { renderPipelines.remove(pipeline) }
        public func destroy(_ pipeline: CajuComputePipelineHandle) { computePipelines.remove(pipeline) }

        // MARK: Upload

        public func writeBuffer(_ buffer: CajuBufferHandle, offset: Int, bytes: UnsafeRawBufferPointer)
            throws(CajuRHIError)
        {
            guard let record = buffers.value(for: buffer) else {
                throw CajuHandlePool<CajuBufferTag, Int>.invalid(buffer)
            }
            guard record.descriptor.storage == .shared else { throw .invalidDescriptor(.incompatibleUsage) }
            guard offset >= 0, offset + bytes.count <= record.descriptor.size else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }
            guard let base = bytes.baseAddress else { return }
            (record.buffer.contents() + offset).copyMemory(from: base, byteCount: bytes.count)
        }

        public func writeTexture(
            _ texture: CajuTextureHandle, mipLevel: Int, slice: Int, width: Int, height: Int,
            bytesPerRow: Int,
            bytes: UnsafeRawBufferPointer
        ) throws(CajuRHIError) {
            guard let record = textures.value(for: texture) else {
                throw CajuHandlePool<CajuTextureTag, Int>.invalid(texture)
            }
            let d = record.descriptor
            guard width > 0, height > 0, mipLevel >= 0, mipLevel < d.mipLevels, slice >= 0,
                slice < max(d.depthOrLayers, 1), bytesPerRow >= d.format.byteSize(width: width, height: 1),
                d.storage != .memoryless
            else { throw .invalidDescriptor(.zeroSize) }
            let rows = (height + d.format.blockHeight - 1) / d.format.blockHeight
            guard bytes.count >= bytesPerRow * rows, let base = bytes.baseAddress else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }
            let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width, height, 1))
            if d.storage == .shared {
                record.texture.replace(
                    region: region, mipmapLevel: mipLevel, slice: slice, withBytes: base,
                    bytesPerRow: bytesPerRow, bytesPerImage: 0)
                return
            }
            // Textura privada: copia por um buffer de *staging* e espera (caminho de carga, não por quadro).
            guard
                let staging = mtlDevice.makeBuffer(
                    bytes: base, length: bytesPerRow * rows, options: .storageModeShared),
                let cb = mtlQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder()
            else { throw .outOfMemory }
            blit.copy(
                from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
                sourceBytesPerImage: bytesPerRow * rows, sourceSize: MTLSize(width, height, 1),
                to: record.texture, destinationSlice: slice, destinationLevel: mipLevel,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            if cb.status == .error {
                throw .backend(code: Int32(truncatingIfNeeded: (cb.error as NSError?)?.code ?? -1))
            }
        }

        /// Lê o mip 0 de uma textura `shared` (conformidade e *goldens*). Chame `queue.waitUntilIdle()` antes
        /// para garantir que a GPU terminou de escrever. Retorna os bytes linha a linha, sem preenchimento.
        public func readTexture(_ texture: CajuTextureHandle) throws(CajuRHIError) -> [UInt8] {
            guard let record = textures.value(for: texture) else {
                throw CajuHandlePool<CajuTextureTag, Int>.invalid(texture)
            }
            let d = record.descriptor
            guard d.storage == .shared, !d.format.isCompressed, d.sampleCount == 1 else {
                throw .invalidDescriptor(.incompatibleUsage)
            }
            let bytesPerRow = d.format.byteSize(width: d.width, height: 1)
            var out = [UInt8](repeating: 0, count: bytesPerRow * d.height)
            out.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    record.texture.getBytes(
                        base, bytesPerRow: bytesPerRow,
                        from: MTLRegion(
                            origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(d.width, d.height, 1)),
                        mipmapLevel: 0)
                }
            }
            return out
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
            let handle = try createTexture(descriptor)
            transients[slot, default: []].append((descriptor, handle))
            return handle
        }

        public func releaseTransients() {
            for entries in transients.values { for e in entries { textures.remove(e.handle) } }
            transients.removeAll()
        }

        /// Quantidade de recursos vivos de qualquer tipo (diagnóstico de vazamento).
        public var liveResourceCount: Int {
            buffers.count + textures.count + samplers.count + shaders.count + renderPipelines.count
                + computePipelines.count
        }

        /// Texturas transitórias vivas (com ou sem memória).
        public var transientTextureCount: Int { transients.values.reduce(0) { $0 + $1.count } }

        /// Bytes de GPU alocados pelo dispositivo (`currentAllocatedSize`).
        public var allocatedBytes: Int { mtlDevice.currentAllocatedSize }
    }
#endif
