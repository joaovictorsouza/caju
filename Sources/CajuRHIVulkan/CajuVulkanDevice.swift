#if os(Android)
    import CVulkan
    import CajuRHI

    struct VulkanBuffer {
        var buffer: VkBuffer
        var allocation: VmaAllocation
        /// Endereço mapeado de forma persistente (só `shared`).
        var mapped: UnsafeMutableRawPointer?
        var descriptor: CajuBufferDescriptor
    }

    /// Textura com o *layout* corrente rastreado: o backend emite as barreiras (o contrato não tem barreiras).
    final class VulkanTexture {
        var image: VkImage
        var view: VkImageView
        var allocation: VmaAllocation?
        let descriptor: CajuTextureDescriptor
        let layers: UInt32
        var layout: VkImageLayout = VK_IMAGE_LAYOUT_UNDEFINED
        /// Imagem de *swapchain*: o *swapchain* é o dono (não destruir aqui).
        let ownsImage: Bool

        init(
            image: VkImage, view: VkImageView, allocation: VmaAllocation?, descriptor: CajuTextureDescriptor,
            layers: UInt32, ownsImage: Bool = true
        ) {
            self.image = image
            self.view = view
            self.allocation = allocation
            self.descriptor = descriptor
            self.layers = layers
            self.ownsImage = ownsImage
        }
    }

    /// Objeto nativo cuja destruição espera a GPU terminar de usá-lo (ADR 0024).
    enum VulkanGarbage {
        case buffer(VkBuffer, VmaAllocation)
        case image(VkImage, VkImageView, VmaAllocation?)
        case sampler(VkSampler)
        case shader(VkShaderModule)
    }

    /// Dispositivo Vulkan do RHI (ADR 0001, 0015, 0024).
    ///
    /// Não é `Sendable`: pertence à Game Thread (ADR 0008).
    public final class CajuVulkanDevice: CajuRenderDevice {
        public typealias Queue = CajuVulkanQueue
        public typealias Swapchain = CajuVulkanSwapchain

        public let capabilities: CajuDeviceCapabilities
        let context: CajuVulkanContext

        var buffers = CajuHandlePool<CajuBufferTag, VulkanBuffer>()
        var textures = CajuHandlePool<CajuTextureTag, VulkanTexture>()
        var samplers = CajuHandlePool<CajuSamplerTag, VkSampler>()
        var shaders = CajuHandlePool<CajuShaderTag, VkShaderModule>()
        private var transients: [Int: [(descriptor: CajuTextureDescriptor, handle: CajuTextureHandle)]] = [:]
        private var garbage: [(serial: UInt64, item: VulkanGarbage)] = []

        /// Cria o dispositivo. `enableSurface` liga as extensões de superfície (apresentação em janela);
        /// o executável de conformidade, sem janela, passa `false`.
        public init(enableSurface: Bool = false) throws(CajuRHIError) {
            context = try CajuVulkanContext(enableSurface: enableSurface)
            capabilities = context.capabilities
            garbage.reserveCapacity(64)
        }

        deinit {
            try? context.waitIdle()
            collectGarbage(force: true)
        }

        public var queue: CajuVulkanQueue { CajuVulkanQueue(device: self) }

        // MARK: Memória e destruição adiada

        /// Destrói agora o que a GPU já terminou de usar (ou tudo, com `force`, depois de `waitIdle`).
        func collectGarbage(force: Bool = false) {
            context.poll()
            let done = force ? UInt64.max : context.completedSerial
            var index = 0
            while index < garbage.count {
                if garbage[index].serial <= done {
                    destroyNow(garbage[index].item)
                    garbage.remove(at: index)
                } else {
                    index += 1
                }
            }
        }

        private func destroyNow(_ item: VulkanGarbage) {
            switch item {
            case .buffer(let buffer, let allocation):
                vmaDestroyBuffer(context.allocator, buffer, allocation)
            case .image(let image, let view, let allocation):
                vkDestroyImageView(context.device, view, nil)
                if let allocation { vmaDestroyImage(context.allocator, image, allocation) }
            case .sampler(let sampler): vkDestroySampler(context.device, sampler, nil)
            case .shader(let module): vkDestroyShaderModule(context.device, module, nil)
            }
        }

        /// Agenda a destruição para depois da última submissão enviada (que pode ainda referenciar o objeto).
        private func retire(_ item: VulkanGarbage) {
            if context.submittedSerial <= context.completedSerial {
                destroyNow(item)
            } else {
                garbage.append((context.submittedSerial, item))
            }
        }

        /// Bytes de memória de GPU em uso pelo VMA (blocos alocados; diagnóstico de vazamento).
        public var allocatedBytes: Int {
            var budgets = [VmaBudget](repeating: VmaBudget(), count: Int(VK_MAX_MEMORY_HEAPS))
            vmaGetHeapBudgets(context.allocator, &budgets)
            return budgets.reduce(0) { $0 + Int(truncatingIfNeeded: $1.statistics.blockBytes) }
        }

        /// Quantidade de recursos vivos de qualquer tipo (diagnóstico de vazamento).
        public var liveResourceCount: Int { buffers.count + textures.count + samplers.count + shaders.count }

        /// Objetos nativos esperando a GPU terminar para serem destruídos.
        public var pendingDestructionCount: Int { garbage.count }

        // MARK: Criação

        public func createBuffer(_ d: CajuBufferDescriptor) throws(CajuRHIError) -> CajuBufferHandle {
            guard d.size > 0 else { throw .invalidDescriptor(.zeroSize) }
            guard d.size <= capabilities.maxBufferSize else { throw .invalidDescriptor(.exceedsDeviceLimit) }
            guard !d.usage.isEmpty else { throw .invalidDescriptor(.emptyUsage) }
            guard d.storage != .memoryless else { throw .invalidDescriptor(.incompatibleUsage) }

            var usage: UInt32 = VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue
            if d.usage.contains(.vertex) { usage |= VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue }
            if d.usage.contains(.index) { usage |= VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue }
            if d.usage.contains(.uniform) { usage |= VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue }
            if d.usage.contains(.storage) { usage |= VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue }
            if d.usage.contains(.copySource) { usage |= VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue }
            var bufferInfo = VkBufferCreateInfo()
            bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
            bufferInfo.size = VkDeviceSize(d.size)
            bufferInfo.usage = VkBufferUsageFlags(usage)
            bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE

            let shared = d.storage == .shared
            var allocationInfo = VmaAllocationCreateInfo()
            allocationInfo.usage = shared ? VMA_MEMORY_USAGE_AUTO : VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE
            if shared {
                allocationInfo.flags =
                    VmaAllocationCreateFlags(
                        VMA_ALLOCATION_CREATE_MAPPED_BIT.rawValue
                            | VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT.rawValue)
            }
            var buffer: VkBuffer?
            var allocation: VmaAllocation?
            var info = VmaAllocationInfo()
            try vkCheck(
                vmaCreateBuffer(context.allocator, &bufferInfo, &allocationInfo, &buffer, &allocation, &info))
            guard let buffer, let allocation else { throw .outOfMemory }
            return buffers.insert(
                VulkanBuffer(buffer: buffer, allocation: allocation, mapped: info.pMappedData, descriptor: d))
        }

        public func createTexture(_ d: CajuTextureDescriptor) throws(CajuRHIError) -> CajuTextureHandle {
            textures.insert(try makeTexture(d))
        }

        private func makeTexture(_ d: CajuTextureDescriptor) throws(CajuRHIError) -> VulkanTexture {
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
            let largest = max(d.width, d.height, d.dimension == .type3D ? d.depthOrLayers : 1)
            guard d.mipLevels >= 1, d.mipLevels <= Int.bitWidth - largest.leadingZeroBitCount else {
                throw .invalidDescriptor(.invalidMipCount)
            }
            let memoryless = d.storage == .memoryless
            if memoryless {
                guard capabilities.supportsMemoryless else { throw .unsupported(.memorylessAttachments) }
                guard d.usage == .renderTarget else { throw .invalidDescriptor(.incompatibleUsage) }
            }

            // Uso nativo e verificação do formato (o contrato não promete formato×uso em todo aparelho).
            let format = d.format.vulkan
            let features = context.formatFeatures(format)
            var usage: UInt32 = 0
            var required: UInt32 = 0
            if d.usage.contains(.sampled) {
                usage |= VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
                required |= VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT.rawValue
            }
            if d.usage.contains(.renderTarget) {
                usage |=
                    (d.format.isDepth
                    ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT : VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
                    .rawValue
                required |=
                    (d.format.isDepth
                    ? VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT : VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)
                    .rawValue
            }
            if d.usage.contains(.storage) {
                usage |= VK_IMAGE_USAGE_STORAGE_BIT.rawValue
                required |= VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT.rawValue
            }
            guard features & required == required else { throw .unsupported(.pixelFormat(d.format)) }
            if memoryless {
                usage |= VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT.rawValue
            } else {
                // `writeTexture` (carga) e leitura de conformidade passam por *staging* e cópia.
                usage |= VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
                if d.usage.contains(.copySource) || d.storage == .shared {
                    usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
                }
            }

            let layers: UInt32 =
                switch d.dimension {
                case .type2D, .type3D: 1
                case .type2DArray: UInt32(d.depthOrLayers)
                case .cube: 6
                }
            var imageInfo = VkImageCreateInfo()
            imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
            if d.dimension == .cube {
                imageInfo.flags = VkImageCreateFlags(VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue)
            }
            imageInfo.imageType = d.dimension == .type3D ? VK_IMAGE_TYPE_3D : VK_IMAGE_TYPE_2D
            imageInfo.format = format
            imageInfo.extent = VkExtent3D(
                width: UInt32(d.width), height: UInt32(d.height),
                depth: d.dimension == .type3D ? UInt32(d.depthOrLayers) : 1)
            imageInfo.mipLevels = UInt32(d.mipLevels)
            imageInfo.arrayLayers = layers
            imageInfo.samples = vulkanSampleCount(d.sampleCount)
            imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL
            imageInfo.usage = VkImageUsageFlags(usage)
            imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
            imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED

            var allocationInfo = VmaAllocationCreateInfo()
            allocationInfo.usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE
            if memoryless {
                allocationInfo.requiredFlags = VkMemoryPropertyFlags(
                    VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT.rawValue)
            }
            var image: VkImage?
            var allocation: VmaAllocation?
            try vkCheck(
                vmaCreateImage(context.allocator, &imageInfo, &allocationInfo, &image, &allocation, nil))
            guard let image, let allocation else { throw .outOfMemory }

            var viewInfo = VkImageViewCreateInfo()
            viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
            viewInfo.image = image
            viewInfo.viewType =
                switch d.dimension {
                case .type2D: VK_IMAGE_VIEW_TYPE_2D
                case .type2DArray: VK_IMAGE_VIEW_TYPE_2D_ARRAY
                case .cube: VK_IMAGE_VIEW_TYPE_CUBE
                case .type3D: VK_IMAGE_VIEW_TYPE_3D
                }
            viewInfo.format = format
            viewInfo.subresourceRange = VkImageSubresourceRange(
                aspectMask: d.format.vulkanAspect, baseMipLevel: 0, levelCount: UInt32(d.mipLevels),
                baseArrayLayer: 0, layerCount: layers)
            var view: VkImageView?
            let viewResult = vkCreateImageView(context.device, &viewInfo, nil, &view)
            guard viewResult == VK_SUCCESS, let view else {
                vmaDestroyImage(context.allocator, image, allocation)
                throw mapVkResult(viewResult)
            }
            return VulkanTexture(
                image: image, view: view, allocation: allocation, descriptor: d, layers: layers)
        }

        public func createSampler(_ d: CajuSamplerDescriptor) throws(CajuRHIError) -> CajuSamplerHandle {
            guard d.maxAnisotropy >= 1, d.maxAnisotropy <= capabilities.maxAnisotropy else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }
            var info = VkSamplerCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
            info.magFilter = d.magFilter.vulkan
            info.minFilter = d.minFilter.vulkan
            info.mipmapMode = d.mipFilter.vulkanMip
            info.addressModeU = d.addressU.vulkan
            info.addressModeV = d.addressV.vulkan
            info.addressModeW = d.addressW.vulkan
            info.anisotropyEnable = d.maxAnisotropy > 1 ? VkBool32(VK_TRUE) : VkBool32(VK_FALSE)
            info.maxAnisotropy = Float(d.maxAnisotropy)
            info.maxLod = Float(VK_LOD_CLAMP_NONE)
            info.borderColor = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK
            var sampler: VkSampler?
            try vkCheck(vkCreateSampler(context.device, &info, nil, &sampler))
            guard let sampler else { throw .outOfMemory }
            return samplers.insert(sampler)
        }

        public func createShaderModule(_ d: CajuShaderModuleDescriptor) throws(CajuRHIError)
            -> CajuShaderHandle
        {
            guard !d.code.isEmpty, d.format == .spirv, d.code.count % 4 == 0 else {
                throw .invalidDescriptor(.missingShader)
            }
            var module: VkShaderModule?
            let result: VkResult = d.code.withUnsafeBytes { raw in
                var info = VkShaderModuleCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
                info.codeSize = raw.count
                // `[UInt8]` vem alinhado a pelo menos 16 bytes: a reinterpretação como `UInt32` é segura.
                info.pCode = raw.baseAddress?.assumingMemoryBound(to: UInt32.self)
                return vkCreateShaderModule(context.device, &info, nil, &module)
            }
            try vkCheck(result)
            guard let module else { throw .outOfMemory }
            return shaders.insert(module)
        }

        public func createRenderPipeline(_ d: CajuRenderPipelineDescriptor) throws(CajuRHIError)
            -> CajuRenderPipelineHandle
        {
            throw .backend(code: cajuVulkanNotImplementedCode)  // fatia D da V-1
        }

        public func createComputePipeline(_ d: CajuComputePipelineDescriptor) throws(CajuRHIError)
            -> CajuComputePipelineHandle
        {
            throw .unsupported(.computePipelines)
        }

        public func createSwapchain(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError)
            -> CajuVulkanSwapchain
        {
            throw .backend(code: cajuVulkanNotImplementedCode)  // fatia E da V-1
        }

        // MARK: Destruição (adiada até a GPU terminar)

        public func destroy(_ buffer: CajuBufferHandle) {
            if let record = buffers.remove(buffer) { retire(.buffer(record.buffer, record.allocation)) }
        }

        public func destroy(_ texture: CajuTextureHandle) {
            guard let record = textures.remove(texture), record.ownsImage else { return }
            retire(.image(record.image, record.view, record.allocation))
        }

        public func destroy(_ sampler: CajuSamplerHandle) {
            if let record = samplers.remove(sampler) { retire(.sampler(record)) }
        }

        public func destroy(_ shader: CajuShaderHandle) {
            if let record = shaders.remove(shader) { retire(.shader(record)) }
        }

        public func destroy(_ pipeline: CajuRenderPipelineHandle) {}
        public func destroy(_ pipeline: CajuComputePipelineHandle) {}

        // MARK: Upload e leitura

        public func writeBuffer(_ buffer: CajuBufferHandle, offset: Int, bytes: UnsafeRawBufferPointer)
            throws(CajuRHIError)
        {
            guard let record = buffers.value(for: buffer) else {
                throw CajuHandlePool<CajuBufferTag, Int>.invalid(buffer)
            }
            guard record.descriptor.storage == .shared, let mapped = record.mapped else {
                throw .invalidDescriptor(.incompatibleUsage)
            }
            guard offset >= 0, offset + bytes.count <= record.descriptor.size else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }
            guard let base = bytes.baseAddress else { return }
            (mapped + offset).copyMemory(from: base, byteCount: bytes.count)
            try vkCheck(
                vmaFlushAllocation(
                    context.allocator, record.allocation, VkDeviceSize(offset), VkDeviceSize(bytes.count)))
        }

        public func writeTexture(
            _ texture: CajuTextureHandle, mipLevel: Int, slice: Int, width: Int, height: Int,
            bytesPerRow: Int, bytes: UnsafeRawBufferPointer
        ) throws(CajuRHIError) {
            guard let record = textures.value(for: texture) else {
                throw CajuHandlePool<CajuTextureTag, Int>.invalid(texture)
            }
            let d = record.descriptor
            guard width > 0, height > 0, mipLevel >= 0, mipLevel < d.mipLevels, slice >= 0,
                slice < max(Int(record.layers), 1), bytesPerRow >= d.format.byteSize(width: width, height: 1),
                d.storage != .memoryless
            else { throw .invalidDescriptor(.zeroSize) }
            let rows = (height + d.format.blockHeight - 1) / d.format.blockHeight
            let size = bytesPerRow * rows
            guard bytes.count >= size, let base = bytes.baseAddress else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }
            let staging = try makeStagingBuffer(size: size, readback: false)
            defer { vmaDestroyBuffer(context.allocator, staging.buffer, staging.allocation) }
            staging.mapped.copyMemory(from: base, byteCount: size)
            try vkCheck(vmaFlushAllocation(context.allocator, staging.allocation, 0, VkDeviceSize(size)))

            let commandBuffer = try context.beginCommandBuffer()
            transition(commandBuffer, record, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
            var region = VkBufferImageCopy(
                bufferOffset: 0,
                bufferRowLength: UInt32(bytesPerRow / d.format.bytesPerBlock * d.format.blockWidth),
                bufferImageHeight: 0,
                imageSubresource: VkImageSubresourceLayers(
                    aspectMask: d.format.vulkanAspect, mipLevel: UInt32(mipLevel),
                    baseArrayLayer: UInt32(slice),
                    layerCount: 1),
                imageOffset: VkOffset3D(x: 0, y: 0, z: 0),
                imageExtent: VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1))
            vkCmdCopyBufferToImage(
                commandBuffer, staging.buffer, record.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
            let serial = try context.submit(commandBuffer)
            try context.wait(for: serial)
            collectGarbage()
        }

        /// Lê o mip 0 de uma textura de 1 amostra e sem compressão (conformidade e *goldens*): bytes linha a
        /// linha, sem preenchimento. Espera a GPU terminar o que foi enviado antes.
        public func readTexture(_ texture: CajuTextureHandle) throws(CajuRHIError) -> [UInt8] {
            guard let record = textures.value(for: texture) else {
                throw CajuHandlePool<CajuTextureTag, Int>.invalid(texture)
            }
            let d = record.descriptor
            guard d.storage == .shared, !d.format.isCompressed, d.sampleCount == 1, d.dimension == .type2D
            else {
                throw .invalidDescriptor(.incompatibleUsage)
            }
            let bytesPerRow = d.format.byteSize(width: d.width, height: 1)
            let size = bytesPerRow * d.height
            let staging = try makeStagingBuffer(size: size, readback: true)
            defer { vmaDestroyBuffer(context.allocator, staging.buffer, staging.allocation) }

            let commandBuffer = try context.beginCommandBuffer()
            transition(commandBuffer, record, to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
            var region = VkBufferImageCopy(
                bufferOffset: 0, bufferRowLength: 0, bufferImageHeight: 0,
                imageSubresource: VkImageSubresourceLayers(
                    aspectMask: d.format.vulkanAspect, mipLevel: 0, baseArrayLayer: 0, layerCount: 1),
                imageOffset: VkOffset3D(x: 0, y: 0, z: 0),
                imageExtent: VkExtent3D(width: UInt32(d.width), height: UInt32(d.height), depth: 1))
            vkCmdCopyImageToBuffer(
                commandBuffer, record.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.buffer, 1, &region)
            // Torna as escritas da transferência visíveis ao *host*.
            var barrier = VkMemoryBarrier()
            barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
            barrier.srcAccessMask = VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue)
            barrier.dstAccessMask = VkAccessFlags(VK_ACCESS_HOST_READ_BIT.rawValue)
            vkCmdPipelineBarrier(
                commandBuffer, VkPipelineStageFlags(VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue),
                VkPipelineStageFlags(VK_PIPELINE_STAGE_HOST_BIT.rawValue), 0, 1, &barrier, 0, nil, 0, nil)
            let serial = try context.submit(commandBuffer)
            try context.wait(for: serial)
            collectGarbage()
            try vkCheck(vmaInvalidateAllocation(context.allocator, staging.allocation, 0, VkDeviceSize(size)))
            return [UInt8](UnsafeRawBufferPointer(start: staging.mapped, count: size))
        }

        private func makeStagingBuffer(size: Int, readback: Bool) throws(CajuRHIError) -> (
            buffer: VkBuffer, allocation: VmaAllocation, mapped: UnsafeMutableRawPointer
        ) {
            var bufferInfo = VkBufferCreateInfo()
            bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
            bufferInfo.size = VkDeviceSize(size)
            bufferInfo.usage = VkBufferUsageFlags(
                (readback ? VK_BUFFER_USAGE_TRANSFER_DST_BIT : VK_BUFFER_USAGE_TRANSFER_SRC_BIT).rawValue)
            bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
            var allocationInfo = VmaAllocationCreateInfo()
            allocationInfo.usage = VMA_MEMORY_USAGE_AUTO
            allocationInfo.flags = VmaAllocationCreateFlags(
                VMA_ALLOCATION_CREATE_MAPPED_BIT.rawValue
                    | (readback
                    ? VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT
                    : VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT).rawValue)
            var buffer: VkBuffer?
            var allocation: VmaAllocation?
            var info = VmaAllocationInfo()
            try vkCheck(
                vmaCreateBuffer(context.allocator, &bufferInfo, &allocationInfo, &buffer, &allocation, &info))
            guard let buffer, let allocation, let mapped = info.pMappedData else { throw .outOfMemory }
            return (buffer, allocation, mapped)
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
            for entries in transients.values { for entry in entries { destroy(entry.handle) } }
            transients.removeAll()
        }

        /// Texturas transitórias vivas (com ou sem memória).
        public var transientTextureCount: Int { transients.values.reduce(0) { $0 + $1.count } }

        // MARK: Barreiras de layout

        /// Leva a imagem inteira ao `layout` pedido, emitindo a barreira conservadora e atualizando o rastreio.
        func transition(_ commandBuffer: VkCommandBuffer, _ texture: VulkanTexture, to layout: VkImageLayout)
        {
            guard texture.layout != layout else { return }
            let source = Self.accessAndStage(texture.layout)
            let destination = Self.accessAndStage(layout)
            var barrier = VkImageMemoryBarrier()
            barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
            barrier.srcAccessMask = source.access
            barrier.dstAccessMask = destination.access
            barrier.oldLayout = texture.layout
            barrier.newLayout = layout
            barrier.srcQueueFamilyIndex = UInt32.max  // VK_QUEUE_FAMILY_IGNORED
            barrier.dstQueueFamilyIndex = UInt32.max
            barrier.image = texture.image
            barrier.subresourceRange = VkImageSubresourceRange(
                aspectMask: texture.descriptor.format.vulkanAspect, baseMipLevel: 0,
                levelCount: UInt32(texture.descriptor.mipLevels), baseArrayLayer: 0,
                layerCount: texture.layers)
            vkCmdPipelineBarrier(
                commandBuffer, source.stage, destination.stage, 0, 0, nil, 0, nil, 1, &barrier)
            texture.layout = layout
        }

        private static func accessAndStage(_ layout: VkImageLayout) -> (
            access: VkAccessFlags, stage: VkPipelineStageFlags
        ) {
            func flags(_ a: [VkAccessFlagBits]) -> VkAccessFlags {
                a.reduce(0) { $0 | VkAccessFlags($1.rawValue) }
            }
            func stages(_ s: [VkPipelineStageFlagBits]) -> VkPipelineStageFlags {
                s.reduce(0) { $0 | VkPipelineStageFlags($1.rawValue) }
            }
            switch layout {
            case VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
                return (flags([VK_ACCESS_TRANSFER_WRITE_BIT]), stages([VK_PIPELINE_STAGE_TRANSFER_BIT]))
            case VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL:
                return (flags([VK_ACCESS_TRANSFER_READ_BIT]), stages([VK_PIPELINE_STAGE_TRANSFER_BIT]))
            case VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL:
                return (
                    flags([VK_ACCESS_COLOR_ATTACHMENT_READ_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT]),
                    stages([VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT])
                )
            case VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL:
                return (
                    flags([
                        VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT,
                        VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                    ]),
                    stages([
                        VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT, VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                    ])
                )
            case VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL:
                return (
                    flags([VK_ACCESS_SHADER_READ_BIT]),
                    stages([VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT])
                )
            case VK_IMAGE_LAYOUT_PRESENT_SRC_KHR:
                return (0, stages([VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT]))
            case VK_IMAGE_LAYOUT_UNDEFINED:
                return (0, stages([VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT]))
            default:  // GENERAL e o resto: conservador
                return (
                    flags([VK_ACCESS_MEMORY_READ_BIT, VK_ACCESS_MEMORY_WRITE_BIT]),
                    stages([VK_PIPELINE_STAGE_ALL_COMMANDS_BIT])
                )
            }
        }
    }
#endif
