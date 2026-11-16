#if os(Android)
    import CVulkan
    import CajuRHI

    public struct CajuVulkanQueue: CajuQueue {
        public typealias CommandBuffer = CajuVulkanCommandBuffer
        unowned let device: CajuVulkanDevice

        public func makeCommandBuffer(label: String) throws(CajuRHIError) -> CajuVulkanCommandBuffer {
            CajuVulkanCommandBuffer(device: device, handle: try device.context.beginCommandBuffer())
        }

        public func submit(_ commandBuffer: CajuVulkanCommandBuffer) throws(CajuRHIError) {
            try device.context.submit(commandBuffer.handle)
            device.collectGarbage()
        }

        public func waitUntilIdle() throws(CajuRHIError) {
            try device.context.waitIdle()
            device.collectGarbage()
        }
    }

    public struct CajuVulkanCommandBuffer: CajuCommandBuffer {
        public typealias RenderEncoder = CajuVulkanRenderEncoder
        public typealias ComputeEncoder = CajuVulkanComputeEncoder
        public typealias CopyEncoder = CajuVulkanCopyEncoder

        unowned let device: CajuVulkanDevice
        let handle: VkCommandBuffer

        public mutating func withRenderPass(
            _ descriptor: CajuRenderPassDescriptor, _ body: (inout CajuVulkanRenderEncoder) -> Void
        ) throws(CajuRHIError) {
            throw .backend(code: cajuVulkanNotImplementedCode)  // fatia D da V-1
        }

        public mutating func withComputePass(label: String, _ body: (inout CajuVulkanComputeEncoder) -> Void)
            throws(CajuRHIError)
        {
            throw .unsupported(.computePipelines)
        }

        public mutating func withCopyPass(label: String, _ body: (inout CajuVulkanCopyEncoder) -> Void)
            throws(CajuRHIError)
        {
            // Barreira global antes e depois: o que a GPU escreveu antes fica visível à cópia, e a cópia, ao resto.
            Self.memoryBarrier(
                handle, from: VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, to: VK_PIPELINE_STAGE_TRANSFER_BIT)
            var encoder = CajuVulkanCopyEncoder(device: device, commandBuffer: handle)
            body(&encoder)
            Self.memoryBarrier(
                handle, from: VK_PIPELINE_STAGE_TRANSFER_BIT, to: VK_PIPELINE_STAGE_ALL_COMMANDS_BIT)
            if let error = encoder.error { throw error }
        }

        public mutating func present(_ image: consuming CajuSwapchainImage) throws(CajuRHIError) {
            throw .backend(code: cajuVulkanNotImplementedCode)  // fatia E da V-1
        }

        private static func memoryBarrier(
            _ commandBuffer: VkCommandBuffer, from source: VkPipelineStageFlagBits,
            to destination: VkPipelineStageFlagBits
        ) {
            var barrier = VkMemoryBarrier()
            barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
            barrier.srcAccessMask = VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue)
            barrier.dstAccessMask = VkAccessFlags(
                VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue)
            vkCmdPipelineBarrier(
                commandBuffer, VkPipelineStageFlags(source.rawValue),
                VkPipelineStageFlags(destination.rawValue), 0, 1,
                &barrier, 0, nil, 0, nil)
        }
    }

    /// Encoder de render (fatia D da V-1): hoje só existe para o contrato compilar.
    public struct CajuVulkanRenderEncoder: CajuRenderEncoder {
        public mutating func setPipeline(_ pipeline: CajuRenderPipelineHandle) {}
        public mutating func setViewport(_ viewport: CajuViewport) {}
        public mutating func setScissor(_ rect: CajuScissorRect) {}
        public mutating func setVertexBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int) {}
        public mutating func setBuffer(
            _ buffer: CajuBufferHandle, offset: Int, index: Int, stage: CajuShaderStage
        ) {}
        public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int, stage: CajuShaderStage) {}
        public mutating func setTexture(_ texture: CajuTextureHandle, index: Int, stage: CajuShaderStage) {}
        public mutating func setSampler(_ sampler: CajuSamplerHandle, index: Int, stage: CajuShaderStage) {}
        public mutating func draw(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int)
        {}
        public mutating func drawIndexed(
            indexCount: Int, instanceCount: Int, indexBuffer: CajuBufferHandle, indexType: CajuIndexType,
            indexOffset: Int, baseVertex: Int, firstInstance: Int
        ) {}
    }

    /// Compute não faz parte dos gates da Onda 1 (`capabilities.supportsCompute == false`).
    public struct CajuVulkanComputeEncoder: CajuComputeEncoder {
        public mutating func setPipeline(_ pipeline: CajuComputePipelineHandle) {}
        public mutating func setBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int) {}
        public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int) {}
        public mutating func setTexture(_ texture: CajuTextureHandle, index: Int) {}
        public mutating func dispatch(
            groupsX: Int, groupsY: Int, groupsZ: Int, threadsPerGroupX: Int, threadsPerGroupY: Int,
            threadsPerGroupZ: Int
        ) {}
    }

    public struct CajuVulkanCopyEncoder: CajuCopyEncoder {
        unowned let device: CajuVulkanDevice
        let commandBuffer: VkCommandBuffer
        var error: CajuRHIError?

        init(device: CajuVulkanDevice, commandBuffer: VkCommandBuffer) {
            self.device = device
            self.commandBuffer = commandBuffer
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
            guard s.descriptor.usage.contains(.copySource), d.descriptor.usage.contains(.copyDestination)
            else {
                return fail(.invalidDescriptor(.incompatibleUsage))
            }
            var region = VkBufferCopy(
                srcOffset: VkDeviceSize(sourceOffset), dstOffset: VkDeviceSize(destinationOffset),
                size: VkDeviceSize(size))
            vkCmdCopyBuffer(commandBuffer, s.buffer, d.buffer, 1, &region)
        }

        public mutating func copyBufferToTexture(
            _ buffer: CajuBufferHandle, bufferOffset: Int, bytesPerRow: Int, to texture: CajuTextureHandle,
            mipLevel: Int, slice: Int, width: Int, height: Int
        ) {
            guard let b = device.buffers.value(for: buffer), let t = device.textures.value(for: texture)
            else {
                return fail(.invalidHandle(index: texture.index, generation: texture.generation))
            }
            let d = t.descriptor
            guard b.descriptor.usage.contains(.copySource) else {
                return fail(.invalidDescriptor(.incompatibleUsage))
            }
            guard width > 0, height > 0, mipLevel >= 0, mipLevel < d.mipLevels, slice >= 0,
                slice < max(Int(t.layers), 1), bufferOffset >= 0, d.storage != .memoryless,
                bytesPerRow >= d.format.byteSize(width: width, height: 1)
            else { return fail(.invalidDescriptor(.zeroSize)) }
            let rows = (height + d.format.blockHeight - 1) / d.format.blockHeight
            guard bufferOffset + bytesPerRow * rows <= b.descriptor.size else {
                return fail(.invalidDescriptor(.exceedsDeviceLimit))
            }
            device.transition(commandBuffer, t, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
            var region = VkBufferImageCopy(
                bufferOffset: VkDeviceSize(bufferOffset),
                bufferRowLength: UInt32(bytesPerRow / d.format.bytesPerBlock * d.format.blockWidth),
                bufferImageHeight: 0,
                imageSubresource: VkImageSubresourceLayers(
                    aspectMask: d.format.vulkanAspect, mipLevel: UInt32(mipLevel),
                    baseArrayLayer: UInt32(slice),
                    layerCount: 1),
                imageOffset: VkOffset3D(x: 0, y: 0, z: 0),
                imageExtent: VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1))
            vkCmdCopyBufferToImage(
                commandBuffer, b.buffer, t.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
        }

        public mutating func generateMipmaps(for texture: CajuTextureHandle) {
            guard let t = device.textures.value(for: texture) else {
                return fail(.invalidHandle(index: texture.index, generation: texture.generation))
            }
            let d = t.descriptor
            let required =
                VK_FORMAT_FEATURE_BLIT_SRC_BIT.rawValue | VK_FORMAT_FEATURE_BLIT_DST_BIT.rawValue
                | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT.rawValue
            guard d.dimension != .type3D, !d.format.isCompressed, !d.format.isDepth,
                device.context.formatFeatures(d.format.vulkan) & required == required
            else { return fail(.unsupported(.pixelFormat(d.format))) }
            guard d.mipLevels > 1 else { return }
            device.transition(commandBuffer, t, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)

            func barrier(level: UInt32, from: VkImageLayout, to: VkImageLayout) {
                var b = VkImageMemoryBarrier()
                b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
                b.srcAccessMask = VkAccessFlags(
                    (from == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
                        ? VK_ACCESS_TRANSFER_WRITE_BIT : VK_ACCESS_TRANSFER_READ_BIT).rawValue)
                b.dstAccessMask = VkAccessFlags(
                    (to == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
                        ? VK_ACCESS_TRANSFER_READ_BIT : VK_ACCESS_TRANSFER_WRITE_BIT).rawValue)
                b.oldLayout = from
                b.newLayout = to
                b.srcQueueFamilyIndex = UInt32.max
                b.dstQueueFamilyIndex = UInt32.max
                b.image = t.image
                b.subresourceRange = VkImageSubresourceRange(
                    aspectMask: d.format.vulkanAspect, baseMipLevel: level, levelCount: 1, baseArrayLayer: 0,
                    layerCount: t.layers)
                vkCmdPipelineBarrier(
                    commandBuffer, VkPipelineStageFlags(VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue),
                    VkPipelineStageFlags(VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue), 0, 0, nil, 0, nil, 1, &b)
            }
            var width = Int32(d.width)
            var height = Int32(d.height)
            for level in 1..<UInt32(d.mipLevels) {
                barrier(
                    level: level - 1, from: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
                let nextWidth = max(width / 2, 1)
                let nextHeight = max(height / 2, 1)
                var blit = VkImageBlit(
                    srcSubresource: VkImageSubresourceLayers(
                        aspectMask: d.format.vulkanAspect, mipLevel: level - 1, baseArrayLayer: 0,
                        layerCount: t.layers),
                    srcOffsets: (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: width, y: height, z: 1)),
                    dstSubresource: VkImageSubresourceLayers(
                        aspectMask: d.format.vulkanAspect, mipLevel: level, baseArrayLayer: 0,
                        layerCount: t.layers),
                    dstOffsets: (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: nextWidth, y: nextHeight, z: 1)))
                vkCmdBlitImage(
                    commandBuffer, t.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, t.image,
                    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, VK_FILTER_LINEAR)
                width = nextWidth
                height = nextHeight
            }
            // Todos os níveis menos o último estão em TRANSFER_SRC: volta à uniformidade (rastreio por imagem).
            for level in 0..<UInt32(d.mipLevels - 1) {
                barrier(
                    level: level, from: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
            }
        }
    }
#endif
