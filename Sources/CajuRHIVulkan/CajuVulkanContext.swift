#if os(Android)
    import CVulkan
    import CajuRHI

    /// Instância, dispositivo, fila e alocador (VMA) do backend, mais a maquinaria de submissão:
    /// *command buffers* reaproveitados, uma *fence* por submissão e um número de série crescente
    /// (ADR 0024). Tudo na Game Thread; não é `Sendable`.
    final class CajuVulkanContext {
        let instance: VkInstance
        let physicalDevice: VkPhysicalDevice
        let device: VkDevice
        let queue: VkQueue
        let queueFamily: UInt32
        let allocator: VmaAllocator
        let capabilities: CajuDeviceCapabilities
        let limits: VkPhysicalDeviceLimits
        let surfaceEnabled: Bool

        private let commandPool: VkCommandPool
        private var freeCommandBuffers: [VkCommandBuffer] = []
        private var freeFences: [VkFence] = []

        private struct InFlight {
            var serial: UInt64
            var fence: VkFence
            var commandBuffer: VkCommandBuffer
        }
        private var inFlight: [InFlight] = []
        /// Série da última submissão enviada e da última comprovadamente concluída pela GPU.
        private(set) var submittedSerial: UInt64 = 0
        private(set) var completedSerial: UInt64 = 0

        init(enableSurface: Bool) throws(CajuRHIError) {
            surfaceEnabled = enableSurface

            // Instância.
            var application = VkApplicationInfo()
            application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
            application.pApplicationName = vkName("Caju")
            application.pEngineName = vkName("Caju")
            application.apiVersion = vulkan11
            let instanceExtensions: [UnsafePointer<CChar>?] =
                enableSurface ? [vkName("VK_KHR_surface"), vkName("VK_KHR_android_surface")] : []
            var createdInstance: VkInstance?
            let instanceResult: VkResult = instanceExtensions.withUnsafeBufferPointer { extensions in
                withUnsafePointer(to: &application) { application in
                    var info = VkInstanceCreateInfo()
                    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                    info.pApplicationInfo = application
                    info.enabledExtensionCount = UInt32(extensions.count)
                    info.ppEnabledExtensionNames = extensions.baseAddress
                    return vkCreateInstance(&info, nil, &createdInstance)
                }
            }
            try vkCheck(instanceResult)
            guard let instance = createdInstance else { throw .deviceLost }
            self.instance = instance

            // Dispositivo físico com fila gráfica.
            var count: UInt32 = 0
            try vkCheck(vkEnumeratePhysicalDevices(instance, &count, nil))
            var physicalDevices = [VkPhysicalDevice?](repeating: nil, count: Int(count))
            try vkCheck(vkEnumeratePhysicalDevices(instance, &count, &physicalDevices))
            var chosen: VkPhysicalDevice?
            var family: UInt32 = 0
            search: for candidate in physicalDevices {
                var familyCount: UInt32 = 0
                vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, nil)
                var families = [VkQueueFamilyProperties](
                    repeating: VkQueueFamilyProperties(), count: Int(familyCount))
                vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, &families)
                for (index, properties) in families.enumerated()
                where properties.queueFlags & VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue) != 0 {
                    chosen = candidate
                    family = UInt32(index)
                    break search
                }
            }
            guard let physicalDevice = chosen else { throw .deviceLost }
            self.physicalDevice = physicalDevice
            queueFamily = family

            var properties = VkPhysicalDeviceProperties()
            vkGetPhysicalDeviceProperties(physicalDevice, &properties)
            guard properties.apiVersion >= vulkan11 else { throw .unsupported(.computePipelines) }
            limits = properties.limits
            var supported = VkPhysicalDeviceFeatures()
            vkGetPhysicalDeviceFeatures(physicalDevice, &supported)

            // Dispositivo lógico: só o que o contrato usa e o aparelho oferece.
            var enabled = VkPhysicalDeviceFeatures()
            enabled.samplerAnisotropy = supported.samplerAnisotropy
            enabled.textureCompressionASTC_LDR = supported.textureCompressionASTC_LDR
            var priority: Float = 1
            var queueInfo = VkDeviceQueueCreateInfo()
            queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            queueInfo.queueFamilyIndex = family
            queueInfo.queueCount = 1
            let deviceExtensions: [UnsafePointer<CChar>?] = enableSurface ? [vkName("VK_KHR_swapchain")] : []
            var createdDevice: VkDevice?
            let deviceResult: VkResult = deviceExtensions.withUnsafeBufferPointer { extensions in
                withUnsafePointer(to: &priority) { priority in
                    queueInfo.pQueuePriorities = priority
                    return withUnsafePointer(to: &queueInfo) { queueInfo in
                        withUnsafePointer(to: &enabled) { enabled in
                            var info = VkDeviceCreateInfo()
                            info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                            info.queueCreateInfoCount = 1
                            info.pQueueCreateInfos = queueInfo
                            info.enabledExtensionCount = UInt32(extensions.count)
                            info.ppEnabledExtensionNames = extensions.baseAddress
                            info.pEnabledFeatures = enabled
                            return vkCreateDevice(physicalDevice, &info, nil, &createdDevice)
                        }
                    }
                }
            }
            try vkCheck(deviceResult)
            guard let device = createdDevice else { throw .deviceLost }
            self.device = device
            var createdQueue: VkQueue?
            vkGetDeviceQueue(device, family, 0, &createdQueue)
            guard let queue = createdQueue else { throw .deviceLost }
            self.queue = queue

            // Pool de command buffers (um só: a fila é única e a thread é uma).
            var poolInfo = VkCommandPoolCreateInfo()
            poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
            poolInfo.flags = VkCommandPoolCreateFlags(
                VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
            poolInfo.queueFamilyIndex = family
            var createdPool: VkCommandPool?
            let poolResult = vkCreateCommandPool(device, &poolInfo, nil, &createdPool)
            guard poolResult == VK_SUCCESS, let pool = createdPool else {
                vkDestroyDevice(device, nil)
                vkDestroyInstance(instance, nil)
                throw mapVkResult(poolResult)
            }
            commandPool = pool

            // Alocador de memória (VMA, funções ligadas estaticamente; Vulkan 1.1).
            var allocatorInfo = VmaAllocatorCreateInfo(
                flags: 0, physicalDevice: physicalDevice, device: device, preferredLargeHeapBlockSize: 0,
                pAllocationCallbacks: nil, pDeviceMemoryCallbacks: nil, pHeapSizeLimit: nil,
                pVulkanFunctions: nil, instance: instance, vulkanApiVersion: vulkan11,
                pTypeExternalMemoryHandleTypes: nil)
            var createdAllocator: VmaAllocator?
            let allocatorResult = vmaCreateAllocator(&allocatorInfo, &createdAllocator)
            guard allocatorResult == VK_SUCCESS, let allocator = createdAllocator else {
                vkDestroyCommandPool(device, pool, nil)
                vkDestroyDevice(device, nil)
                vkDestroyInstance(instance, nil)
                throw mapVkResult(allocatorResult)
            }
            self.allocator = allocator

            capabilities = Self.makeCapabilities(
                physicalDevice: physicalDevice, properties: properties, features: supported)
        }

        deinit {
            vkDeviceWaitIdle(device)
            for entry in inFlight { vkDestroyFence(device, entry.fence, nil) }
            for fence in freeFences { vkDestroyFence(device, fence, nil) }
            vmaDestroyAllocator(allocator)
            vkDestroyCommandPool(device, commandPool, nil)  // libera também os command buffers
            vkDestroyDevice(device, nil)
            vkDestroyInstance(instance, nil)
        }

        // MARK: Capacidades

        private static func makeCapabilities(
            physicalDevice: VkPhysicalDevice, properties: VkPhysicalDeviceProperties,
            features: VkPhysicalDeviceFeatures
        ) -> CajuDeviceCapabilities {
            let limits = properties.limits
            var name = properties.deviceName
            let deviceName = withUnsafePointer(to: &name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(VK_MAX_PHYSICAL_DEVICE_NAME_SIZE)) {
                    String(cString: $0)
                }
            }
            var maintenance = VkPhysicalDeviceMaintenance3Properties()
            maintenance.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_3_PROPERTIES
            withUnsafeMutablePointer(to: &maintenance) { maintenance in
                var query = VkPhysicalDeviceProperties2()
                query.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
                query.pNext = UnsafeMutableRawPointer(maintenance)
                vkGetPhysicalDeviceProperties2(physicalDevice, &query)
            }
            var memory = VkPhysicalDeviceMemoryProperties()
            vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memory)
            var lazy = false
            withUnsafePointer(to: &memory.memoryTypes) {
                $0.withMemoryRebound(to: VkMemoryType.self, capacity: Int(VK_MAX_MEMORY_TYPES)) { types in
                    for index in 0..<Int(memory.memoryTypeCount)
                    where types[index].propertyFlags
                        & VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT.rawValue) != 0
                    {
                        lazy = true
                    }
                }
            }
            let colorSamples = CajuSampleCounts(vulkan: limits.framebufferColorSampleCounts)
            let depthSamples = CajuSampleCounts(vulkan: limits.framebufferDepthSampleCounts)
            return CajuDeviceCapabilities(
                backendName: "Vulkan", deviceName: deviceName,
                maxTextureDimension2D: Int(limits.maxImageDimension2D),
                maxColorAttachments: Int(min(limits.maxColorAttachments, 8)),
                maxVertexBuffers: Int(min(limits.maxVertexInputBindings, 31)),
                maxBufferSize: Int(truncatingIfNeeded: maintenance.maxMemoryAllocationSize),
                maxAnisotropy: features.samplerAnisotropy != 0 ? Int(limits.maxSamplerAnisotropy) : 1,
                uniformBufferAlignment: Int(limits.minUniformBufferOffsetAlignment),
                sampleCounts: colorSamples.intersection(depthSamples),
                supportsMemoryless: lazy,
                supportsCompute: false,  // compute chega depois da V-1 (não está nos gates da Onda 1)
                supportsASTC: features.textureCompressionASTC_LDR != 0,
                presentModes: [.fifo])
        }

        /// Propriedades de formato (para validar usos pedidos).
        func formatFeatures(_ format: VkFormat) -> VkFormatFeatureFlags {
            var properties = VkFormatProperties()
            vkGetPhysicalDeviceFormatProperties(physicalDevice, format, &properties)
            return properties.optimalTilingFeatures
        }

        // MARK: Submissão

        /// Pega um *command buffer* livre (ou aloca) e já inicia a gravação.
        func beginCommandBuffer() throws(CajuRHIError) -> VkCommandBuffer {
            poll()
            var commandBuffer: VkCommandBuffer?
            if let reused = freeCommandBuffers.popLast() {
                commandBuffer = reused
            } else {
                var allocate = VkCommandBufferAllocateInfo()
                allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
                allocate.commandPool = commandPool
                allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
                allocate.commandBufferCount = 1
                try vkCheck(vkAllocateCommandBuffers(device, &allocate, &commandBuffer))
            }
            guard let commandBuffer else { throw .outOfMemory }
            var begin = VkCommandBufferBeginInfo()
            begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
            begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
            try vkCheck(vkBeginCommandBuffer(commandBuffer, &begin))
            return commandBuffer
        }

        /// Encerra e envia o *command buffer*; devolve a série da submissão.
        /// `wait`/`signal` são os semáforos da apresentação (nulos fora do *swapchain*).
        @discardableResult
        func submit(
            _ commandBuffer: VkCommandBuffer, waitSemaphore: VkSemaphore? = nil,
            waitStage: VkPipelineStageFlags = 0, signalSemaphore: VkSemaphore? = nil
        ) throws(CajuRHIError) -> UInt64 {
            try vkCheck(vkEndCommandBuffer(commandBuffer))
            var fence: VkFence?
            if let reused = freeFences.popLast() {
                fence = reused
            } else {
                var info = VkFenceCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
                try vkCheck(vkCreateFence(device, &info, nil, &fence))
            }
            guard let fence else { throw .outOfMemory }
            var wait = waitSemaphore
            var stage = waitStage
            var signal = signalSemaphore
            var buffer: VkCommandBuffer? = commandBuffer
            let result: VkResult = withUnsafePointer(to: &buffer) { buffer in
                var info = VkSubmitInfo()
                info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                info.commandBufferCount = 1
                info.pCommandBuffers = buffer
                return withUnsafePointer(to: &wait) { wait in
                    withUnsafePointer(to: &stage) { stage in
                        withUnsafePointer(to: &signal) { signal in
                            if waitSemaphore != nil {
                                info.waitSemaphoreCount = 1
                                info.pWaitSemaphores = wait
                                info.pWaitDstStageMask = stage
                            }
                            if signalSemaphore != nil {
                                info.signalSemaphoreCount = 1
                                info.pSignalSemaphores = signal
                            }
                            return vkQueueSubmit(queue, 1, &info, fence)
                        }
                    }
                }
            }
            guard result == VK_SUCCESS else {
                freeFences.append(fence)
                throw mapVkResult(result)
            }
            submittedSerial += 1
            inFlight.append(InFlight(serial: submittedSerial, fence: fence, commandBuffer: commandBuffer))
            return submittedSerial
        }

        /// Recolhe as submissões que a GPU já terminou (sem bloquear).
        func poll() {
            while let first = inFlight.first, vkGetFenceStatus(device, first.fence) == VK_SUCCESS {
                retire(first)
                inFlight.removeFirst()
            }
        }

        private func retire(_ entry: InFlight) {
            completedSerial = entry.serial
            var fence: VkFence? = entry.fence
            vkResetFences(device, 1, &fence)
            freeFences.append(entry.fence)
            vkResetCommandBuffer(entry.commandBuffer, 0)
            freeCommandBuffers.append(entry.commandBuffer)
        }

        /// Bloqueia até a submissão `serial` terminar (e todas as anteriores).
        func wait(for serial: UInt64) throws(CajuRHIError) {
            while let first = inFlight.first, first.serial <= serial {
                var fence: VkFence? = first.fence
                try vkCheck(vkWaitForFences(device, 1, &fence, VkBool32(VK_TRUE), UInt64.max))
                retire(first)
                inFlight.removeFirst()
            }
        }

        func waitIdle() throws(CajuRHIError) {
            try vkCheck(vkQueueWaitIdle(queue))
            try wait(for: submittedSerial)
        }
    }
#endif
