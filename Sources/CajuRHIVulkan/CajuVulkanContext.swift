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
        /// `vkCmdPushDescriptorSetKHR` quando o aparelho tem `VK_KHR_push_descriptor` (caminho principal de
        /// ligação de recursos; sem ela, o backend usa um *pool* de sets por submissão, ADR 0024).
        let pushDescriptorSet: PFN_vkCmdPushDescriptorSetKHR?

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

        /// Contagem de mensagens da camada de validação (erros, avisos), quando ela está ligada.
        let validationCounts: UnsafeMutablePointer<(errors: Int, warnings: Int)>
        let validationEnabled: Bool
        private var messenger: VkDebugUtilsMessengerEXT?

        init(enableSurface: Bool, enableValidation: Bool) throws(CajuRHIError) {
            surfaceEnabled = enableSurface
            validationCounts = .allocate(capacity: 1)
            validationCounts.initialize(to: (0, 0))
            let validation = enableValidation && Self.hasInstanceLayer("VK_LAYER_KHRONOS_validation")
            validationEnabled = validation

            // Instância.
            var application = VkApplicationInfo()
            application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
            application.pApplicationName = vkName("Caju")
            application.pEngineName = vkName("Caju")
            application.apiVersion = vulkan11
            var instanceExtensions: [UnsafePointer<CChar>?] =
                enableSurface ? [vkName("VK_KHR_surface"), vkName("VK_KHR_android_surface")] : []
            if validation { instanceExtensions.append(vkName("VK_EXT_debug_utils")) }
            let layers: [UnsafePointer<CChar>?] = validation ? [vkName("VK_LAYER_KHRONOS_validation")] : []
            var createdInstance: VkInstance?
            let instanceResult: VkResult = instanceExtensions.withUnsafeBufferPointer { extensions in
                layers.withUnsafeBufferPointer { layers in
                    withUnsafePointer(to: &application) { application in
                        var info = VkInstanceCreateInfo()
                        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                        info.pApplicationInfo = application
                        info.enabledExtensionCount = UInt32(extensions.count)
                        info.ppEnabledExtensionNames = extensions.baseAddress
                        info.enabledLayerCount = UInt32(layers.count)
                        info.ppEnabledLayerNames = layers.baseAddress
                        return vkCreateInstance(&info, nil, &createdInstance)
                    }
                }
            }
            try vkCheck(instanceResult)
            guard let instance = createdInstance else { throw .deviceLost }
            self.instance = instance
            if validation { messenger = Self.makeMessenger(instance, counts: validationCounts) }

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
            let hasPushDescriptor = Self.hasDeviceExtension(physicalDevice, "VK_KHR_push_descriptor")
            var deviceExtensions: [UnsafePointer<CChar>?] = enableSurface ? [vkName("VK_KHR_swapchain")] : []
            if hasPushDescriptor { deviceExtensions.append(vkName("VK_KHR_push_descriptor")) }
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
            if hasPushDescriptor, let function = vkGetDeviceProcAddr(device, "vkCmdPushDescriptorSetKHR") {
                pushDescriptorSet = unsafeBitCast(function, to: PFN_vkCmdPushDescriptorSetKHR.self)
            } else {
                pushDescriptorSet = nil
            }

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
            defer { validationCounts.deallocate() }
            vkDeviceWaitIdle(device)
            for entry in inFlight { vkDestroyFence(device, entry.fence, nil) }
            for fence in freeFences { vkDestroyFence(device, fence, nil) }
            vmaDestroyAllocator(allocator)
            vkDestroyCommandPool(device, commandPool, nil)  // libera também os command buffers
            vkDestroyDevice(device, nil)
            if let messenger, let destroy = vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT")
            {
                unsafeBitCast(destroy, to: PFN_vkDestroyDebugUtilsMessengerEXT.self)(instance, messenger, nil)
            }
            vkDestroyInstance(instance, nil)
        }

        // MARK: Camada de validação (só depuração; ADR 0024)

        private static func hasInstanceLayer(_ name: String) -> Bool {
            var count: UInt32 = 0
            guard vkEnumerateInstanceLayerProperties(&count, nil) == VK_SUCCESS, count > 0 else {
                return false
            }
            var properties = [VkLayerProperties](repeating: VkLayerProperties(), count: Int(count))
            guard vkEnumerateInstanceLayerProperties(&count, &properties) == VK_SUCCESS else { return false }
            return properties.contains { property in
                var layerName = property.layerName
                return withUnsafePointer(to: &layerName) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(VK_MAX_EXTENSION_NAME_SIZE)) {
                        String(cString: $0) == name
                    }
                }
            }
        }

        /// Encaminha avisos e erros da camada ao logcat (tag `CajuVulkan`) e os conta.
        private static func makeMessenger(
            _ instance: VkInstance, counts: UnsafeMutablePointer<(errors: Int, warnings: Int)>
        ) -> VkDebugUtilsMessengerEXT? {
            guard let create = vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT") else {
                return nil
            }
            var info = VkDebugUtilsMessengerCreateInfoEXT()
            info.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
            info.messageSeverity = VkDebugUtilsMessageSeverityFlagsEXT(
                VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT.rawValue
                    | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT.rawValue)
            info.messageType = VkDebugUtilsMessageTypeFlagsEXT(
                VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT.rawValue
                    | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT.rawValue
                    | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT.rawValue)
            info.pfnUserCallback = { severity, _, data, user in
                // A camada do Khronos sempre dá um id (`VUID-…`, `UNASSIGNED-…`, `SYNC-…`); o driver Adreno manda
                // dicas próprias pelo mesmo canal, sem id (ex.: VKDBGUTILWARN003, multipass), marcadas como
                // erro de validação. Só as do Khronos contam como erro; as do driver são avisos.
                let fromKhronos = data?.pointee.pMessageIdName != nil
                let isError =
                    fromKhronos
                    && severity.rawValue & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT.rawValue != 0
                var warnings = 0
                if let user {
                    let counts = user.assumingMemoryBound(to: (errors: Int, warnings: Int).self)
                    if isError { counts.pointee.errors += 1 } else { counts.pointee.warnings += 1 }
                    warnings = counts.pointee.warnings
                }
                // Avisos do driver se repetem a cada quadro: só os primeiros vão ao logcat.
                guard fromKhronos || warnings <= 5 else { return VkBool32(VK_FALSE) }
                let message = data?.pointee.pMessage ?? vkName("?")
                let tag = fromKhronos ? vkName("CajuVulkan") : vkName("CajuVulkanDriver")
                _ = __android_log_write(
                    Int32((isError ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN).rawValue), tag, message)
                return VkBool32(VK_FALSE)
            }
            info.pUserData = UnsafeMutableRawPointer(counts)
            var messenger: VkDebugUtilsMessengerEXT?
            let result = unsafeBitCast(create, to: PFN_vkCreateDebugUtilsMessengerEXT.self)(
                instance, &info, nil, &messenger)
            return result == VK_SUCCESS ? messenger : nil
        }

        // MARK: Capacidades

        private static func hasDeviceExtension(_ physicalDevice: VkPhysicalDevice, _ name: String) -> Bool {
            var count: UInt32 = 0
            guard vkEnumerateDeviceExtensionProperties(physicalDevice, nil, &count, nil) == VK_SUCCESS else {
                return false
            }
            var properties = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
            guard vkEnumerateDeviceExtensionProperties(physicalDevice, nil, &count, &properties) == VK_SUCCESS
            else { return false }
            return properties.contains { property in
                var extensionName = property.extensionName
                return withUnsafePointer(to: &extensionName) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(VK_MAX_EXTENSION_NAME_SIZE)) {
                        String(cString: $0) == name
                    }
                }
            }
        }

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
