#if os(Android)
    import CVulkan
    import CajuRHI

    /// Recurso ligado a um *binding* do set 0 durante um passe.
    enum VulkanBoundResource {
        case none
        case buffer(VkBuffer, offset: Int, range: Int)
        case image(VkImageView)
        case sampler(VkSampler)
    }

    extension CajuVulkanDevice {
        /// Grava um passe de render (ADR 0024): valida com as regras comuns do contrato, leva os attachments
        /// com `load` ao layout de attachment, começa o `VkRenderPass` em cache com viewport invertido (NDC com
        /// y para cima e origem no canto superior esquerdo, como no Metal) e termina com cada textura no seu
        /// layout de repouso.
        func recordRenderPass(
            _ descriptor: CajuRenderPassDescriptor, into commandBuffer: VkCommandBuffer,
            _ body: (inout CajuVulkanRenderEncoder) -> Void
        ) throws(CajuRHIError) {
            try CajuRenderPassValidator.validate(
                descriptor,
                maxColorAttachments: min(capabilities.maxColorAttachments, VulkanRenderPassKey.maxColors),
                lookup: { textures.value(for: $0)?.descriptor })
            func record(_ attachment: CajuAttachmentTexture) throws(CajuRHIError) -> VulkanTexture {
                guard case .texture(let handle) = attachment, let texture = textures.value(for: handle) else {
                    throw .invalidHandle(index: 0, generation: 0)
                }
                return texture
            }

            // Até 9 attachments (4 cores, 4 *resolves*, profundidade), sem alocar: tupla de *views*.
            var key = VulkanRenderPassKey()
            var views:
                (
                    VkImageView?, VkImageView?, VkImageView?, VkImageView?, VkImageView?, VkImageView?,
                    VkImageView?, VkImageView?, VkImageView?
                ) = (nil, nil, nil, nil, nil, nil, nil, nil, nil)
            var clears:
                (
                    VkClearValue, VkClearValue, VkClearValue, VkClearValue, VkClearValue, VkClearValue,
                    VkClearValue, VkClearValue, VkClearValue
                ) = (
                    VkClearValue(), VkClearValue(), VkClearValue(), VkClearValue(), VkClearValue(),
                    VkClearValue(), VkClearValue(), VkClearValue(), VkClearValue()
                )
            var viewCount = 0
            var width: UInt32 = 0
            var height: UInt32 = 0
            var colorFormats: (CajuPixelFormat?, CajuPixelFormat?, CajuPixelFormat?, CajuPixelFormat?) = (
                nil, nil, nil, nil
            )
            var samples = 1

            func setView(_ view: VkImageView, _ clear: VkClearValue) {
                withUnsafeMutableBytes(of: &views) {
                    $0.storeBytes(
                        of: view, toByteOffset: viewCount * MemoryLayout<VkImageView?>.stride,
                        as: VkImageView?.self)
                }
                withUnsafeMutableBytes(of: &clears) {
                    $0.storeBytes(
                        of: clear, toByteOffset: viewCount * MemoryLayout<VkClearValue>.stride,
                        as: VkClearValue.self)
                }
                viewCount += 1
            }

            func attachmentKey(
                _ texture: VulkanTexture, load: CajuLoadAction, store: CajuStoreAction, isResolve: Bool
            ) -> VulkanAttachmentKey {
                let attachmentLayout =
                    texture.descriptor.format.isDepth
                    ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
                    : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                var loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
                var initial = VK_IMAGE_LAYOUT_UNDEFINED
                if !isResolve {
                    switch load {
                    case .load:
                        loadOp = VK_ATTACHMENT_LOAD_OP_LOAD
                        initial = attachmentLayout
                    case .clear: loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
                    case .dontCare: break
                    }
                }
                let storeOp: VkAttachmentStoreOp =
                    switch store {
                    case .store, .storeAndResolve: VK_ATTACHMENT_STORE_OP_STORE
                    case .dontCare, .resolve:
                        isResolve ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE
                    }
                return VulkanAttachmentKey(
                    format: texture.descriptor.format.vulkan.rawValue,
                    samples: vulkanSampleCount(texture.descriptor.sampleCount).rawValue,
                    load: loadOp.rawValue,
                    store: storeOp.rawValue, initialLayout: initial.rawValue,
                    finalLayout: (texture.restingLayout ?? attachmentLayout).rawValue)
            }

            func clearValue(_ load: CajuLoadAction, depth: Bool) -> VkClearValue {
                guard case .clear(let v) = load else { return VkClearValue() }
                var value = VkClearValue()
                if depth {
                    value.depthStencil = VkClearDepthStencilValue(depth: v.x, stencil: 0)
                } else {
                    value.color = VkClearColorValue(float32: (v.x, v.y, v.z, v.w))
                }
                return value
            }

            // Cores.
            key.colorCount = UInt8(descriptor.colorAttachments.count)
            for (i, color) in descriptor.colorAttachments.enumerated() {
                let texture = try record(color.texture)
                if case .load = color.load {
                    transition(commandBuffer, texture, to: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
                }
                key[color: i] = attachmentKey(texture, load: color.load, store: color.store, isResolve: false)
                setView(
                    try attachmentView(texture, mipLevel: color.mipLevel, slice: color.slice),
                    clearValue(color.load, depth: false))
                width = UInt32(max(texture.descriptor.width >> color.mipLevel, 1))
                height = UInt32(max(texture.descriptor.height >> color.mipLevel, 1))
                samples = texture.descriptor.sampleCount
                withUnsafeMutableBytes(of: &colorFormats) {
                    $0.storeBytes(
                        of: texture.descriptor.format,
                        toByteOffset: i * MemoryLayout<CajuPixelFormat?>.stride, as: CajuPixelFormat?.self)
                }
            }
            // *Resolves* (depois das cores, na ordem delas).
            for (i, color) in descriptor.colorAttachments.enumerated() {
                guard let target = color.resolveTexture else { continue }
                switch color.store {
                case .resolve, .storeAndResolve: break
                case .store, .dontCare: continue
                }
                let texture = try record(target)
                key.resolveMask |= 1 << i
                key[resolve: i] = attachmentKey(texture, load: .dontCare, store: .store, isResolve: true)
                setView(try attachmentView(texture, mipLevel: 0, slice: 0), VkClearValue())
            }
            // Profundidade.
            var depthFormat: CajuPixelFormat?
            if let depth = descriptor.depthAttachment {
                let texture = try record(depth.texture)
                if case .load = depth.load {
                    transition(commandBuffer, texture, to: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
                }
                key.hasDepth = true
                key.depth = attachmentKey(texture, load: depth.load, store: depth.store, isResolve: false)
                setView(
                    try attachmentView(texture, mipLevel: 0, slice: 0), clearValue(depth.load, depth: true))
                depthFormat = texture.descriptor.format
                if width == 0 {
                    width = UInt32(texture.descriptor.width)
                    height = UInt32(texture.descriptor.height)
                    samples = texture.descriptor.sampleCount
                }
            }

            let renderPass = try self.renderPass(for: key)
            // Sem `throws` tipado no *closure* (o Swift 6.2 cai ao converter para `withUnsafeBytes`).
            let made: Result<VkFramebuffer, CajuRHIError> = withUnsafeBytes(of: &views) { raw in
                do throws(CajuRHIError) {
                    return .success(
                        try self.framebuffer(
                            renderPass: renderPass,
                            views: UnsafeBufferPointer(
                                start: raw.baseAddress?.assumingMemoryBound(to: VkImageView?.self),
                                count: viewCount),
                            width: width, height: height))
                } catch {
                    return .failure(error)
                }
            }
            let framebuffer = try made.get()

            withUnsafeBytes(of: &clears) { raw in
                var begin = VkRenderPassBeginInfo()
                begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
                begin.renderPass = renderPass
                begin.framebuffer = framebuffer
                begin.renderArea = VkRect2D(
                    offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: width, height: height))
                begin.clearValueCount = UInt32(viewCount)
                begin.pClearValues = raw.baseAddress?.assumingMemoryBound(to: VkClearValue.self)
                vkCmdBeginRenderPass(commandBuffer, &begin, VK_SUBPASS_CONTENTS_INLINE)
            }
            for i in boundResources.indices { boundResources[i] = .none }

            var encoder = CajuVulkanRenderEncoder(
                device: self, commandBuffer: commandBuffer, width: Float(width), height: Float(height),
                colorFormats: colorFormats, colorCount: descriptor.colorAttachments.count,
                depthFormat: depthFormat,
                sampleCount: samples)
            encoder.setViewport(CajuViewport(width: Float(width), height: Float(height)))
            encoder.setScissor(CajuScissorRect(x: 0, y: 0, width: Int(width), height: Int(height)))
            body(&encoder)
            vkCmdEndRenderPass(commandBuffer)

            // O render pass já levou cada attachment ao layout final do descritor (o de repouso).
            for color in descriptor.colorAttachments {
                if let texture = try? record(color.texture), let resting = texture.restingLayout {
                    texture.layout = resting
                }
                if let target = color.resolveTexture, let texture = try? record(target),
                    let resting = texture.restingLayout
                {
                    texture.layout = resting
                }
            }
            if let depth = descriptor.depthAttachment, let texture = try? record(depth.texture),
                let resting = texture.restingLayout
            {
                texture.layout = resting
            }
            if let error = encoder.error { throw error }
        }
    }

    public struct CajuVulkanRenderEncoder: CajuRenderEncoder {
        unowned let device: CajuVulkanDevice
        let commandBuffer: VkCommandBuffer
        var error: CajuRHIError?
        private var pipeline: VulkanRenderPipeline?
        private var dirty = true
        private let colorFormats: (CajuPixelFormat?, CajuPixelFormat?, CajuPixelFormat?, CajuPixelFormat?)
        private let colorCount: Int
        private let depthFormat: CajuPixelFormat?
        private let sampleCount: Int

        init(
            device: CajuVulkanDevice, commandBuffer: VkCommandBuffer, width: Float, height: Float,
            colorFormats: (CajuPixelFormat?, CajuPixelFormat?, CajuPixelFormat?, CajuPixelFormat?),
            colorCount: Int,
            depthFormat: CajuPixelFormat?, sampleCount: Int
        ) {
            self.device = device
            self.commandBuffer = commandBuffer
            self.colorFormats = colorFormats
            self.colorCount = colorCount
            self.depthFormat = depthFormat
            self.sampleCount = sampleCount
        }

        private mutating func fail(_ e: CajuRHIError) { if error == nil { error = e } }

        private func passColorFormat(_ index: Int) -> CajuPixelFormat? {
            withUnsafeBytes(of: colorFormats) {
                $0.load(
                    fromByteOffset: index * MemoryLayout<CajuPixelFormat?>.stride, as: CajuPixelFormat?.self)
            }
        }

        public mutating func setPipeline(_ handle: CajuRenderPipelineHandle) {
            guard let p = device.renderPipelines.value(for: handle) else {
                return fail(.invalidHandle(index: handle.index, generation: handle.generation))
            }
            var compatible =
                p.colorFormats.count == colorCount && p.depthFormat == depthFormat
                && p.sampleCount == sampleCount
            for (i, format) in p.colorFormats.enumerated() where compatible {
                compatible = passColorFormat(i) == format
            }
            guard compatible else { return fail(.invalidDescriptor(.formatMismatch)) }
            vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, p.pipeline)
            pipeline = p
            dirty = true
        }

        public mutating func setViewport(_ v: CajuViewport) {
            // Altura negativa (VK_KHR_maintenance1, núcleo no 1.1): y do NDC para cima, origem em cima.
            var viewport = VkViewport(
                x: v.x, y: v.y + v.height, width: v.width, height: -v.height, minDepth: v.near,
                maxDepth: v.far)
            vkCmdSetViewport(commandBuffer, 0, 1, &viewport)
        }

        public mutating func setScissor(_ r: CajuScissorRect) {
            var rect = VkRect2D(
                offset: VkOffset2D(x: Int32(clamping: r.x), y: Int32(clamping: r.y)),
                extent: VkExtent2D(
                    width: UInt32(clamping: max(r.width, 0)), height: UInt32(clamping: max(r.height, 0))))
            vkCmdSetScissor(commandBuffer, 0, 1, &rect)
        }

        public mutating func setVertexBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int) {
            guard let b = device.buffers.value(for: buffer) else {
                return fail(.invalidHandle(index: buffer.index, generation: buffer.generation))
            }
            guard offset >= 0, offset < b.descriptor.size, index >= 0,
                index < device.capabilities.maxVertexBuffers
            else { return fail(.invalidDescriptor(.exceedsDeviceLimit)) }
            var native: VkBuffer? = b.buffer
            var nativeOffset = VkDeviceSize(offset)
            vkCmdBindVertexBuffers(commandBuffer, UInt32(index), 1, &native, &nativeOffset)
        }

        private mutating func bind(
            _ resource: CajuVulkanBindingMap.Resource, index: Int, stage: CajuShaderStage,
            _ value: VulkanBoundResource
        ) {
            guard stage != .compute else { return fail(.invalidUsage(.drawOutsideRenderPass)) }
            guard
                let binding = CajuVulkanBindingMap.binding(
                    resource, index: index, fragment: stage == .fragment)
            else { return fail(.invalidDescriptor(.exceedsDeviceLimit)) }
            device.boundResources[binding] = value
            dirty = true
        }

        public mutating func setBuffer(
            _ buffer: CajuBufferHandle, offset: Int, index: Int, stage: CajuShaderStage
        ) {
            guard let b = device.buffers.value(for: buffer) else {
                return fail(.invalidHandle(index: buffer.index, generation: buffer.generation))
            }
            guard offset >= 0, offset < b.descriptor.size else {
                return fail(.invalidDescriptor(.exceedsDeviceLimit))
            }
            bind(
                .buffer, index: index, stage: stage,
                .buffer(b.buffer, offset: offset, range: b.descriptor.size - offset))
        }

        public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int, stage: CajuShaderStage) {
            guard bytes.count <= 4096 else { return fail(.invalidDescriptor(.exceedsDeviceLimit)) }
            do {
                let offset = try device.uniformRing.push(bytes)
                bind(
                    .buffer, index: index, stage: stage,
                    .buffer(device.uniformRing.buffer, offset: offset, range: max(bytes.count, 1)))
            } catch {
                fail(error)
            }
        }

        public mutating func setTexture(_ texture: CajuTextureHandle, index: Int, stage: CajuShaderStage) {
            guard let t = device.textures.value(for: texture) else {
                return fail(.invalidHandle(index: texture.index, generation: texture.generation))
            }
            guard t.descriptor.usage.contains(.sampled) || t.descriptor.usage.contains(.storage) else {
                return fail(.invalidDescriptor(.incompatibleUsage))
            }
            bind(.texture, index: index, stage: stage, .image(t.view))
        }

        public mutating func setSampler(_ sampler: CajuSamplerHandle, index: Int, stage: CajuShaderStage) {
            guard let s = device.samplers.value(for: sampler) else {
                return fail(.invalidHandle(index: sampler.index, generation: sampler.generation))
            }
            bind(.sampler, index: index, stage: stage, .sampler(s))
        }

        /// Empurra os descritores que o pipeline usa (`vkCmdPushDescriptorSetKHR`), só se algo mudou.
        private mutating func flushBindings() -> Bool {
            guard let pipeline else {
                fail(.invalidUsage(.noPipelineBound))
                return false
            }
            guard dirty else { return true }
            dirty = false
            guard !pipeline.bindings.isEmpty, let push = device.context.pushDescriptorSet else { return true }
            let writes = device.descriptorWrites
            let bufferInfos = device.descriptorBufferInfos
            let imageInfos = device.descriptorImageInfos
            let maxRange = Int(device.context.limits.maxUniformBufferRange)
            var count = 0
            for entry in pipeline.bindings {
                let binding = Int(entry.binding)
                var write = VkWriteDescriptorSet()
                write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                write.dstBinding = entry.binding
                write.descriptorCount = 1
                write.descriptorType = VkDescriptorType(entry.kind.rawValue)
                switch (entry.kind, device.boundResources[binding]) {
                case (.uniformBuffer, .buffer(let buffer, let offset, let range)),
                    (.storageBuffer, .buffer(let buffer, let offset, let range)):
                    let clamped = entry.kind == .uniformBuffer ? min(range, maxRange) : range
                    bufferInfos[count] = VkDescriptorBufferInfo(
                        buffer: buffer, offset: VkDeviceSize(offset), range: VkDeviceSize(clamped))
                    write.pBufferInfo = UnsafePointer(bufferInfos + count)
                case (.sampledImage, .image(let view)):
                    imageInfos[count] = VkDescriptorImageInfo(
                        sampler: nil, imageView: view, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
                    write.pImageInfo = UnsafePointer(imageInfos + count)
                case (.storageImage, .image(let view)):
                    imageInfos[count] = VkDescriptorImageInfo(
                        sampler: nil, imageView: view, imageLayout: VK_IMAGE_LAYOUT_GENERAL)
                    write.pImageInfo = UnsafePointer(imageInfos + count)
                case (.sampler, .sampler(let sampler)):
                    imageInfos[count] = VkDescriptorImageInfo(
                        sampler: sampler, imageView: nil, imageLayout: VK_IMAGE_LAYOUT_UNDEFINED)
                    write.pImageInfo = UnsafePointer(imageInfos + count)
                case (.combinedImageSampler, .image(let view)):
                    // `sampler2D` de GLSL: a textura no índice `i` usa o sampler do mesmo índice e estágio.
                    guard let paired = CajuVulkanBindingMap.samplerPairedWithTexture(binding: binding),
                        case .sampler(let sampler) = device.boundResources[paired]
                    else { continue }
                    imageInfos[count] = VkDescriptorImageInfo(
                        sampler: sampler, imageView: view,
                        imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
                    write.pImageInfo = UnsafePointer(imageInfos + count)
                default:
                    continue  // nada ligado ou tipo trocado: o *draw* lê lixo, como no Metal sem o recurso
                }
                writes[count] = write
                count += 1
            }
            if count > 0 {
                push(
                    commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.layout, 0, UInt32(count), writes)
            }
            return true
        }

        public mutating func draw(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int)
        {
            guard flushBindings() else { return }
            vkCmdDraw(
                commandBuffer, UInt32(clamping: vertexCount), UInt32(clamping: instanceCount),
                UInt32(clamping: firstVertex), UInt32(clamping: firstInstance))
        }

        public mutating func drawIndexed(
            indexCount: Int, instanceCount: Int, indexBuffer: CajuBufferHandle, indexType: CajuIndexType,
            indexOffset: Int, baseVertex: Int, firstInstance: Int
        ) {
            guard flushBindings() else { return }
            guard let b = device.buffers.value(for: indexBuffer) else {
                return fail(.invalidHandle(index: indexBuffer.index, generation: indexBuffer.generation))
            }
            guard indexOffset >= 0, indexOffset % indexType.byteSize == 0, indexOffset < b.descriptor.size
            else {
                return fail(.invalidDescriptor(.exceedsDeviceLimit))
            }
            vkCmdBindIndexBuffer(
                commandBuffer, b.buffer, VkDeviceSize(indexOffset),
                indexType == .uint16 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32)
            vkCmdDrawIndexed(
                commandBuffer, UInt32(clamping: indexCount), UInt32(clamping: instanceCount), 0,
                Int32(clamping: baseVertex), UInt32(clamping: firstInstance))
        }
    }
#endif
