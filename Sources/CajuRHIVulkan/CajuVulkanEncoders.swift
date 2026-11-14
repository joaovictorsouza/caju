#if os(Android)
    import Android
    import CajuRHI
    import CVulkan

    struct CajuVulkanPendingPresent {
        let imageIndex: UInt32
    }

    /// Command buffer Vulkan (`~Copyable`) que grava passes de render e agenda apresentação.
    public struct CajuVulkanCommandBuffer: CajuCommandBuffer, ~Copyable {
        public typealias RenderEncoder = CajuVulkanRenderEncoder
        public typealias ComputeEncoder = CajuVulkanComputeEncoder
        public typealias CopyEncoder = CajuVulkanCopyEncoder

        unowned let device: CajuVulkanDevice
        let vkCommandBuffer: VkCommandBuffer?
        let frameSlot: Int
        let label: String
        var pendingPresent: CajuVulkanPendingPresent?

        init(
            device: CajuVulkanDevice,
            vkCommandBuffer: VkCommandBuffer?,
            frameSlot: Int,
            label: String
        ) {
            self.device = device
            self.vkCommandBuffer = vkCommandBuffer
            self.frameSlot = frameSlot
            self.label = label
        }

        /// Grava um passe de render no `VkCommandBuffer`. Sem alocação de heap no caminho quente.
        public mutating func withRenderPass(
            _ descriptor: CajuRenderPassDescriptor,
            _ body: (inout CajuVulkanRenderEncoder) -> Void
        ) throws(CajuRHIError) {
            let resolved = try validateAndResolve(descriptor)

            var clearColor = VkClearValue(
                color: VkClearColorValue(
                    float32: (
                        resolved.clearColor.x,
                        resolved.clearColor.y,
                        resolved.clearColor.z,
                        resolved.clearColor.w
                    )))
            withUnsafePointer(to: &clearColor) { clearPtr in
                var passInfo = VkRenderPassBeginInfo()
                passInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
                passInfo.renderPass = resolved.renderPass
                passInfo.framebuffer = resolved.framebuffer
                passInfo.renderArea = VkRect2D(
                    offset: VkOffset2D(x: 0, y: 0), extent: resolved.extent)
                passInfo.clearValueCount = 1
                passInfo.pClearValues = clearPtr
                vkCmdBeginRenderPass(vkCommandBuffer, &passInfo, VK_SUBPASS_CONTENTS_INLINE)
            }

            var encoder = CajuVulkanRenderEncoder(
                device: device, vkCommandBuffer: vkCommandBuffer)
            body(&encoder)
            vkCmdEndRenderPass(vkCommandBuffer)
            if let error = encoder.error {
                throw error
            }
        }

        /// Compute passes adiados nesta 1ª fatia: lança `.unsupported(.computePipelines)`.
        public mutating func withComputePass(
            label: String, _ body: (inout CajuVulkanComputeEncoder) -> Void
        ) throws(CajuRHIError) {
            throw .unsupported(.computePipelines)
        }

        /// Grava um passe de cópia (suporta `copyBuffer`; cópias para textura/mipmaps lançam `.unsupported`).
        public mutating func withCopyPass(
            label: String, _ body: (inout CajuVulkanCopyEncoder) -> Void
        ) throws(CajuRHIError) {
            var encoder = CajuVulkanCopyEncoder(
                device: device, vkCommandBuffer: vkCommandBuffer)
            body(&encoder)
            if let error = encoder.error {
                throw error
            }
        }

        /// Agenda a apresentação da imagem adquirida da swapchain ao final do `submit`.
        public mutating func present(_ image: consuming CajuSwapchainImage) throws(CajuRHIError) {
            guard device.textures.value(for: image.texture) != nil else {
                throw .invalidHandle(
                    index: image.texture.index, generation: image.texture.generation)
            }
            pendingPresent = CajuVulkanPendingPresent(imageIndex: UInt32(image.imageIndex))
        }

        private struct ResolvedRenderPass {
            let renderPass: VkRenderPass?
            let framebuffer: VkFramebuffer?
            let extent: VkExtent2D
            let clearColor: SIMD4<Float>
        }

        private func validateAndResolve(_ descriptor: CajuRenderPassDescriptor)
            throws(CajuRHIError) -> ResolvedRenderPass
        {
            guard descriptor.colorAttachments.count <= device.capabilities.maxColorAttachments
            else {
                throw .invalidDescriptor(.tooManyAttachments)
            }
            guard !descriptor.colorAttachments.isEmpty || descriptor.depthAttachment != nil else {
                throw .invalidDescriptor(.emptyUsage)
            }

            var targetSize: (Int, Int)?
            var targetSamples: Int?
            var firstTextureRecord: CajuVulkanTextureRecord?

            func checkAttachment(
                _ attachmentTexture: CajuAttachmentTexture,
                load: CajuLoadAction,
                store: CajuStoreAction,
                resolve: CajuAttachmentTexture?
            ) throws(CajuRHIError) -> CajuVulkanTextureRecord {
                guard case .texture(let handle) = attachmentTexture else {
                    if case .resource(let res) = attachmentTexture {
                        throw .invalidFrameGraph(.unknownResource(index: res.index))
                    }
                    throw .invalidDescriptor(.emptyUsage)
                }
                guard let record = device.textures.value(for: handle) else {
                    throw .invalidHandle(index: handle.index, generation: handle.generation)
                }
                let td = record.descriptor
                guard td.usage.contains(.renderTarget) else {
                    throw .invalidDescriptor(.incompatibleUsage)
                }
                if let targetSize, targetSize != (td.width, td.height) {
                    throw .invalidUsage(.attachmentSizeMismatch)
                }
                targetSize = (td.width, td.height)
                if let targetSamples, targetSamples != td.sampleCount {
                    throw .invalidUsage(.attachmentSizeMismatch)
                }
                targetSamples = td.sampleCount
                if td.storage == .memoryless {
                    if case .load = load { throw .invalidUsage(.memorylessMustNotPersist) }
                    switch store {
                    case .store, .storeAndResolve:
                        throw .invalidUsage(.memorylessMustNotPersist)
                    case .dontCare, .resolve:
                        break
                    }
                }
                switch store {
                case .resolve, .storeAndResolve:
                    guard td.sampleCount > 1,
                        let resolve,
                        case .texture(let resolveHandle) = resolve,
                        let resolveRecord = device.textures.value(for: resolveHandle),
                        resolveRecord.descriptor.sampleCount == 1,
                        (resolveRecord.descriptor.width, resolveRecord.descriptor.height)
                            == (td.width, td.height)
                    else {
                        throw .invalidUsage(.resolveTargetNotSingleSample)
                    }
                case .store, .dontCare:
                    break
                }
                return record
            }

            for (index, color) in descriptor.colorAttachments.enumerated() {
                let record = try checkAttachment(
                    color.texture, load: color.load, store: color.store,
                    resolve: color.resolveTexture)
                if index == 0 {
                    firstTextureRecord = record
                }
            }
            if let depth = descriptor.depthAttachment {
                _ = try checkAttachment(
                    depth.texture, load: depth.load, store: depth.store, resolve: nil)
            }

            // Na 1ª fatia, passes operam sobre 1 color attachment da swapchain sem depth.
            guard descriptor.colorAttachments.count == 1,
                descriptor.depthAttachment == nil,
                let firstRecord = firstTextureRecord,
                let imageIndex = firstRecord.swapchainImageIndex,
                let swapchain = device.activeSwapchain,
                imageIndex < swapchain.framebuffers.count
            else {
                throw .invalidDescriptor(.tooManyAttachments)
            }

            let firstColor = descriptor.colorAttachments[0]
            let variant = CajuVulkanTranslation.renderPassVariantIndex(
                load: firstColor.load, store: firstColor.store)
            let clearRGBA: SIMD4<Float> =
                if case .clear(let value) = firstColor.load {
                    value
                } else {
                    SIMD4<Float>(0, 0, 0, 1)
                }

            return ResolvedRenderPass(
                renderPass: swapchain.renderPasses[variant],
                framebuffer: swapchain.framebuffers[imageIndex],
                extent: swapchain.extent,
                clearColor: clearRGBA
            )
        }
    }

    // MARK: - Render Encoder

    /// Encoder Vulkan de comandos de desenho (`~Copyable`, vive apenas dentro de `withRenderPass`).
    public struct CajuVulkanRenderEncoder: CajuRenderEncoder, ~Copyable {
        unowned let device: CajuVulkanDevice
        let vkCommandBuffer: VkCommandBuffer?
        var error: CajuRHIError?
        private var pipelineBound = false
        private var currentPipelineLayout: VkPipelineLayout?
        private var currentPushConstantStages: VkShaderStageFlags = 0

        init(device: CajuVulkanDevice, vkCommandBuffer: VkCommandBuffer?) {
            self.device = device
            self.vkCommandBuffer = vkCommandBuffer
        }

        private mutating func fail(_ err: CajuRHIError) {
            if error == nil { error = err }
        }

        /// Liga o pipeline gráfico atual.
        public mutating func setPipeline(_ pipeline: CajuRenderPipelineHandle) {
            guard let record = device.renderPipelines.value(for: pipeline) else {
                fail(
                    CajuHandlePool<
                        CajuRenderPipelineTag, CajuVulkanRenderPipelineRecord
                    >.invalid(pipeline))
                return
            }
            pipelineBound = true
            currentPipelineLayout = record.layout
            currentPushConstantStages = record.pushConstantStages
            vkCmdBindPipeline(
                vkCommandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, record.pipeline)
        }

        /// Define o viewport dinâmico.
        public mutating func setViewport(_ viewport: CajuViewport) {
            var vkViewport = VkViewport(
                x: viewport.x,
                y: viewport.y,
                width: viewport.width,
                height: viewport.height,
                minDepth: viewport.near,
                maxDepth: viewport.far
            )
            vkCmdSetViewport(vkCommandBuffer, 0, 1, &vkViewport)
        }

        /// Define o retângulo de recorte (scissor) dinâmico.
        public mutating func setScissor(_ rect: CajuScissorRect) {
            var vkScissor = VkRect2D(
                offset: VkOffset2D(x: Int32(rect.x), y: Int32(rect.y)),
                extent: VkExtent2D(
                    width: UInt32(max(rect.width, 0)),
                    height: UInt32(max(rect.height, 0))
                )
            )
            vkCmdSetScissor(vkCommandBuffer, 0, 1, &vkScissor)
        }

        /// Liga um buffer de vértices no slot `index`.
        public mutating func setBuffer(
            _ buffer: CajuBufferHandle, offset: Int, index: Int, stage: CajuShaderStage
        ) {
            guard let record = device.buffers.value(for: buffer) else {
                fail(CajuHandlePool<CajuBufferTag, CajuVulkanBufferRecord>.invalid(buffer))
                return
            }
            guard offset >= 0, offset <= record.descriptor.size,
                index >= 0, index < device.capabilities.maxVertexBuffers
            else {
                fail(.invalidDescriptor(.exceedsDeviceLimit))
                return
            }
            var vkBuf: VkBuffer? = record.buffer
            var vkOff = VkDeviceSize(offset)
            vkCmdBindVertexBuffers(vkCommandBuffer, UInt32(index), 1, &vkBuf, &vkOff)
        }

        /// Envia constantes pequenas inline via `vkCmdPushConstants` (até 128 B nesta fatia).
        public mutating func setBytes(
            _ bytes: UnsafeRawBufferPointer, index: Int, stage: CajuShaderStage
        ) {
            guard pipelineBound, let layout = currentPipelineLayout else {
                fail(.invalidUsage(.noPipelineBound))
                return
            }
            guard bytes.count > 0,
                bytes.count <= CajuVulkanDevice.maxPushConstantBytes,
                let base = bytes.baseAddress
            else {
                fail(.invalidDescriptor(.exceedsDeviceLimit))
                return
            }
            vkCmdPushConstants(
                vkCommandBuffer,
                layout,
                currentPushConstantStages,
                0,
                UInt32(bytes.count),
                base
            )
        }

        /// Ligação de textura amostrada (adiada nesta 1ª fatia: acumula `.unsupported`).
        public mutating func setTexture(
            _ texture: CajuTextureHandle, index: Int, stage: CajuShaderStage
        ) {
            guard let record = device.textures.value(for: texture) else {
                fail(CajuHandlePool<CajuTextureTag, CajuVulkanTextureRecord>.invalid(texture))
                return
            }
            fail(.unsupported(.pixelFormat(record.descriptor.format)))
        }

        /// Ligação de sampler (adiada nesta 1ª fatia).
        public mutating func setSampler(
            _ sampler: CajuSamplerHandle, index: Int, stage: CajuShaderStage
        ) {
            fail(.invalidHandle(index: sampler.index, generation: sampler.generation))
        }

        /// Emite comando de desenho não indexado (`vkCmdDraw`).
        public mutating func draw(
            vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int
        ) {
            guard pipelineBound else {
                fail(.invalidUsage(.noPipelineBound))
                return
            }
            guard vertexCount >= 0, instanceCount >= 0, firstVertex >= 0, firstInstance >= 0 else {
                fail(.invalidDescriptor(.zeroSize))
                return
            }
            vkCmdDraw(
                vkCommandBuffer,
                UInt32(vertexCount),
                UInt32(instanceCount),
                UInt32(firstVertex),
                UInt32(firstInstance)
            )
        }

        /// Liga o buffer de índices e emite comando de desenho indexado (`vkCmdDrawIndexed`).
        public mutating func drawIndexed(
            indexCount: Int,
            instanceCount: Int,
            indexBuffer: CajuBufferHandle,
            indexType: CajuIndexType,
            indexOffset: Int,
            baseVertex: Int,
            firstInstance: Int
        ) {
            guard pipelineBound else {
                fail(.invalidUsage(.noPipelineBound))
                return
            }
            guard let record = device.buffers.value(for: indexBuffer) else {
                fail(
                    CajuHandlePool<CajuBufferTag, CajuVulkanBufferRecord>.invalid(indexBuffer))
                return
            }
            guard indexOffset >= 0, indexCount >= 0, instanceCount >= 0, firstInstance >= 0,
                indexOffset + indexCount * indexType.byteSize <= record.descriptor.size
            else {
                fail(.invalidDescriptor(.exceedsDeviceLimit))
                return
            }
            let vkIdxType = VkIndexType(
                rawValue: CajuVulkanTranslation.vkIndexType(for: indexType))
            vkCmdBindIndexBuffer(
                vkCommandBuffer, record.buffer, VkDeviceSize(indexOffset), vkIdxType)
            vkCmdDrawIndexed(
                vkCommandBuffer,
                UInt32(indexCount),
                UInt32(instanceCount),
                0,
                Int32(baseVertex),
                UInt32(firstInstance)
            )
        }
    }

    // MARK: - Compute e Copy Encoders

    /// Encoder de compute (adiado nesta 1ª fatia).
    public struct CajuVulkanComputeEncoder: CajuComputeEncoder, ~Copyable {
        var error: CajuRHIError? = .unsupported(.computePipelines)

        public mutating func setPipeline(_ pipeline: CajuComputePipelineHandle) {}
        public mutating func setBuffer(_ buffer: CajuBufferHandle, offset: Int, index: Int) {}
        public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int) {}
        public mutating func setTexture(_ texture: CajuTextureHandle, index: Int) {}
        public mutating func dispatch(
            groupsX: Int, groupsY: Int, groupsZ: Int,
            threadsPerGroupX: Int, threadsPerGroupY: Int, threadsPerGroupZ: Int
        ) {}
    }

    /// Encoder de cópia Vulkan (`copyBuffer` via `vkCmdCopyBuffer`; texturas/mipmaps adiados).
    public struct CajuVulkanCopyEncoder: CajuCopyEncoder, ~Copyable {
        unowned let device: CajuVulkanDevice
        let vkCommandBuffer: VkCommandBuffer?
        var error: CajuRHIError?

        init(device: CajuVulkanDevice, vkCommandBuffer: VkCommandBuffer?) {
            self.device = device
            self.vkCommandBuffer = vkCommandBuffer
        }

        private mutating func fail(_ err: CajuRHIError) {
            if error == nil { error = err }
        }

        /// Copia uma região entre dois buffers Vulkan (`vkCmdCopyBuffer`).
        public mutating func copyBuffer(
            from source: CajuBufferHandle,
            sourceOffset: Int,
            to destination: CajuBufferHandle,
            destinationOffset: Int,
            size: Int
        ) {
            guard let src = device.buffers.value(for: source) else {
                fail(CajuHandlePool<CajuBufferTag, CajuVulkanBufferRecord>.invalid(source))
                return
            }
            guard let dst = device.buffers.value(for: destination) else {
                fail(CajuHandlePool<CajuBufferTag, CajuVulkanBufferRecord>.invalid(destination))
                return
            }
            guard sourceOffset >= 0, destinationOffset >= 0, size > 0,
                sourceOffset + size <= src.descriptor.size,
                destinationOffset + size <= dst.descriptor.size
            else {
                fail(.invalidDescriptor(.exceedsDeviceLimit))
                return
            }
            var region = VkBufferCopy(
                srcOffset: VkDeviceSize(sourceOffset),
                dstOffset: VkDeviceSize(destinationOffset),
                size: VkDeviceSize(size)
            )
            vkCmdCopyBuffer(vkCommandBuffer, src.buffer, dst.buffer, 1, &region)
        }

        /// Cópia de buffer para textura adiada nesta 1ª fatia.
        public mutating func copyBufferToTexture(
            _ buffer: CajuBufferHandle,
            bufferOffset: Int,
            bytesPerRow: Int,
            to texture: CajuTextureHandle,
            mipLevel: Int,
            slice: Int,
            width: Int,
            height: Int
        ) {
            guard device.buffers.value(for: buffer) != nil else {
                fail(CajuHandlePool<CajuBufferTag, CajuVulkanBufferRecord>.invalid(buffer))
                return
            }
            guard let tex = device.textures.value(for: texture) else {
                fail(CajuHandlePool<CajuTextureTag, CajuVulkanTextureRecord>.invalid(texture))
                return
            }
            fail(.unsupported(.pixelFormat(tex.descriptor.format)))
        }

        /// Geração de mipmaps adiada nesta 1ª fatia.
        public mutating func generateMipmaps(for texture: CajuTextureHandle) {
            guard let tex = device.textures.value(for: texture) else {
                fail(CajuHandlePool<CajuTextureTag, CajuVulkanTextureRecord>.invalid(texture))
                return
            }
            fail(.unsupported(.pixelFormat(tex.descriptor.format)))
        }
    }

    // MARK: - Swapchain

    /// Swapchain Vulkan (`VkSwapchainKHR`) sobre uma `ANativeWindow` Android.
    ///
    /// Gerencia a superfície `VkSurfaceKHR`, as imagens apresentáveis, seus `VkImageView`s,
    /// `VkFramebuffer`s, semáforos `renderFinished` e as 6 variantes de `VkRenderPass`
    /// para combinações de `(loadOp, storeOp)`.
    public final class CajuVulkanSwapchain: CajuSwapchain {
        let device: CajuVulkanDevice
        public private(set) var format: CajuPixelFormat = .bgra8UnormSRGB
        public private(set) var pixelWidth = 0
        public private(set) var pixelHeight = 0

        private var currentWindowHandle: UInt = 0
        private var vkSurface: VkSurfaceKHR?
        var vkSwapchain: VkSwapchainKHR?
        var swapchainVkFormat = VK_FORMAT_UNDEFINED
        var extent = VkExtent2D()
        private var vkImages: [VkImage?] = []
        private var imageViews: [VkImageView?] = []
        var framebuffers: [VkFramebuffer?] = []
        var renderFinished: [VkSemaphore?] = []
        var renderPasses = [VkRenderPass?](repeating: nil, count: 6)
        private var textureHandles: [CajuTextureHandle] = []
        private var surfaceReleased = true
        private var outOfDate = false

        init(device: CajuVulkanDevice) {
            self.device = device
        }

        deinit {
            releaseSurface()
        }

        func markOutOfDate() {
            outOfDate = true
        }

        /// Adquire a próxima imagem apresentável da `VkSwapchainKHR`.
        /// Lança `.surfaceLost` se a superfície foi liberada ou `.surfaceOutOfDate` se precisa de `recreate`.
        public func acquireNextImage() throws(CajuRHIError) -> CajuSwapchainImage {
            if surfaceReleased || vkSwapchain == nil {
                throw .surfaceLost
            }
            if outOfDate {
                throw .surfaceOutOfDate
            }

            try device.ensureFrameReady()
            let slot = device.frameIndex
            var imageIndex: UInt32 = 0
            let acquireResult = vkAcquireNextImageKHR(
                device.vkDevice,
                vkSwapchain,
                UInt64.max,
                device.imageAvailable[slot],
                nil,
                &imageIndex
            )
            if acquireResult == VK_ERROR_OUT_OF_DATE_KHR {
                outOfDate = true
                throw .surfaceOutOfDate
            }
            if acquireResult == VK_ERROR_SURFACE_LOST_KHR {
                surfaceReleased = true
                throw .surfaceLost
            }
            guard acquireResult == VK_SUCCESS || acquireResult == VK_SUBOPTIMAL_KHR else {
                throw CajuVulkanTranslation.rhiError(fromVkResult: acquireResult.rawValue)
            }
            let idx = Int(imageIndex)
            guard idx < textureHandles.count else {
                throw .surfaceOutOfDate
            }
            device.frameImageAcquired = true
            device.activeSwapchain = self
            return CajuSwapchainImage(
                texture: textureHandles[idx],
                width: pixelWidth,
                height: pixelHeight,
                format: format,
                imageIndex: idx
            )
        }

        /// Recria a `VkSwapchainKHR` (e a `VkSurfaceKHR` caso o ponteiro da `ANativeWindow` tenha mudado).
        public func recreate(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError) {
            try CajuVulkanTranslation.validateSurfaceDescriptor(
                surface, capabilities: device.capabilities)
            guard let windowPtr = UnsafeMutableRawPointer(bitPattern: surface.nativeHandle) else {
                throw .surfaceLost
            }

            vkDeviceWaitIdle(device.vkDevice)
            destroySwapchainObjects()

            if currentWindowHandle != surface.nativeHandle || vkSurface == nil {
                destroySurface()
                var surfaceInfo = VkAndroidSurfaceCreateInfoKHR()
                surfaceInfo.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR
                surfaceInfo.window = OpaquePointer(windowPtr)
                var createdSurface: VkSurfaceKHR?
                try checkVk(
                    vkCreateAndroidSurfaceKHR(
                        device.instance, &surfaceInfo, nil, &createdSurface))
                guard let validSurface = createdSurface else {
                    throw .surfaceLost
                }
                var supported: VkBool32 = 0
                vkGetPhysicalDeviceSurfaceSupportKHR(
                    device.physicalDevice, device.queueFamily, validSurface, &supported)
                if supported == 0 {
                    vkDestroySurfaceKHR(device.instance, validSurface, nil)
                    throw .unsupported(.presentMode(surface.presentMode))
                }
                vkSurface = validSurface
                currentWindowHandle = surface.nativeHandle
            }

            var caps = VkSurfaceCapabilitiesKHR()
            try checkVk(
                vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
                    device.physicalDevice, vkSurface, &caps))
            let size = CajuVulkanSwapchainPlan.extent(
                current: .init(
                    width: caps.currentExtent.width, height: caps.currentExtent.height),
                minimum: .init(
                    width: caps.minImageExtent.width, height: caps.minImageExtent.height),
                maximum: .init(
                    width: caps.maxImageExtent.width, height: caps.maxImageExtent.height),
                fallback: .init(
                    width: UInt32(surface.pixelWidth), height: UInt32(surface.pixelHeight))
            )
            guard !size.isEmpty else {
                outOfDate = true
                throw .surfaceOutOfDate
            }
            extent = VkExtent2D(width: size.width, height: size.height)

            var formatCount: UInt32 = 0
            try checkVk(
                vkGetPhysicalDeviceSurfaceFormatsKHR(
                    device.physicalDevice, vkSurface, &formatCount, nil))
            guard formatCount > 0 else {
                throw .unsupported(.pixelFormat(surface.preferredFormat))
            }
            var surfaceFormats = [VkSurfaceFormatKHR](
                repeating: VkSurfaceFormatKHR(), count: Int(formatCount))
            try checkVk(
                vkGetPhysicalDeviceSurfaceFormatsKHR(
                    device.physicalDevice, vkSurface, &formatCount, &surfaceFormats))

            let wantedVkFormat = CajuVulkanTranslation.vkFormat(for: surface.preferredFormat)
            let planFormats = surfaceFormats.map {
                CajuVulkanSwapchainPlan.SurfaceFormat(
                    format: $0.format.rawValue, colorSpace: $0.colorSpace.rawValue)
            }
            guard
                let chosen = CajuVulkanSwapchainPlan.chooseFormat(
                    planFormats, preferredFormat: wantedVkFormat)
            else {
                throw .unsupported(.pixelFormat(surface.preferredFormat))
            }
            swapchainVkFormat = VkFormat(rawValue: chosen.format)
            format =
                CajuVulkanTranslation.pixelFormat(fromVkFormat: chosen.format)
                ?? surface.preferredFormat

            var createInfo = VkSwapchainCreateInfoKHR()
            createInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
            createInfo.surface = vkSurface
            createInfo.minImageCount = CajuVulkanSwapchainPlan.imageCount(
                min: caps.minImageCount, max: caps.maxImageCount)
            createInfo.imageFormat = swapchainVkFormat
            createInfo.imageColorSpace = VkColorSpaceKHR(rawValue: chosen.colorSpace)
            createInfo.imageExtent = extent
            createInfo.imageArrayLayers = 1
            createInfo.imageUsage = VkImageUsageFlags(
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue)
            createInfo.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
            createInfo.preTransform = caps.currentTransform
            let opaque = VkCompositeAlphaFlagsKHR(VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR.rawValue)
            createInfo.compositeAlpha =
                caps.supportedCompositeAlpha & opaque != 0
                ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
            createInfo.presentMode = VkPresentModeKHR(
                rawValue: CajuVulkanTranslation.vkPresentMode(for: surface.presentMode))
            createInfo.clipped = VkBool32(VK_TRUE)

            try checkVk(vkCreateSwapchainKHR(device.vkDevice, &createInfo, nil, &vkSwapchain))

            var imgCount: UInt32 = 0
            try checkVk(vkGetSwapchainImagesKHR(device.vkDevice, vkSwapchain, &imgCount, nil))
            vkImages = [VkImage?](repeating: nil, count: Int(imgCount))
            try checkVk(
                vkGetSwapchainImagesKHR(device.vkDevice, vkSwapchain, &imgCount, &vkImages))

            do {
                try createRenderPassVariants()
                try createPerImageResources()
            } catch {
                destroySwapchainObjects()
                throw error
            }

            pixelWidth = Int(extent.width)
            pixelHeight = Int(extent.height)
            surfaceReleased = false
            outOfDate = false
            device.activeSwapchain = self
        }

        /// Libera os objetos Vulkan dependentes da superfície e invalida as texturas da swapchain.
        public func releaseSurface() {
            vkDeviceWaitIdle(device.vkDevice)
            destroySwapchainObjects()
            destroySurface()
            surfaceReleased = true
            outOfDate = false
        }

        // MARK: Auxiliares privados

        private func createRenderPassVariants() throws(CajuRHIError) {
            let loadOps: [VkAttachmentLoadOp] = [
                VK_ATTACHMENT_LOAD_OP_LOAD,
                VK_ATTACHMENT_LOAD_OP_CLEAR,
                VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            ]
            let storeOps: [VkAttachmentStoreOp] = [
                VK_ATTACHMENT_STORE_OP_STORE,
                VK_ATTACHMENT_STORE_OP_DONT_CARE,
            ]
            for (loadIdx, loadOp) in loadOps.enumerated() {
                for (storeIdx, storeOp) in storeOps.enumerated() {
                    var color = VkAttachmentDescription()
                    color.format = swapchainVkFormat
                    color.samples = VK_SAMPLE_COUNT_1_BIT
                    color.loadOp = loadOp
                    color.storeOp = storeOp
                    color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
                    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
                    color.initialLayout =
                        loadOp == VK_ATTACHMENT_LOAD_OP_LOAD
                        ? VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : VK_IMAGE_LAYOUT_UNDEFINED
                    color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR

                    var reference = VkAttachmentReference(
                        attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
                    var dependency = VkSubpassDependency()
                    dependency.srcSubpass = UInt32.max
                    dependency.dstSubpass = 0
                    dependency.srcStageMask = VkPipelineStageFlags(
                        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
                    dependency.dstStageMask = VkPipelineStageFlags(
                        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
                    dependency.dstAccessMask = VkAccessFlags(
                        VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)

                    let variantIndex = loadIdx * 2 + storeIdx
                    let result: VkResult = withUnsafePointer(to: &color) { colorPtr in
                        withUnsafePointer(to: &reference) { refPtr in
                            var subpass = VkSubpassDescription()
                            subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
                            subpass.colorAttachmentCount = 1
                            subpass.pColorAttachments = refPtr
                            return withUnsafePointer(to: &subpass) { subpassPtr in
                                withUnsafePointer(to: &dependency) { depPtr in
                                    var info = VkRenderPassCreateInfo()
                                    info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
                                    info.attachmentCount = 1
                                    info.pAttachments = colorPtr
                                    info.subpassCount = 1
                                    info.pSubpasses = subpassPtr
                                    info.dependencyCount = 1
                                    info.pDependencies = depPtr
                                    return vkCreateRenderPass(
                                        device.vkDevice, &info, nil, &renderPasses[variantIndex])
                                }
                            }
                        }
                    }
                    try checkVk(result)
                }
            }
        }

        private func createPerImageResources() throws(CajuRHIError) {
            let count = vkImages.count
            imageViews = [VkImageView?](repeating: nil, count: count)
            framebuffers = [VkFramebuffer?](repeating: nil, count: count)
            renderFinished = [VkSemaphore?](repeating: nil, count: count)
            textureHandles.removeAll(keepingCapacity: true)
            textureHandles.reserveCapacity(count)

            let compatiblePass = renderPasses[2]  // CLEAR + STORE
            for index in 0..<count {
                var viewInfo = VkImageViewCreateInfo()
                viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
                viewInfo.image = vkImages[index]
                viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
                viewInfo.format = swapchainVkFormat
                viewInfo.subresourceRange = VkImageSubresourceRange(
                    aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                    baseMipLevel: 0,
                    levelCount: 1,
                    baseArrayLayer: 0,
                    layerCount: 1
                )
                try checkVk(
                    vkCreateImageView(device.vkDevice, &viewInfo, nil, &imageViews[index]))

                var attachment = imageViews[index]
                let fbResult: VkResult = withUnsafePointer(to: &attachment) { attPtr in
                    var fbInfo = VkFramebufferCreateInfo()
                    fbInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
                    fbInfo.renderPass = compatiblePass
                    fbInfo.attachmentCount = 1
                    fbInfo.pAttachments = attPtr
                    fbInfo.width = extent.width
                    fbInfo.height = extent.height
                    fbInfo.layers = 1
                    return vkCreateFramebuffer(
                        device.vkDevice, &fbInfo, nil, &framebuffers[index])
                }
                try checkVk(fbResult)

                var semInfo = VkSemaphoreCreateInfo()
                semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
                try checkVk(
                    vkCreateSemaphore(device.vkDevice, &semInfo, nil, &renderFinished[index]))

                let texDesc = CajuTextureDescriptor(
                    format: format,
                    width: Int(extent.width),
                    height: Int(extent.height),
                    usage: .renderTarget,
                    label: "swapchain"
                )
                let handle = device.textures.insert(
                    CajuVulkanTextureRecord(descriptor: texDesc, swapchainImageIndex: index))
                textureHandles.append(handle)
            }
        }

        private func destroySwapchainObjects() {
            for handle in textureHandles {
                device.textures.remove(handle)
            }
            textureHandles.removeAll(keepingCapacity: true)

            for sem in renderFinished {
                if let sem { vkDestroySemaphore(device.vkDevice, sem, nil) }
            }
            for fb in framebuffers {
                if let fb { vkDestroyFramebuffer(device.vkDevice, fb, nil) }
            }
            for view in imageViews {
                if let view { vkDestroyImageView(device.vkDevice, view, nil) }
            }
            renderFinished.removeAll(keepingCapacity: true)
            framebuffers.removeAll(keepingCapacity: true)
            imageViews.removeAll(keepingCapacity: true)
            vkImages.removeAll(keepingCapacity: true)

            for i in renderPasses.indices {
                if let pass = renderPasses[i] {
                    vkDestroyRenderPass(device.vkDevice, pass, nil)
                    renderPasses[i] = nil
                }
            }
            if let vkSwapchain {
                vkDestroySwapchainKHR(device.vkDevice, vkSwapchain, nil)
            }
            vkSwapchain = nil
        }

        private func destroySurface() {
            if let vkSurface {
                vkDestroySurfaceKHR(device.instance, vkSurface, nil)
            }
            vkSurface = nil
            currentWindowHandle = 0
        }
    }
#endif
