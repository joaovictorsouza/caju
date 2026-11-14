#if canImport(Metal)
    import CajuRHI
    import Metal
    import QuartzCore

    public struct CajuMetalQueue: CajuQueue {
        public typealias CommandBuffer = CajuMetalCommandBuffer
        unowned let device: CajuMetalDevice

        public func makeCommandBuffer(label: String) throws(CajuRHIError) -> CajuMetalCommandBuffer {
            guard let cb = device.mtlQueue.makeCommandBuffer() else { throw .deviceLost }
            if !label.isEmpty { cb.label = label }
            return CajuMetalCommandBuffer(device: device, commandBuffer: cb)
        }

        public func submit(_ commandBuffer: consuming CajuMetalCommandBuffer) throws(CajuRHIError) {
            let device = commandBuffer.device
            let cb = commandBuffer.commandBuffer
            for index in commandBuffer.presentedTextures { device.releaseDrawableTexture(index) }
            cb.commit()
        }

        public func waitUntilIdle() throws(CajuRHIError) {
            guard let cb = device.mtlQueue.makeCommandBuffer() else { throw .deviceLost }
            cb.commit()
            cb.waitUntilCompleted()
        }
    }

    public struct CajuMetalCommandBuffer: CajuCommandBuffer, ~Copyable {
        public typealias RenderEncoder = CajuMetalRenderEncoder
        public typealias ComputeEncoder = CajuMetalComputeEncoder
        public typealias CopyEncoder = CajuMetalCopyEncoder

        unowned let device: CajuMetalDevice
        let commandBuffer: any MTLCommandBuffer
        var presentedTextures: [CajuTextureHandle] = []

        init(device: CajuMetalDevice, commandBuffer: any MTLCommandBuffer) {
            self.device = device
            self.commandBuffer = commandBuffer
        }

        public mutating func withRenderPass(
            _ descriptor: CajuRenderPassDescriptor, _ body: (inout CajuMetalRenderEncoder) -> Void
        ) throws(CajuRHIError) {
            try CajuRenderPassValidator.validate(
                descriptor, maxColorAttachments: device.capabilities.maxColorAttachments,
                lookup: { device.textures.value(for: $0)?.descriptor })
            let pass = MTLRenderPassDescriptor()
            func texture(_ t: CajuAttachmentTexture) throws(CajuRHIError) -> any MTLTexture {
                guard case .texture(let h) = t, let record = device.textures.value(for: h) else {
                    throw .invalidHandle(index: 0, generation: 0)
                }
                return record.texture
            }
            for (i, c) in descriptor.colorAttachments.enumerated() {
                let a = pass.colorAttachments[i]
                a?.texture = try texture(c.texture)
                a?.level = c.mipLevel
                a?.slice = c.slice
                a?.loadAction = c.load.metal
                a?.storeAction = c.store.metal
                if case .clear(let v) = c.load {
                    a?.clearColor = MTLClearColor(
                        red: Double(v.x), green: Double(v.y), blue: Double(v.z), alpha: Double(v.w))
                }
                if let r = c.resolveTexture { a?.resolveTexture = try texture(r) }
            }
            if let depth = descriptor.depthAttachment {
                let t = try texture(depth.texture)
                pass.depthAttachment.texture = t
                pass.depthAttachment.loadAction = depth.load.metal
                pass.depthAttachment.storeAction = depth.store.metal
                if case .clear(let v) = depth.load { pass.depthAttachment.clearDepth = Double(v.x) }
                if t.pixelFormat == .depth32Float_stencil8 {
                    pass.stencilAttachment.texture = t
                    pass.stencilAttachment.loadAction = .dontCare
                    pass.stencilAttachment.storeAction = .dontCare
                }
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw .outOfMemory
            }
            if !descriptor.label.isEmpty { encoder.label = descriptor.label }
            var wrapper = CajuMetalRenderEncoder(device: device, encoder: encoder)
            body(&wrapper)
            encoder.endEncoding()
            if let error = wrapper.error { throw error }
        }

        public mutating func withComputePass(label: String, _ body: (inout CajuMetalComputeEncoder) -> Void)
            throws(CajuRHIError)
        {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw .outOfMemory }
            if !label.isEmpty { encoder.label = label }
            var wrapper = CajuMetalComputeEncoder(device: device, encoder: encoder)
            body(&wrapper)
            encoder.endEncoding()
            if let error = wrapper.error { throw error }
        }

        public mutating func withCopyPass(label: String, _ body: (inout CajuMetalCopyEncoder) -> Void)
            throws(CajuRHIError)
        {
            guard let encoder = commandBuffer.makeBlitCommandEncoder() else { throw .outOfMemory }
            if !label.isEmpty { encoder.label = label }
            var wrapper = CajuMetalCopyEncoder(device: device, encoder: encoder)
            body(&wrapper)
            encoder.endEncoding()
            if let error = wrapper.error { throw error }
        }

        public mutating func present(_ image: consuming CajuSwapchainImage) throws(CajuRHIError) {
            let handle = image.texture
            guard let record = device.textures.value(for: handle), let drawable = record.drawable else {
                throw .invalidHandle(index: handle.index, generation: handle.generation)
            }
            commandBuffer.present(drawable)
            presentedTextures.append(handle)
        }
    }

    extension CajuMetalDevice {
        /// Solta a textura e o drawable de uma imagem do *swapchain* depois de apresentada.
        func releaseDrawableTexture(_ handle: CajuTextureHandle) { destroy(handle) }
    }

    public struct CajuMetalRenderEncoder: CajuRenderEncoder, ~Copyable {
        unowned let device: CajuMetalDevice
        let encoder: any MTLRenderCommandEncoder
        var error: CajuRHIError?
        private var topology: MTLPrimitiveType = .triangle
        private var pipelineBound = false

        init(device: CajuMetalDevice, encoder: any MTLRenderCommandEncoder) {
            self.device = device
            self.encoder = encoder
        }

        private mutating func fail(_ e: CajuRHIError) { if error == nil { error = e } }

        public mutating func setPipeline(_ pipeline: CajuRenderPipelineHandle) {
            guard let p = device.renderPipelines.value(for: pipeline) else {
                return fail(.invalidHandle(index: pipeline.index, generation: pipeline.generation))
            }
            encoder.setRenderPipelineState(p.state)
            if let depth = p.depth { encoder.setDepthStencilState(depth) }
            encoder.setCullMode(p.cullMode)
            encoder.setFrontFacing(p.winding)
            topology = p.topology
            pipelineBound = true
        }

        public mutating func setViewport(_ v: CajuViewport) {
            encoder.setViewport(
                MTLViewport(
                    originX: Double(v.x), originY: Double(v.y), width: Double(v.width),
                    height: Double(v.height),
                    znear: Double(v.near), zfar: Double(v.far)))
        }

        public mutating func setScissor(_ r: CajuScissorRect) {
            encoder.setScissorRect(MTLScissorRect(x: r.x, y: r.y, width: r.width, height: r.height))
        }

        public mutating func setVertexBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int) {
            guard let b = device.buffers.value(for: buffer) else {
                return fail(.invalidHandle(index: buffer.index, generation: buffer.generation))
            }
            encoder.setVertexBuffer(b.buffer, offset: offset, index: CajuBufferUsage.metalVertexSlot(index))
        }

        public mutating func setBuffer(
            _ buffer: CajuBufferHandle, offset: Int, index: Int, stage: CajuShaderStage
        ) {
            guard let b = device.buffers.value(for: buffer) else {
                return fail(.invalidHandle(index: buffer.index, generation: buffer.generation))
            }
            switch stage {
            case .vertex: encoder.setVertexBuffer(b.buffer, offset: offset, index: index)
            case .fragment: encoder.setFragmentBuffer(b.buffer, offset: offset, index: index)
            case .compute: fail(.invalidUsage(.drawOutsideRenderPass))
            }
        }

        public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int, stage: CajuShaderStage) {
            guard let base = bytes.baseAddress, bytes.count <= 4096 else {
                return fail(.invalidDescriptor(.exceedsDeviceLimit))
            }
            switch stage {
            case .vertex: encoder.setVertexBytes(base, length: bytes.count, index: index)
            case .fragment: encoder.setFragmentBytes(base, length: bytes.count, index: index)
            case .compute: fail(.invalidUsage(.drawOutsideRenderPass))
            }
        }

        public mutating func setTexture(_ texture: CajuTextureHandle, index: Int, stage: CajuShaderStage) {
            guard let t = device.textures.value(for: texture) else {
                return fail(.invalidHandle(index: texture.index, generation: texture.generation))
            }
            switch stage {
            case .vertex: encoder.setVertexTexture(t.texture, index: index)
            case .fragment: encoder.setFragmentTexture(t.texture, index: index)
            case .compute: fail(.invalidUsage(.drawOutsideRenderPass))
            }
        }

        public mutating func setSampler(_ sampler: CajuSamplerHandle, index: Int, stage: CajuShaderStage) {
            guard let s = device.samplers.value(for: sampler) else {
                return fail(.invalidHandle(index: sampler.index, generation: sampler.generation))
            }
            switch stage {
            case .vertex: encoder.setVertexSamplerState(s, index: index)
            case .fragment: encoder.setFragmentSamplerState(s, index: index)
            case .compute: fail(.invalidUsage(.drawOutsideRenderPass))
            }
        }

        public mutating func draw(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int)
        {
            guard pipelineBound else { return fail(.invalidUsage(.noPipelineBound)) }
            encoder.drawPrimitives(
                type: topology, vertexStart: firstVertex, vertexCount: vertexCount,
                instanceCount: instanceCount,
                baseInstance: firstInstance)
        }

        public mutating func drawIndexed(
            indexCount: Int, instanceCount: Int, indexBuffer: CajuBufferHandle, indexType: CajuIndexType,
            indexOffset: Int, baseVertex: Int, firstInstance: Int
        ) {
            guard pipelineBound else { return fail(.invalidUsage(.noPipelineBound)) }
            guard let b = device.buffers.value(for: indexBuffer) else {
                return fail(.invalidHandle(index: indexBuffer.index, generation: indexBuffer.generation))
            }
            encoder.drawIndexedPrimitives(
                type: topology, indexCount: indexCount, indexType: indexType == .uint16 ? .uint16 : .uint32,
                indexBuffer: b.buffer, indexBufferOffset: indexOffset, instanceCount: instanceCount,
                baseVertex: baseVertex, baseInstance: firstInstance)
        }
    }

    public struct CajuMetalComputeEncoder: CajuComputeEncoder, ~Copyable {
        unowned let device: CajuMetalDevice
        let encoder: any MTLComputeCommandEncoder
        var error: CajuRHIError?

        init(device: CajuMetalDevice, encoder: any MTLComputeCommandEncoder) {
            self.device = device
            self.encoder = encoder
        }

        private mutating func fail(_ e: CajuRHIError) { if error == nil { error = e } }

        public mutating func setPipeline(_ pipeline: CajuComputePipelineHandle) {
            guard let p = device.computePipelines.value(for: pipeline) else {
                return fail(.invalidHandle(index: pipeline.index, generation: pipeline.generation))
            }
            encoder.setComputePipelineState(p)
        }

        public mutating func setBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int) {
            guard let b = device.buffers.value(for: buffer) else {
                return fail(.invalidHandle(index: buffer.index, generation: buffer.generation))
            }
            encoder.setBuffer(b.buffer, offset: offset, index: index)
        }

        public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int) {
            guard let base = bytes.baseAddress, bytes.count <= 4096 else {
                return fail(.invalidDescriptor(.exceedsDeviceLimit))
            }
            encoder.setBytes(base, length: bytes.count, index: index)
        }

        public mutating func setTexture(_ texture: CajuTextureHandle, index: Int) {
            guard let t = device.textures.value(for: texture) else {
                return fail(.invalidHandle(index: texture.index, generation: texture.generation))
            }
            encoder.setTexture(t.texture, index: index)
        }

        public mutating func dispatch(
            groupsX: Int, groupsY: Int, groupsZ: Int, threadsPerGroupX: Int, threadsPerGroupY: Int,
            threadsPerGroupZ: Int
        ) {
            encoder.dispatchThreadgroups(
                MTLSize(groupsX, groupsY, groupsZ),
                threadsPerThreadgroup: MTLSize(threadsPerGroupX, threadsPerGroupY, threadsPerGroupZ))
        }
    }

    public struct CajuMetalCopyEncoder: CajuCopyEncoder, ~Copyable {
        unowned let device: CajuMetalDevice
        let encoder: any MTLBlitCommandEncoder
        var error: CajuRHIError?

        init(device: CajuMetalDevice, encoder: any MTLBlitCommandEncoder) {
            self.device = device
            self.encoder = encoder
        }

        private mutating func fail(_ e: CajuRHIError) { if error == nil { error = e } }

        public mutating func copyBuffer(
            from source: CajuBufferHandle, sourceOffset: Int, to destination: CajuBufferHandle,
            destinationOffset: Int, size: Int
        ) {
            guard let s = device.buffers.value(for: source), let d = device.buffers.value(for: destination),
                sourceOffset >= 0, destinationOffset >= 0, size >= 0,
                sourceOffset + size <= s.descriptor.size, destinationOffset + size <= d.descriptor.size
            else { return fail(.invalidDescriptor(.exceedsDeviceLimit)) }
            encoder.copy(
                from: s.buffer, sourceOffset: sourceOffset, to: d.buffer,
                destinationOffset: destinationOffset,
                size: size)
        }

        public mutating func copyBufferToTexture(
            _ buffer: CajuBufferHandle, bufferOffset: Int, bytesPerRow: Int, to texture: CajuTextureHandle,
            mipLevel: Int, slice: Int, width: Int, height: Int
        ) {
            guard let b = device.buffers.value(for: buffer), let t = device.textures.value(for: texture)
            else {
                return fail(.invalidHandle(index: texture.index, generation: texture.generation))
            }
            let rows = (height + t.descriptor.format.blockHeight - 1) / t.descriptor.format.blockHeight
            encoder.copy(
                from: b.buffer, sourceOffset: bufferOffset, sourceBytesPerRow: bytesPerRow,
                sourceBytesPerImage: bytesPerRow * rows, sourceSize: MTLSize(width, height, 1),
                to: t.texture, destinationSlice: slice, destinationLevel: mipLevel,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }

        public mutating func generateMipmaps(for texture: CajuTextureHandle) {
            guard let t = device.textures.value(for: texture) else {
                return fail(.invalidHandle(index: texture.index, generation: texture.generation))
            }
            encoder.generateMipmaps(for: t.texture)
        }
    }
#endif
