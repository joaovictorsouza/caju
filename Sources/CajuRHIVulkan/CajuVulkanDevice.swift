#if os(Android)
    import Android
    import CajuRHI
    import CVulkan

    /// Ponteiro C estático de um literal (sem alocar).
    @inline(__always)
    private func cString(_ string: StaticString) -> UnsafePointer<CChar> {
        UnsafeRawPointer(string.utf8Start).assumingMemoryBound(to: CChar.self)
    }

    /// Converte um `VkResult` diferente de `VK_SUCCESS` em `CajuRHIError`.
    @inline(__always)
    func checkVk(_ result: VkResult) throws(CajuRHIError) {
        guard result == VK_SUCCESS else {
            throw CajuVulkanTranslation.rhiError(fromVkResult: result.rawValue)
        }
    }

    // MARK: - Registros internos de recursos

    struct CajuVulkanBufferRecord {
        let buffer: VkBuffer
        let memory: VkDeviceMemory
        let mapped: UnsafeMutableRawPointer?
        let descriptor: CajuBufferDescriptor
    }

    struct CajuVulkanTextureRecord {
        let descriptor: CajuTextureDescriptor
        let swapchainImageIndex: Int?
    }

    struct CajuVulkanShaderRecord {
        let module: VkShaderModule
        let descriptor: CajuShaderModuleDescriptor
    }

    struct CajuVulkanRenderPipelineRecord {
        let pipeline: VkPipeline
        let layout: VkPipelineLayout
        let compatibleRenderPass: VkRenderPass
        let pushConstantStages: VkShaderStageFlags
        let descriptor: CajuRenderPipelineDescriptor
    }

    /// Dispositivo Vulkan 1.1 que implementa o contrato `CajuRenderDevice` (ADR 0015).
    ///
    /// Pertence à Game Thread (não é `Sendable`, conforme ADR 0008). Mantém dois quadros em voo
    /// com command buffers, semáforos e fences pré-alocados para submissão sem alocação de heap.
    public final class CajuVulkanDevice: CajuRenderDevice {
        public typealias Queue = CajuVulkanQueue
        public typealias Swapchain = CajuVulkanSwapchain

        static let framesInFlight = 2
        static let maxPushConstantBytes = 128

        public let capabilities: CajuDeviceCapabilities
        public var queue: CajuVulkanQueue { CajuVulkanQueue(device: self) }

        let instance: VkInstance
        let physicalDevice: VkPhysicalDevice
        let vkDevice: VkDevice
        let vkQueue: VkQueue
        let queueFamily: UInt32
        let commandPool: VkCommandPool
        let memoryTypeFlags: [UInt32]

        var commandBuffers = [VkCommandBuffer?](repeating: nil, count: framesInFlight)
        var imageAvailable = [VkSemaphore?](repeating: nil, count: framesInFlight)
        var inFlight = [VkFence?](repeating: nil, count: framesInFlight)
        var frameIndex = 0
        var frameFenceWaited = false
        var frameImageAcquired = false
        weak var activeSwapchain: CajuVulkanSwapchain?

        var buffers = CajuHandlePool<CajuBufferTag, CajuVulkanBufferRecord>()
        var textures = CajuHandlePool<CajuTextureTag, CajuVulkanTextureRecord>()
        var shaders = CajuHandlePool<CajuShaderTag, CajuVulkanShaderRecord>()
        var renderPipelines = CajuHandlePool<
            CajuRenderPipelineTag, CajuVulkanRenderPipelineRecord
        >()

        /// Cria a instância Vulkan 1.1, seleciona o dispositivo físico e inicializa fila e pool.
        public init() throws(CajuRHIError) {
            var application = VkApplicationInfo()
            application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
            application.pApplicationName = cString("Caju")
            application.pEngineName = cString("Caju")
            application.apiVersion = (1 << 22) | (1 << 12)  // Vulkan 1.1

            let instanceExtensions: [UnsafePointer<CChar>?] = [
                cString("VK_KHR_surface"), cString("VK_KHR_android_surface"),
            ]
            var createdInstance: VkInstance?
            let instanceResult: VkResult = instanceExtensions.withUnsafeBufferPointer { extensions in
                withUnsafePointer(to: &application) { app in
                    var info = VkInstanceCreateInfo()
                    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                    info.pApplicationInfo = app
                    info.enabledExtensionCount = UInt32(extensions.count)
                    info.ppEnabledExtensionNames = extensions.baseAddress
                    return vkCreateInstance(&info, nil, &createdInstance)
                }
            }
            try checkVk(instanceResult)
            guard let validInstance = createdInstance else {
                throw .backend(code: VK_ERROR_INITIALIZATION_FAILED.rawValue)
            }
            instance = validInstance

            var deviceCount: UInt32 = 0
            let enumCountResult = vkEnumeratePhysicalDevices(validInstance, &deviceCount, nil)
            if enumCountResult != VK_SUCCESS || deviceCount == 0 {
                vkDestroyInstance(validInstance, nil)
                throw enumCountResult == VK_SUCCESS
                    ? .deviceLost
                    : CajuVulkanTranslation.rhiError(fromVkResult: enumCountResult.rawValue)
            }
            var candidates = [VkPhysicalDevice?](repeating: nil, count: Int(deviceCount))
            let enumResult = vkEnumeratePhysicalDevices(validInstance, &deviceCount, &candidates)
            if enumResult != VK_SUCCESS {
                vkDestroyInstance(validInstance, nil)
                throw CajuVulkanTranslation.rhiError(fromVkResult: enumResult.rawValue)
            }

            var chosenDevice: VkPhysicalDevice?
            var chosenFamily: UInt32 = 0
            search: for candidate in candidates {
                guard let candidate else { continue }
                var familyCount: UInt32 = 0
                vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, nil)
                var families = [VkQueueFamilyProperties](
                    repeating: VkQueueFamilyProperties(), count: Int(familyCount))
                vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, &families)
                for (index, properties) in families.enumerated()
                where properties.queueFlags & VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue) != 0 {
                    chosenDevice = candidate
                    chosenFamily = UInt32(index)
                    break search
                }
            }
            guard let validPhysical = chosenDevice else {
                vkDestroyInstance(validInstance, nil)
                throw .deviceLost
            }
            physicalDevice = validPhysical
            queueFamily = chosenFamily

            var properties = VkPhysicalDeviceProperties()
            vkGetPhysicalDeviceProperties(validPhysical, &properties)
            var features = VkPhysicalDeviceFeatures()
            vkGetPhysicalDeviceFeatures(validPhysical, &features)
            var memProps = VkPhysicalDeviceMemoryProperties()
            vkGetPhysicalDeviceMemoryProperties(validPhysical, &memProps)

            let memCount = Int(min(memProps.memoryTypeCount, UInt32(VK_MAX_MEMORY_TYPES)))
            memoryTypeFlags = withUnsafeBytes(of: memProps.memoryTypes) { rawBuffer in
                let typed = rawBuffer.bindMemory(to: VkMemoryType.self)
                var flags = [UInt32]()
                flags.reserveCapacity(memCount)
                for i in 0..<memCount {
                    flags.append(typed[i].propertyFlags)
                }
                return flags
            }

            let name = withUnsafeBytes(of: properties.deviceName) { rawBuffer -> String in
                let prefix = rawBuffer.prefix { $0 != 0 }
                return String(decoding: prefix, as: UTF8.self)
            }
            let sampleMask =
                properties.limits.framebufferColorSampleCounts
                & properties.limits.framebufferDepthSampleCounts
            let supportedSamples = CajuVulkanTranslation.sampleCounts(fromVkMask: sampleMask)

            capabilities = CajuDeviceCapabilities(
                backendName: "Vulkan",
                deviceName: name,
                maxTextureDimension2D: Int(properties.limits.maxImageDimension2D),
                maxColorAttachments: min(Int(properties.limits.maxColorAttachments), 8),
                maxVertexBuffers: min(Int(properties.limits.maxVertexInputBindings), 8),
                maxBufferSize: 256 << 20,
                maxAnisotropy: max(Int(properties.limits.maxSamplerAnisotropy), 1),
                uniformBufferAlignment: max(
                    Int(properties.limits.minUniformBufferOffsetAlignment), 1),
                sampleCounts: supportedSamples.isEmpty ? [.x1] : supportedSamples,
                supportsMemoryless: false,
                supportsCompute: false,
                supportsASTC: features.textureCompressionASTC_LDR != 0,
                presentModes: [.fifo]
            )

            var priority: Float = 1.0
            var queueInfo = VkDeviceQueueCreateInfo()
            queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            queueInfo.queueFamilyIndex = chosenFamily
            queueInfo.queueCount = 1
            queueInfo.pQueuePriorities = withUnsafePointer(to: &priority) { $0 }

            let deviceExtensions: [UnsafePointer<CChar>?] = [cString("VK_KHR_swapchain")]
            var createdDevice: VkDevice?
            let deviceResult: VkResult = deviceExtensions.withUnsafeBufferPointer { extensions in
                var info = VkDeviceCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                info.queueCreateInfoCount = 1
                info.pQueueCreateInfos = withUnsafePointer(to: &queueInfo) { $0 }
                info.enabledExtensionCount = UInt32(extensions.count)
                info.ppEnabledExtensionNames = extensions.baseAddress
                return vkCreateDevice(validPhysical, &info, nil, &createdDevice)
            }
            if deviceResult != VK_SUCCESS || createdDevice == nil {
                vkDestroyInstance(validInstance, nil)
                throw CajuVulkanTranslation.rhiError(fromVkResult: deviceResult.rawValue)
            }
            guard let validDevice = createdDevice else {
                vkDestroyInstance(validInstance, nil)
                throw .deviceLost
            }
            vkDevice = validDevice

            var fetchedQueue: VkQueue?
            vkGetDeviceQueue(validDevice, chosenFamily, 0, &fetchedQueue)
            guard let validQueue = fetchedQueue else {
                vkDestroyDevice(validDevice, nil)
                vkDestroyInstance(validInstance, nil)
                throw .deviceLost
            }
            vkQueue = validQueue

            var poolInfo = VkCommandPoolCreateInfo()
            poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
            poolInfo.flags = VkCommandPoolCreateFlags(
                VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
            poolInfo.queueFamilyIndex = chosenFamily
            var createdPool: VkCommandPool?
            let poolResult = vkCreateCommandPool(validDevice, &poolInfo, nil, &createdPool)
            guard poolResult == VK_SUCCESS, let validPool = createdPool else {
                vkDestroyDevice(validDevice, nil)
                vkDestroyInstance(validInstance, nil)
                throw CajuVulkanTranslation.rhiError(fromVkResult: poolResult.rawValue)
            }
            commandPool = validPool

            var allocate = VkCommandBufferAllocateInfo()
            allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
            allocate.commandPool = validPool
            allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
            allocate.commandBufferCount = UInt32(Self.framesInFlight)
            let allocResult = vkAllocateCommandBuffers(validDevice, &allocate, &commandBuffers)
            if allocResult != VK_SUCCESS {
                vkDestroyCommandPool(validDevice, validPool, nil)
                vkDestroyDevice(validDevice, nil)
                vkDestroyInstance(validInstance, nil)
                throw CajuVulkanTranslation.rhiError(fromVkResult: allocResult.rawValue)
            }

            for frame in 0..<Self.framesInFlight {
                var semaphoreInfo = VkSemaphoreCreateInfo()
                semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
                let semResult = vkCreateSemaphore(
                    validDevice, &semaphoreInfo, nil, &imageAvailable[frame])
                var fenceInfo = VkFenceCreateInfo()
                fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
                fenceInfo.flags = VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT.rawValue)
                let fenceResult = vkCreateFence(validDevice, &fenceInfo, nil, &inFlight[frame])
                if semResult != VK_SUCCESS || fenceResult != VK_SUCCESS {
                    for i in 0...frame {
                        if let sem = imageAvailable[i] { vkDestroySemaphore(validDevice, sem, nil) }
                        if let f = inFlight[i] { vkDestroyFence(validDevice, f, nil) }
                    }
                    vkDestroyCommandPool(validDevice, validPool, nil)
                    vkDestroyDevice(validDevice, nil)
                    vkDestroyInstance(validInstance, nil)
                    let failed = semResult != VK_SUCCESS ? semResult : fenceResult
                    throw CajuVulkanTranslation.rhiError(fromVkResult: failed.rawValue)
                }
            }
        }

        deinit {
            vkDeviceWaitIdle(vkDevice)
            for frame in 0..<Self.framesInFlight {
                if let sem = imageAvailable[frame] { vkDestroySemaphore(vkDevice, sem, nil) }
                if let fence = inFlight[frame] { vkDestroyFence(vkDevice, fence, nil) }
            }
            vkDestroyCommandPool(vkDevice, commandPool, nil)
            vkDestroyDevice(vkDevice, nil)
            vkDestroyInstance(instance, nil)
        }

        // MARK: Sincronização de quadro em voo

        func ensureFrameReady() throws(CajuRHIError) {
            if !frameFenceWaited {
                var fence = inFlight[frameIndex]
                try checkVk(vkWaitForFences(vkDevice, 1, &fence, VkBool32(VK_TRUE), UInt64.max))
                frameFenceWaited = true
            }
        }

        func advanceFrame() {
            frameIndex = (frameIndex + 1) % Self.framesInFlight
            frameFenceWaited = false
            frameImageAcquired = false
        }

        // MARK: Buffers (vkAllocateMemory direto por buffer; VMA entra em fatia futura)

        /// Cria um buffer Vulkan com alocação `vkAllocateMemory` host-visible/coherent dedicada.
        /// O sub-alocador VMA fica adiado para uma fatia futura.
        public func createBuffer(_ descriptor: CajuBufferDescriptor) throws(CajuRHIError)
            -> CajuBufferHandle
        {
            try CajuVulkanTranslation.validateBufferDescriptor(
                descriptor, capabilities: capabilities)

            var bufferInfo = VkBufferCreateInfo()
            bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
            bufferInfo.size = VkDeviceSize(descriptor.size)
            bufferInfo.usage = CajuVulkanTranslation.vkBufferUsage(for: descriptor.usage)
            bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE

            var createdBuffer: VkBuffer?
            try checkVk(vkCreateBuffer(vkDevice, &bufferInfo, nil, &createdBuffer))
            guard let validBuffer = createdBuffer else {
                throw .outOfMemory
            }

            var requirements = VkMemoryRequirements()
            vkGetBufferMemoryRequirements(vkDevice, validBuffer, &requirements)

            // Alocação host-visible + host-coherent por buffer (VMA fica para fatia futura).
            let requiredFlags = UInt32(
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue
                    | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)
            guard
                let memoryTypeIndex = CajuVulkanTranslation.findMemoryType(
                    typeBits: requirements.memoryTypeBits,
                    memoryPropertyFlags: memoryTypeFlags,
                    requiredFlags: requiredFlags)
            else {
                vkDestroyBuffer(vkDevice, validBuffer, nil)
                throw .outOfMemory
            }

            var allocInfo = VkMemoryAllocateInfo()
            allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
            allocInfo.allocationSize = requirements.size
            allocInfo.memoryTypeIndex = memoryTypeIndex

            var createdMemory: VkDeviceMemory?
            let allocResult = vkAllocateMemory(vkDevice, &allocInfo, nil, &createdMemory)
            guard allocResult == VK_SUCCESS, let validMemory = createdMemory else {
                vkDestroyBuffer(vkDevice, validBuffer, nil)
                throw CajuVulkanTranslation.rhiError(fromVkResult: allocResult.rawValue)
            }

            let bindResult = vkBindBufferMemory(vkDevice, validBuffer, validMemory, 0)
            if bindResult != VK_SUCCESS {
                vkFreeMemory(vkDevice, validMemory, nil)
                vkDestroyBuffer(vkDevice, validBuffer, nil)
                throw CajuVulkanTranslation.rhiError(fromVkResult: bindResult.rawValue)
            }

            var mappedPtr: UnsafeMutableRawPointer?
            if descriptor.storage == .shared {
                let mapResult = vkMapMemory(
                    vkDevice, validMemory, 0, VkDeviceSize(descriptor.size), 0, &mappedPtr)
                if mapResult != VK_SUCCESS {
                    vkFreeMemory(vkDevice, validMemory, nil)
                    vkDestroyBuffer(vkDevice, validBuffer, nil)
                    throw CajuVulkanTranslation.rhiError(fromVkResult: mapResult.rawValue)
                }
            }

            let record = CajuVulkanBufferRecord(
                buffer: validBuffer,
                memory: validMemory,
                mapped: mappedPtr,
                descriptor: descriptor
            )
            return buffers.insert(record)
        }

        /// Copia dados da CPU diretamente para o ponteiro mapeado de um buffer `.shared`.
        public func writeBuffer(
            _ buffer: CajuBufferHandle, offset: Int, bytes: UnsafeRawBufferPointer
        ) throws(CajuRHIError) {
            guard let record = buffers.value(for: buffer) else {
                throw CajuHandlePool<CajuBufferTag, CajuVulkanBufferRecord>.invalid(buffer)
            }
            guard record.descriptor.storage == .shared, let mapped = record.mapped else {
                throw .invalidDescriptor(.incompatibleUsage)
            }
            guard offset >= 0, offset + bytes.count <= record.descriptor.size else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }
            if bytes.count > 0, let source = bytes.baseAddress {
                mapped.advanced(by: offset).copyMemory(from: source, byteCount: bytes.count)
            }
        }

        // MARK: Shaders e pipelines gráficos

        /// Cria um `VkShaderModule` a partir de bytecode SPIR-V.
        public func createShaderModule(_ descriptor: CajuShaderModuleDescriptor)
            throws(CajuRHIError) -> CajuShaderHandle
        {
            let words = try CajuVulkanTranslation.spirvWords(from: descriptor)
            var createdModule: VkShaderModule?
            let result: VkResult = words.withUnsafeBufferPointer { buffer in
                var info = VkShaderModuleCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
                info.codeSize = buffer.count * MemoryLayout<UInt32>.size
                info.pCode = buffer.baseAddress
                return vkCreateShaderModule(vkDevice, &info, nil, &createdModule)
            }
            try checkVk(result)
            guard let validModule = createdModule else {
                throw .backend(code: VK_ERROR_INITIALIZATION_FAILED.rawValue)
            }
            return shaders.insert(
                CajuVulkanShaderRecord(module: validModule, descriptor: descriptor))
        }

        /// Cria um `VkPipeline` gráfico com viewport/scissor dinâmicos, push constants (128 B)
        /// e um `VkRenderPass` compatível com os attachments declarados no descritor.
        public func createRenderPipeline(_ descriptor: CajuRenderPipelineDescriptor)
            throws(CajuRHIError) -> CajuRenderPipelineHandle
        {
            guard let vertexShader = shaders.value(for: descriptor.vertex.module) else {
                throw CajuHandlePool<CajuShaderTag, CajuVulkanShaderRecord>.invalid(
                    descriptor.vertex.module)
            }
            var fragmentShader: CajuVulkanShaderRecord?
            if let fragment = descriptor.fragment {
                guard let resolved = shaders.value(for: fragment.module) else {
                    throw CajuHandlePool<CajuShaderTag, CajuVulkanShaderRecord>.invalid(
                        fragment.module)
                }
                fragmentShader = resolved
            }
            guard descriptor.colorTargets.count <= capabilities.maxColorAttachments else {
                throw .invalidDescriptor(.tooManyAttachments)
            }
            guard descriptor.vertexLayouts.count <= capabilities.maxVertexBuffers else {
                throw .invalidDescriptor(.tooManyAttachments)
            }
            guard !descriptor.colorTargets.isEmpty || descriptor.depth != nil else {
                throw .invalidDescriptor(.emptyUsage)
            }
            guard
                let vkSamples = CajuVulkanTranslation.vkSampleCount(for: descriptor.sampleCount)
            else {
                throw .invalidDescriptor(.invalidSampleCount)
            }
            guard
                descriptor.sampleCount == 1
                    || capabilities.sampleCounts.supports(descriptor.sampleCount)
            else {
                throw .unsupported(.sampleCount(descriptor.sampleCount))
            }
            for target in descriptor.colorTargets {
                if target.format.isDepth { throw .invalidDescriptor(.formatMismatch) }
                if !capabilities.supports(target.format) {
                    throw .unsupported(.pixelFormat(target.format))
                }
            }
            if let depth = descriptor.depth, !depth.format.isDepth {
                throw .invalidDescriptor(.formatMismatch)
            }

            let compatiblePass = try createCompatibleRenderPass(
                colorTargets: descriptor.colorTargets,
                depth: descriptor.depth,
                sampleCountBits: vkSamples
            )

            var pushStages = VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue)
            if fragmentShader != nil {
                pushStages |= VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue)
            }
            var pushRange = VkPushConstantRange(
                stageFlags: pushStages,
                offset: 0,
                size: UInt32(Self.maxPushConstantBytes)
            )
            var layoutInfo = VkPipelineLayoutCreateInfo()
            layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
            layoutInfo.pushConstantRangeCount = 1
            layoutInfo.pPushConstantRanges = withUnsafePointer(to: &pushRange) { $0 }
            var createdLayout: VkPipelineLayout?
            let layoutResult = vkCreatePipelineLayout(vkDevice, &layoutInfo, nil, &createdLayout)
            guard layoutResult == VK_SUCCESS, let validLayout = createdLayout else {
                vkDestroyRenderPass(vkDevice, compatiblePass, nil)
                throw CajuVulkanTranslation.rhiError(fromVkResult: layoutResult.rawValue)
            }

            var bindings = [VkVertexInputBindingDescription]()
            bindings.reserveCapacity(descriptor.vertexLayouts.count)
            for layout in descriptor.vertexLayouts {
                bindings.append(
                    VkVertexInputBindingDescription(
                        binding: UInt32(layout.bufferIndex),
                        stride: UInt32(layout.stride),
                        inputRate: VkVertexInputRate(
                            rawValue: CajuVulkanTranslation.vkVertexInputRate(for: layout.step))
                    ))
            }

            var attributes = [VkVertexInputAttributeDescription]()
            attributes.reserveCapacity(descriptor.vertexAttributes.count)
            for attr in descriptor.vertexAttributes {
                attributes.append(
                    VkVertexInputAttributeDescription(
                        location: UInt32(attr.location),
                        binding: UInt32(attr.bufferIndex),
                        format: VkFormat(
                            rawValue: CajuVulkanTranslation.vkVertexFormat(for: attr.format)),
                        offset: UInt32(attr.offset)
                    ))
            }

            var blendAttachments = [VkPipelineColorBlendAttachmentState]()
            blendAttachments.reserveCapacity(descriptor.colorTargets.count)
            let allChannels = VkColorComponentFlags(
                VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue
                    | VK_COLOR_COMPONENT_B_BIT.rawValue | VK_COLOR_COMPONENT_A_BIT.rawValue)
            for target in descriptor.colorTargets {
                var state = VkPipelineColorBlendAttachmentState()
                state.colorWriteMask = target.writesAllChannels ? allChannels : 0
                if let blend = target.blend {
                    state.blendEnable = VkBool32(VK_TRUE)
                    state.srcColorBlendFactor = VkBlendFactor(
                        rawValue: CajuVulkanTranslation.vkBlendFactor(for: blend.sourceColor))
                    state.dstColorBlendFactor = VkBlendFactor(
                        rawValue: CajuVulkanTranslation.vkBlendFactor(for: blend.destinationColor))
                    state.colorBlendOp = VkBlendOp(
                        rawValue: CajuVulkanTranslation.vkBlendOp(for: blend.colorOperation))
                    state.srcAlphaBlendFactor = VkBlendFactor(
                        rawValue: CajuVulkanTranslation.vkBlendFactor(for: blend.sourceAlpha))
                    state.dstAlphaBlendFactor = VkBlendFactor(
                        rawValue: CajuVulkanTranslation.vkBlendFactor(for: blend.destinationAlpha))
                    state.alphaBlendOp = VkBlendOp(
                        rawValue: CajuVulkanTranslation.vkBlendOp(for: blend.alphaOperation))
                }
                blendAttachments.append(state)
            }

            let fragmentEntryName = descriptor.fragment?.entryPoint ?? "main"
            var createdPipeline: VkPipeline?
            let pipelineResult: VkResult = descriptor.vertex.entryPoint.withCString { vertexName in
                fragmentEntryName.withCString { fragmentName in
                    var stages = [VkPipelineShaderStageCreateInfo]()
                    stages.reserveCapacity(fragmentShader == nil ? 1 : 2)
                    var vertexStage = VkPipelineShaderStageCreateInfo()
                    vertexStage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                    vertexStage.stage = VK_SHADER_STAGE_VERTEX_BIT
                    vertexStage.module = vertexShader.module
                    vertexStage.pName = vertexName
                    stages.append(vertexStage)

                    if let fragmentShader {
                        var fragmentStage = VkPipelineShaderStageCreateInfo()
                        fragmentStage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                        fragmentStage.stage = VK_SHADER_STAGE_FRAGMENT_BIT
                        fragmentStage.module = fragmentShader.module
                        fragmentStage.pName = fragmentName
                        stages.append(fragmentStage)
                    }

                    return bindings.withUnsafeBufferPointer { bindingsBuf in
                        attributes.withUnsafeBufferPointer { attributesBuf in
                            blendAttachments.withUnsafeBufferPointer { blendsBuf in
                                stages.withUnsafeBufferPointer { stagesBuf in
                                    var vertexInput = VkPipelineVertexInputStateCreateInfo()
                                    vertexInput.sType =
                                        VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
                                    vertexInput.vertexBindingDescriptionCount = UInt32(
                                        bindingsBuf.count)
                                    vertexInput.pVertexBindingDescriptions = bindingsBuf.baseAddress
                                    vertexInput.vertexAttributeDescriptionCount = UInt32(
                                        attributesBuf.count)
                                    vertexInput.pVertexAttributeDescriptions =
                                        attributesBuf.baseAddress

                                    var assembly = VkPipelineInputAssemblyStateCreateInfo()
                                    assembly.sType =
                                        VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
                                    assembly.topology = VkPrimitiveTopology(
                                        rawValue: CajuVulkanTranslation.vkPrimitiveTopology(
                                            for: descriptor.topology))

                                    var viewportState = VkPipelineViewportStateCreateInfo()
                                    viewportState.sType =
                                        VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
                                    viewportState.viewportCount = 1
                                    viewportState.scissorCount = 1

                                    var raster = VkPipelineRasterizationStateCreateInfo()
                                    raster.sType =
                                        VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
                                    raster.polygonMode = VK_POLYGON_MODE_FILL
                                    raster.cullMode = CajuVulkanTranslation.vkCullMode(
                                        for: descriptor.cullMode)
                                    raster.frontFace = VkFrontFace(
                                        rawValue: CajuVulkanTranslation.vkFrontFace(
                                            for: descriptor.frontFace))
                                    raster.lineWidth = 1.0

                                    var multisample = VkPipelineMultisampleStateCreateInfo()
                                    multisample.sType =
                                        VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
                                    multisample.rasterizationSamples = VkSampleCountFlagBits(
                                        rawValue: vkSamples)

                                    var depthStencil = VkPipelineDepthStencilStateCreateInfo()
                                    depthStencil.sType =
                                        VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
                                    if let depth = descriptor.depth {
                                        depthStencil.depthTestEnable = VkBool32(VK_TRUE)
                                        depthStencil.depthWriteEnable =
                                            depth.writesDepth
                                            ? VkBool32(VK_TRUE) : VkBool32(VK_FALSE)
                                        depthStencil.depthCompareOp = VkCompareOp(
                                            rawValue: CajuVulkanTranslation.vkCompareOp(
                                                for: depth.compare))
                                    }

                                    var blend = VkPipelineColorBlendStateCreateInfo()
                                    blend.sType =
                                        VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
                                    blend.attachmentCount = UInt32(blendsBuf.count)
                                    blend.pAttachments = blendsBuf.baseAddress

                                    let dynamicStates = [
                                        VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR,
                                    ]
                                    return dynamicStates.withUnsafeBufferPointer { dynBuf in
                                        var dynamic = VkPipelineDynamicStateCreateInfo()
                                        dynamic.sType =
                                            VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
                                        dynamic.dynamicStateCount = UInt32(dynBuf.count)
                                        dynamic.pDynamicStates = dynBuf.baseAddress

                                        var info = VkGraphicsPipelineCreateInfo()
                                        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                                        info.stageCount = UInt32(stagesBuf.count)
                                        info.pStages = stagesBuf.baseAddress
                                        info.pVertexInputState =
                                            withUnsafePointer(to: &vertexInput) { $0 }
                                        info.pInputAssemblyState =
                                            withUnsafePointer(to: &assembly) { $0 }
                                        info.pViewportState =
                                            withUnsafePointer(to: &viewportState) { $0 }
                                        info.pRasterizationState =
                                            withUnsafePointer(to: &raster) { $0 }
                                        info.pMultisampleState =
                                            withUnsafePointer(to: &multisample) { $0 }
                                        info.pDepthStencilState =
                                            withUnsafePointer(to: &depthStencil) { $0 }
                                        info.pColorBlendState =
                                            withUnsafePointer(to: &blend) { $0 }
                                        info.pDynamicState =
                                            withUnsafePointer(to: &dynamic) { $0 }
                                        info.layout = validLayout
                                        info.renderPass = compatiblePass
                                        info.subpass = 0
                                        return vkCreateGraphicsPipelines(
                                            vkDevice, nil, 1, &info, nil, &createdPipeline)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            guard pipelineResult == VK_SUCCESS, let validPipeline = createdPipeline else {
                vkDestroyPipelineLayout(vkDevice, validLayout, nil)
                vkDestroyRenderPass(vkDevice, compatiblePass, nil)
                throw CajuVulkanTranslation.rhiError(fromVkResult: pipelineResult.rawValue)
            }

            let record = CajuVulkanRenderPipelineRecord(
                pipeline: validPipeline,
                layout: validLayout,
                compatibleRenderPass: compatiblePass,
                pushConstantStages: pushStages,
                descriptor: descriptor
            )
            return renderPipelines.insert(record)
        }

        private func createCompatibleRenderPass(
            colorTargets: [CajuColorTargetState],
            depth: CajuDepthState?,
            sampleCountBits: UInt32
        ) throws(CajuRHIError) -> VkRenderPass {
            var attachments = [VkAttachmentDescription]()
            var colorRefs = [VkAttachmentReference]()
            attachments.reserveCapacity(colorTargets.count + (depth == nil ? 0 : 1))
            colorRefs.reserveCapacity(colorTargets.count)

            for (index, target) in colorTargets.enumerated() {
                var desc = VkAttachmentDescription()
                desc.format = VkFormat(rawValue: CajuVulkanTranslation.vkFormat(for: target.format))
                desc.samples = VkSampleCountFlagBits(rawValue: sampleCountBits)
                desc.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
                desc.storeOp = VK_ATTACHMENT_STORE_OP_STORE
                desc.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
                desc.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
                desc.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
                desc.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
                attachments.append(desc)
                colorRefs.append(
                    VkAttachmentReference(
                        attachment: UInt32(index),
                        layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                    ))
            }

            var depthRef = VkAttachmentReference(
                attachment: UInt32(attachments.count),
                layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
            )
            let hasDepth = depth != nil
            if let depth {
                var desc = VkAttachmentDescription()
                desc.format = VkFormat(rawValue: CajuVulkanTranslation.vkFormat(for: depth.format))
                desc.samples = VkSampleCountFlagBits(rawValue: sampleCountBits)
                desc.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
                desc.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
                desc.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
                desc.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
                desc.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
                desc.finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
                attachments.append(desc)
            }

            var dependency = VkSubpassDependency()
            dependency.srcSubpass = UInt32.max  // VK_SUBPASS_EXTERNAL
            dependency.dstSubpass = 0
            dependency.srcStageMask = VkPipelineStageFlags(
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            dependency.dstStageMask = VkPipelineStageFlags(
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            dependency.dstAccessMask = VkAccessFlags(
                VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)

            var createdPass: VkRenderPass?
            let result: VkResult = attachments.withUnsafeBufferPointer { attBuf in
                colorRefs.withUnsafeBufferPointer { colorRefBuf in
                    withUnsafePointer(to: &depthRef) { depthRefPtr in
                        var subpass = VkSubpassDescription()
                        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
                        subpass.colorAttachmentCount = UInt32(colorRefBuf.count)
                        subpass.pColorAttachments = colorRefBuf.baseAddress
                        if hasDepth {
                            subpass.pDepthStencilAttachment = depthRefPtr
                        }
                        return withUnsafePointer(to: &subpass) { subpassPtr in
                            withUnsafePointer(to: &dependency) { depPtr in
                                var info = VkRenderPassCreateInfo()
                                info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
                                info.attachmentCount = UInt32(attBuf.count)
                                info.pAttachments = attBuf.baseAddress
                                info.subpassCount = 1
                                info.pSubpasses = subpassPtr
                                info.dependencyCount = 1
                                info.pDependencies = depPtr
                                return vkCreateRenderPass(vkDevice, &info, nil, &createdPass)
                            }
                        }
                    }
                }
            }
            try checkVk(result)
            guard let validPass = createdPass else {
                throw .backend(code: VK_ERROR_INITIALIZATION_FAILED.rawValue)
            }
            return validPass
        }

        // MARK: Swapchain

        /// Cria a swapchain associada à superfície nativa Android (`ANativeWindow`).
        public func createSwapchain(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError)
            -> CajuVulkanSwapchain
        {
            let swapchain = CajuVulkanSwapchain(device: self)
            try swapchain.recreate(surface)
            activeSwapchain = swapchain
            return swapchain
        }

        // MARK: Recursos adiados nesta 1ª fatia (lançam .unsupported)

        /// Criação de texturas avulsas adiada nesta 1ª fatia (apenas imagens de swapchain).
        public func createTexture(_ descriptor: CajuTextureDescriptor) throws(CajuRHIError)
            -> CajuTextureHandle
        {
            guard descriptor.width > 0, descriptor.height > 0, descriptor.depthOrLayers > 0 else {
                throw .invalidDescriptor(.zeroSize)
            }
            guard !descriptor.usage.isEmpty else { throw .invalidDescriptor(.emptyUsage) }
            if descriptor.storage == .memoryless {
                throw .unsupported(.memorylessAttachments)
            }
            throw .unsupported(.pixelFormat(descriptor.format))
        }

        /// Samplers adiados nesta 1ª fatia.
        public func createSampler(_ descriptor: CajuSamplerDescriptor) throws(CajuRHIError)
            -> CajuSamplerHandle
        {
            guard descriptor.maxAnisotropy >= 1,
                descriptor.maxAnisotropy <= capabilities.maxAnisotropy
            else {
                throw .invalidDescriptor(.exceedsDeviceLimit)
            }
            throw .unsupported(.pixelFormat(.rgba8Unorm))
        }

        /// Compute pipelines adiados nesta 1ª fatia.
        public func createComputePipeline(_ descriptor: CajuComputePipelineDescriptor)
            throws(CajuRHIError) -> CajuComputePipelineHandle
        {
            throw .unsupported(.computePipelines)
        }

        /// Upload de textura adiado nesta 1ª fatia.
        public func writeTexture(
            _ texture: CajuTextureHandle, mipLevel: Int, slice: Int, width: Int, height: Int,
            bytesPerRow: Int, bytes: UnsafeRawBufferPointer
        ) throws(CajuRHIError) {
            guard let record = textures.value(for: texture) else {
                throw CajuHandlePool<CajuTextureTag, CajuVulkanTextureRecord>.invalid(texture)
            }
            throw .unsupported(.pixelFormat(record.descriptor.format))
        }

        /// Texturas transitórias adiadas nesta 1ª fatia.
        public func transientTexture(_ descriptor: CajuTextureDescriptor, slot: Int)
            throws(CajuRHIError) -> CajuTextureHandle
        {
            if descriptor.storage == .memoryless {
                throw .unsupported(.memorylessAttachments)
            }
            throw .unsupported(.pixelFormat(descriptor.format))
        }

        /// Libera texturas transitórias (sem efeito nesta 1ª fatia).
        public func releaseTransients() {}

        // MARK: Destruição

        /// Destrói um buffer e libera sua `VkDeviceMemory`.
        public func destroy(_ buffer: CajuBufferHandle) {
            guard let record = buffers.remove(buffer) else { return }
            if record.mapped != nil {
                vkUnmapMemory(vkDevice, record.memory)
            }
            vkDestroyBuffer(vkDevice, record.buffer, nil)
            vkFreeMemory(vkDevice, record.memory, nil)
        }

        /// Destrói uma textura registrada.
        public func destroy(_ texture: CajuTextureHandle) {
            textures.remove(texture)
        }

        /// Destrói um sampler (sem efeito nesta 1ª fatia).
        public func destroy(_ sampler: CajuSamplerHandle) {}

        /// Destrói um módulo de shader SPIR-V.
        public func destroy(_ shader: CajuShaderHandle) {
            guard let record = shaders.remove(shader) else { return }
            vkDestroyShaderModule(vkDevice, record.module, nil)
        }

        /// Destrói um pipeline gráfico, seu layout e seu render pass de compatibilidade.
        public func destroy(_ pipeline: CajuRenderPipelineHandle) {
            guard let record = renderPipelines.remove(pipeline) else { return }
            vkDestroyPipeline(vkDevice, record.pipeline, nil)
            vkDestroyPipelineLayout(vkDevice, record.layout, nil)
            vkDestroyRenderPass(vkDevice, record.compatibleRenderPass, nil)
        }

        /// Destrói um pipeline de compute (sem efeito nesta 1ª fatia).
        public func destroy(_ pipeline: CajuComputePipelineHandle) {}
    }

    // MARK: - Fila

    /// Fila de submissão Vulkan associada ao `CajuVulkanDevice`.
    public struct CajuVulkanQueue: CajuQueue {
        public typealias CommandBuffer = CajuVulkanCommandBuffer
        unowned let device: CajuVulkanDevice

        /// Prepara e inicia a gravação do command buffer do quadro em voo atual.
        public func makeCommandBuffer(label: String) throws(CajuRHIError)
            -> CajuVulkanCommandBuffer
        {
            try device.ensureFrameReady()
            let slot = device.frameIndex
            let cmd = device.commandBuffers[slot]
            try checkVk(vkResetCommandBuffer(cmd, 0))
            var beginInfo = VkCommandBufferBeginInfo()
            beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
            beginInfo.flags = VkCommandBufferUsageFlags(
                VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
            try checkVk(vkBeginCommandBuffer(cmd, &beginInfo))
            return CajuVulkanCommandBuffer(
                device: device, vkCommandBuffer: cmd, frameSlot: slot, label: label)
        }

        /// Encerra a gravação, submete à `VkQueue` com semáforos/fence do slot atual e apresenta
        /// na swapchain caso `present` tenha sido agendado. Sem alocação de heap.
        public func submit(_ commandBuffer: consuming CajuVulkanCommandBuffer)
            throws(CajuRHIError)
        {
            let slot = commandBuffer.frameSlot
            var recorded = commandBuffer.vkCommandBuffer
            try checkVk(vkEndCommandBuffer(recorded))

            var fence = device.inFlight[slot]
            try checkVk(vkResetFences(device.vkDevice, 1, &fence))

            if let pending = commandBuffer.pendingPresent,
                let swapchain = device.activeSwapchain,
                let vkSwapchain = swapchain.vkSwapchain,
                Int(pending.imageIndex) < swapchain.renderFinished.count
            {
                var waitSemaphore = device.imageAvailable[slot]
                var signalSemaphore = swapchain.renderFinished[Int(pending.imageIndex)]
                var waitStage = VkPipelineStageFlags(
                    VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)

                let submitResult: VkResult = withUnsafePointer(to: &waitSemaphore) { waitPtr in
                    withUnsafePointer(to: &waitStage) { stagePtr in
                        withUnsafePointer(to: &recorded) { cmdPtr in
                            withUnsafePointer(to: &signalSemaphore) { sigPtr in
                                var submitInfo = VkSubmitInfo()
                                submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                                submitInfo.waitSemaphoreCount =
                                    device.frameImageAcquired ? 1 : 0
                                submitInfo.pWaitSemaphores =
                                    device.frameImageAcquired ? waitPtr : nil
                                submitInfo.pWaitDstStageMask =
                                    device.frameImageAcquired ? stagePtr : nil
                                submitInfo.commandBufferCount = 1
                                submitInfo.pCommandBuffers = cmdPtr
                                submitInfo.signalSemaphoreCount = 1
                                submitInfo.pSignalSemaphores = sigPtr
                                return vkQueueSubmit(device.vkQueue, 1, &submitInfo, fence)
                            }
                        }
                    }
                }
                if submitResult != VK_SUCCESS {
                    device.advanceFrame()
                    throw CajuVulkanTranslation.rhiError(fromVkResult: submitResult.rawValue)
                }

                var chain: VkSwapchainKHR? = vkSwapchain
                var imgIndex = pending.imageIndex
                let presentResult: VkResult = withUnsafePointer(to: &signalSemaphore) { sigPtr in
                    withUnsafePointer(to: &chain) { chainPtr in
                        withUnsafePointer(to: &imgIndex) { idxPtr in
                            var presentInfo = VkPresentInfoKHR()
                            presentInfo.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
                            presentInfo.waitSemaphoreCount = 1
                            presentInfo.pWaitSemaphores = sigPtr
                            presentInfo.swapchainCount = 1
                            presentInfo.pSwapchains = chainPtr
                            presentInfo.pImageIndices = idxPtr
                            return vkQueuePresentKHR(device.vkQueue, &presentInfo)
                        }
                    }
                }
                device.advanceFrame()
                if presentResult == VK_ERROR_OUT_OF_DATE_KHR {
                    swapchain.markOutOfDate()
                    throw .surfaceOutOfDate
                } else if presentResult == VK_ERROR_SURFACE_LOST_KHR {
                    throw .surfaceLost
                } else if presentResult != VK_SUCCESS && presentResult != VK_SUBOPTIMAL_KHR {
                    throw CajuVulkanTranslation.rhiError(fromVkResult: presentResult.rawValue)
                }
            } else {
                let submitResult: VkResult = withUnsafePointer(to: &recorded) { cmdPtr in
                    var submitInfo = VkSubmitInfo()
                    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                    submitInfo.commandBufferCount = 1
                    submitInfo.pCommandBuffers = cmdPtr
                    return vkQueueSubmit(device.vkQueue, 1, &submitInfo, fence)
                }
                device.advanceFrame()
                try checkVk(submitResult)
            }
        }

        /// Bloqueia até a `VkQueue` ficar ociosa.
        public func waitUntilIdle() throws(CajuRHIError) {
            try checkVk(vkQueueWaitIdle(device.vkQueue))
        }
    }
#endif
