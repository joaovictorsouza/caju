#if os(Android)
    import Android
    import CVulkan
    import CajuPlatform

    /// Ponteiro C estático de um literal (sem alocar).
    private func cString(_ string: StaticString) -> UnsafePointer<CChar> {
        UnsafeRawPointer(string.utf8Start).assumingMemoryBound(to: CChar.self)
    }

    @inline(__always)
    private func check(_ result: VkResult, _ step: CajuVulkanStep) throws(CajuVulkanError) {
        guard result == VK_SUCCESS else { throw .vulkan(step: step, code: result.rawValue) }
    }

    /// Renderiza um triângulo girando em Vulkan 1.1 sobre uma `ANativeWindow`.
    ///
    /// Tudo roda na Game Thread. Ciclo: `attach(window:)` ao criar a superfície,
    /// `drawFrame()` por quadro, `resize()` quando o sistema muda a janela e
    /// `detach()` antes de a superfície ser destruída. É uma `class` porque possui
    /// handles nativos com ciclo de vida (liberados no `deinit`).
    public final class CajuVulkanTriangleRenderer {
        private static let framesInFlight = 2

        // Duradouros (instância / dispositivo).
        private var instance: VkInstance?
        private var physicalDevice: VkPhysicalDevice?
        private var device: VkDevice?
        private var queue: VkQueue?
        private var queueFamily: UInt32 = 0
        private var commandPool: VkCommandPool?
        private var pipelineLayout: VkPipelineLayout?
        private var vertexShader: VkShaderModule?
        private var fragmentShader: VkShaderModule?
        private var commandBuffers = [VkCommandBuffer?](repeating: nil, count: framesInFlight)
        private var imageAvailable = [VkSemaphore?](repeating: nil, count: framesInFlight)
        private var inFlight = [VkFence?](repeating: nil, count: framesInFlight)
        private var frameIndex = 0

        // Dependentes da superfície.
        private var window: CajuNativeWindow?
        private var surface: VkSurfaceKHR?
        private var swapchain: VkSwapchainKHR?
        private var swapchainFormat = VK_FORMAT_UNDEFINED
        private var extent = VkExtent2D()
        private var images: [VkImage?] = []
        private var imageViews: [VkImageView?] = []
        private var framebuffers: [VkFramebuffer?] = []
        private var renderFinished: [VkSemaphore?] = []
        private var renderPass: VkRenderPass?
        private var pipeline: VkPipeline?
        private var needsRecreate = false
        private var startTime = timespec()

        /// Cria a instância Vulkan (nenhuma janela ainda).
        public init() throws(CajuVulkanError) {
            var application = VkApplicationInfo()
            application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
            application.pApplicationName = cString("Caju")
            application.pEngineName = cString("Caju")
            application.apiVersion = (1 << 22) | (1 << 12)  // Vulkan 1.1

            let extensions: [UnsafePointer<CChar>?] = [
                cString("VK_KHR_surface"), cString("VK_KHR_android_surface"),
            ]
            var created: VkInstance?
            let result: VkResult = extensions.withUnsafeBufferPointer { extensions in
                withUnsafePointer(to: &application) { application in
                    var info = VkInstanceCreateInfo()
                    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                    info.pApplicationInfo = application
                    info.enabledExtensionCount = UInt32(extensions.count)
                    info.ppEnabledExtensionNames = extensions.baseAddress
                    return vkCreateInstance(&info, nil, &created)
                }
            }
            try check(result, .instance)
            instance = created
            clock_gettime(CLOCK_MONOTONIC, &startTime)
        }

        deinit {
            if let device { vkDeviceWaitIdle(device) }
            destroySwapchainObjects()
            destroySurface()
            destroyDeviceObjects()
            if let device { vkDestroyDevice(device, nil) }
            if let instance { vkDestroyInstance(instance, nil) }
        }

        // MARK: Ciclo de vida da superfície

        /// Cria superfície, (na primeira vez) o dispositivo, e a swapchain.
        public func attach(window newWindow: CajuNativeWindow) throws(CajuVulkanError) {
            detach()
            window = newWindow
            var info = VkAndroidSurfaceCreateInfoKHR()
            info.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR
            info.window = OpaquePointer(newWindow.raw)
            var created: VkSurfaceKHR?
            try check(vkCreateAndroidSurfaceKHR(instance, &info, nil, &created), .surface)
            surface = created
            if device == nil { try createDevice() }
            try createSwapchainObjects()
        }

        /// Solta tudo que depende da janela. Idempotente.
        public func detach() {
            if let device { vkDeviceWaitIdle(device) }
            destroySwapchainObjects()
            destroySurface()
            window = nil
        }

        /// O sistema mudou o tamanho/rotação da janela: recria a swapchain no próximo quadro.
        public func resize() { needsRecreate = true }

        // MARK: Quadro

        /// Desenha e apresenta um quadro (bloqueia no vsync via FIFO). Sem alocação de heap.
        public func drawFrame() throws(CajuVulkanError) {
            guard let device, let queue, swapchain != nil else { return }
            if needsRecreate {
                needsRecreate = false
                try recreateSwapchain()
                guard swapchain != nil else { return }
            }
            let frame = frameIndex
            var fence = inFlight[frame]
            try check(vkWaitForFences(device, 1, &fence, VkBool32(VK_TRUE), UInt64.max), .synchronization)

            var imageIndex: UInt32 = 0
            let acquire = vkAcquireNextImageKHR(
                device, swapchain, UInt64.max, imageAvailable[frame], nil, &imageIndex)
            if acquire == VK_ERROR_OUT_OF_DATE_KHR {
                try recreateSwapchain()
                return
            }
            guard acquire == VK_SUCCESS || acquire == VK_SUBOPTIMAL_KHR else {
                throw .vulkan(step: .acquire, code: acquire.rawValue)
            }
            try check(vkResetFences(device, 1, &fence), .synchronization)

            let commandBuffer = commandBuffers[frame]
            try check(vkResetCommandBuffer(commandBuffer, 0), .record)
            try record(commandBuffer, imageIndex: Int(imageIndex))

            var waitSemaphore = imageAvailable[frame]
            var signalSemaphore = renderFinished[Int(imageIndex)]
            var waitStage = VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            var recorded = commandBuffer
            var submit = VkSubmitInfo()
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
            submit.waitSemaphoreCount = 1
            submit.pWaitSemaphores = withUnsafePointer(to: &waitSemaphore) { $0 }
            submit.pWaitDstStageMask = withUnsafePointer(to: &waitStage) { $0 }
            submit.commandBufferCount = 1
            submit.pCommandBuffers = withUnsafePointer(to: &recorded) { $0 }
            submit.signalSemaphoreCount = 1
            submit.pSignalSemaphores = withUnsafePointer(to: &signalSemaphore) { $0 }
            try check(vkQueueSubmit(queue, 1, &submit, fence), .submit)

            var present = VkPresentInfoKHR()
            present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
            present.waitSemaphoreCount = 1
            present.pWaitSemaphores = withUnsafePointer(to: &signalSemaphore) { $0 }
            present.swapchainCount = 1
            var chain = swapchain
            present.pSwapchains = withUnsafePointer(to: &chain) { $0 }
            present.pImageIndices = withUnsafePointer(to: &imageIndex) { $0 }
            let presented = vkQueuePresentKHR(queue, &present)
            frameIndex = (frame + 1) % Self.framesInFlight
            if presented == VK_ERROR_OUT_OF_DATE_KHR {
                needsRecreate = true
            } else if presented != VK_SUCCESS && presented != VK_SUBOPTIMAL_KHR {
                throw .vulkan(step: .present, code: presented.rawValue)
            }
        }

        private func record(_ commandBuffer: VkCommandBuffer?, imageIndex: Int) throws(CajuVulkanError) {
            var begin = VkCommandBufferBeginInfo()
            begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
            try check(vkBeginCommandBuffer(commandBuffer, &begin), .record)

            var clear = VkClearValue(color: VkClearColorValue(float32: (0.04, 0.05, 0.09, 1.0)))
            var passInfo = VkRenderPassBeginInfo()
            passInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
            passInfo.renderPass = renderPass
            passInfo.framebuffer = framebuffers[imageIndex]
            passInfo.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: extent)
            passInfo.clearValueCount = 1
            passInfo.pClearValues = withUnsafePointer(to: &clear) { $0 }
            vkCmdBeginRenderPass(commandBuffer, &passInfo, VK_SUBPASS_CONTENTS_INLINE)
            vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
            var viewport = VkViewport(
                x: 0, y: 0, width: Float(extent.width), height: Float(extent.height), minDepth: 0, maxDepth: 1
            )
            vkCmdSetViewport(commandBuffer, 0, 1, &viewport)
            var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: extent)
            vkCmdSetScissor(commandBuffer, 0, 1, &scissor)

            var now = timespec()
            clock_gettime(CLOCK_MONOTONIC, &now)
            let seconds = Float(now.tv_sec - startTime.tv_sec) + Float(now.tv_nsec - startTime.tv_nsec) * 1e-9
            var push: (Float, Float) = (seconds * 1.2, Float(extent.width) / Float(extent.height))
            vkCmdPushConstants(
                commandBuffer, pipelineLayout, VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue), 0, 8,
                &push)
            vkCmdDraw(commandBuffer, 3, 1, 0, 0)
            vkCmdEndRenderPass(commandBuffer)
            try check(vkEndCommandBuffer(commandBuffer), .record)
        }

        // MARK: Dispositivo (uma vez)

        private func createDevice() throws(CajuVulkanError) {
            var count: UInt32 = 0
            try check(vkEnumeratePhysicalDevices(instance, &count, nil), .enumerateDevices)
            var devices = [VkPhysicalDevice?](repeating: nil, count: Int(count))
            try check(vkEnumeratePhysicalDevices(instance, &count, &devices), .enumerateDevices)

            var chosen: VkPhysicalDevice?
            var family: UInt32 = 0
            search: for candidate in devices {
                var familyCount: UInt32 = 0
                vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, nil)
                var families = [VkQueueFamilyProperties](
                    repeating: VkQueueFamilyProperties(), count: Int(familyCount))
                vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, &families)
                for (index, properties) in families.enumerated()
                where properties.queueFlags & VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue) != 0 {
                    var supported: VkBool32 = 0
                    vkGetPhysicalDeviceSurfaceSupportKHR(candidate, UInt32(index), surface, &supported)
                    if supported != 0 {
                        chosen = candidate
                        family = UInt32(index)
                        break search
                    }
                }
            }
            guard let chosen else { throw .noSuitableDevice }
            physicalDevice = chosen
            queueFamily = family

            var priority: Float = 1
            var queueInfo = VkDeviceQueueCreateInfo()
            queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            queueInfo.queueFamilyIndex = family
            queueInfo.queueCount = 1
            queueInfo.pQueuePriorities = withUnsafePointer(to: &priority) { $0 }
            let extensions: [UnsafePointer<CChar>?] = [cString("VK_KHR_swapchain")]
            var created: VkDevice?
            let result: VkResult = extensions.withUnsafeBufferPointer { extensions in
                var info = VkDeviceCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                info.queueCreateInfoCount = 1
                info.pQueueCreateInfos = withUnsafePointer(to: &queueInfo) { $0 }
                info.enabledExtensionCount = 1
                info.ppEnabledExtensionNames = extensions.baseAddress
                return vkCreateDevice(chosen, &info, nil, &created)
            }
            try check(result, .device)
            device = created
            vkGetDeviceQueue(created, family, 0, &queue)

            var poolInfo = VkCommandPoolCreateInfo()
            poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
            poolInfo.flags = VkCommandPoolCreateFlags(
                VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
            poolInfo.queueFamilyIndex = family
            try check(vkCreateCommandPool(created, &poolInfo, nil, &commandPool), .commandPool)

            var allocate = VkCommandBufferAllocateInfo()
            allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
            allocate.commandPool = commandPool
            allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
            allocate.commandBufferCount = UInt32(Self.framesInFlight)
            try check(vkAllocateCommandBuffers(created, &allocate, &commandBuffers), .commandBuffer)

            for frame in 0..<Self.framesInFlight {
                var semaphoreInfo = VkSemaphoreCreateInfo()
                semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
                try check(
                    vkCreateSemaphore(created, &semaphoreInfo, nil, &imageAvailable[frame]), .synchronization)
                var fenceInfo = VkFenceCreateInfo()
                fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
                fenceInfo.flags = VkFenceCreateFlags(VK_FENCE_CREATE_SIGNALED_BIT.rawValue)
                try check(vkCreateFence(created, &fenceInfo, nil, &inFlight[frame]), .synchronization)
            }

            vertexShader = try makeShader(CajuVulkanTriangleShaders.vertex)
            fragmentShader = try makeShader(CajuVulkanTriangleShaders.fragment)

            var range = VkPushConstantRange(
                stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue), offset: 0, size: 8)
            var layoutInfo = VkPipelineLayoutCreateInfo()
            layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
            layoutInfo.pushConstantRangeCount = 1
            layoutInfo.pPushConstantRanges = withUnsafePointer(to: &range) { $0 }
            try check(vkCreatePipelineLayout(created, &layoutInfo, nil, &pipelineLayout), .pipelineLayout)
        }

        private func makeShader(_ words: [UInt32]) throws(CajuVulkanError) -> VkShaderModule? {
            var module: VkShaderModule?
            let result: VkResult = words.withUnsafeBufferPointer { words in
                var info = VkShaderModuleCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
                info.codeSize = words.count * MemoryLayout<UInt32>.size
                info.pCode = words.baseAddress
                return vkCreateShaderModule(device, &info, nil, &module)
            }
            try check(result, .shaderModule)
            return module
        }

        // MARK: Swapchain

        private func recreateSwapchain() throws(CajuVulkanError) {
            if let device { vkDeviceWaitIdle(device) }
            destroySwapchainObjects()
            try createSwapchainObjects()
        }

        private func createSwapchainObjects() throws(CajuVulkanError) {
            var capabilities = VkSurfaceCapabilitiesKHR()
            try check(
                vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &capabilities), .swapchain)
            let size = CajuVulkanSwapchainPlan.extent(
                current: .init(
                    width: capabilities.currentExtent.width, height: capabilities.currentExtent.height),
                minimum: .init(
                    width: capabilities.minImageExtent.width, height: capabilities.minImageExtent.height),
                maximum: .init(
                    width: capabilities.maxImageExtent.width, height: capabilities.maxImageExtent.height),
                fallback: .init(width: 1, height: 1))
            guard !size.isEmpty else { return }  // minimizada: tenta de novo no próximo resize
            extent = VkExtent2D(width: size.width, height: size.height)

            var formatCount: UInt32 = 0
            try check(
                vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, nil), .swapchain)
            var formats = [VkSurfaceFormatKHR](repeating: VkSurfaceFormatKHR(), count: Int(formatCount))
            try check(
                vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, &formats),
                .swapchain)
            guard
                let format = CajuVulkanSwapchainPlan.chooseFormat(
                    formats.map { .init(format: $0.format.rawValue, colorSpace: $0.colorSpace.rawValue) })
            else { throw .noSurfaceFormat }
            swapchainFormat = VkFormat(rawValue: format.format)

            var info = VkSwapchainCreateInfoKHR()
            info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
            info.surface = surface
            info.minImageCount = CajuVulkanSwapchainPlan.imageCount(
                min: capabilities.minImageCount, max: capabilities.maxImageCount)
            info.imageFormat = swapchainFormat
            info.imageColorSpace = VkColorSpaceKHR(rawValue: format.colorSpace)
            info.imageExtent = extent
            info.imageArrayLayers = 1
            info.imageUsage = VkImageUsageFlags(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue)
            info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
            info.preTransform = capabilities.currentTransform
            let opaque = VkCompositeAlphaFlagsKHR(VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR.rawValue)
            info.compositeAlpha =
                capabilities.supportedCompositeAlpha & opaque != 0
                ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
            info.presentMode = VK_PRESENT_MODE_FIFO_KHR  // garantido pela especificação
            info.clipped = VkBool32(VK_TRUE)
            try check(vkCreateSwapchainKHR(device, &info, nil, &swapchain), .swapchain)

            var imageCount: UInt32 = 0
            try check(vkGetSwapchainImagesKHR(device, swapchain, &imageCount, nil), .swapchain)
            images = [VkImage?](repeating: nil, count: Int(imageCount))
            try check(vkGetSwapchainImagesKHR(device, swapchain, &imageCount, &images), .swapchain)

            try createRenderPass()
            try createPipeline()

            imageViews = [VkImageView?](repeating: nil, count: images.count)
            framebuffers = [VkFramebuffer?](repeating: nil, count: images.count)
            renderFinished = [VkSemaphore?](repeating: nil, count: images.count)
            for index in images.indices {
                var viewInfo = VkImageViewCreateInfo()
                viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
                viewInfo.image = images[index]
                viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
                viewInfo.format = swapchainFormat
                viewInfo.subresourceRange = VkImageSubresourceRange(
                    aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                    baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
                try check(vkCreateImageView(device, &viewInfo, nil, &imageViews[index]), .imageViews)

                var attachment = imageViews[index]
                var framebufferInfo = VkFramebufferCreateInfo()
                framebufferInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
                framebufferInfo.renderPass = renderPass
                framebufferInfo.attachmentCount = 1
                framebufferInfo.pAttachments = withUnsafePointer(to: &attachment) { $0 }
                framebufferInfo.width = extent.width
                framebufferInfo.height = extent.height
                framebufferInfo.layers = 1
                try check(
                    vkCreateFramebuffer(device, &framebufferInfo, nil, &framebuffers[index]), .framebuffer)

                var semaphoreInfo = VkSemaphoreCreateInfo()
                semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
                try check(
                    vkCreateSemaphore(device, &semaphoreInfo, nil, &renderFinished[index]), .synchronization)
            }
        }

        private func createRenderPass() throws(CajuVulkanError) {
            var color = VkAttachmentDescription()
            color.format = swapchainFormat
            color.samples = VK_SAMPLE_COUNT_1_BIT
            color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
            color.storeOp = VK_ATTACHMENT_STORE_OP_STORE
            color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
            color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
            color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
            color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR

            var reference = VkAttachmentReference(
                attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
            var subpass = VkSubpassDescription()
            subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
            subpass.colorAttachmentCount = 1
            subpass.pColorAttachments = withUnsafePointer(to: &reference) { $0 }

            var dependency = VkSubpassDependency()
            dependency.srcSubpass = UInt32.max  // VK_SUBPASS_EXTERNAL
            dependency.dstSubpass = 0
            dependency.srcStageMask = VkPipelineStageFlags(
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            dependency.dstStageMask = VkPipelineStageFlags(
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            dependency.dstAccessMask = VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)

            var info = VkRenderPassCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
            info.attachmentCount = 1
            info.pAttachments = withUnsafePointer(to: &color) { $0 }
            info.subpassCount = 1
            info.pSubpasses = withUnsafePointer(to: &subpass) { $0 }
            info.dependencyCount = 1
            info.pDependencies = withUnsafePointer(to: &dependency) { $0 }
            try check(vkCreateRenderPass(device, &info, nil, &renderPass), .renderPass)
        }

        private func createPipeline() throws(CajuVulkanError) {
            var stages = [VkPipelineShaderStageCreateInfo](
                repeating: VkPipelineShaderStageCreateInfo(), count: 2)
            stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT
            stages[0].module = vertexShader
            stages[0].pName = cString("main")
            stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT
            stages[1].module = fragmentShader
            stages[1].pName = cString("main")

            var vertexInput = VkPipelineVertexInputStateCreateInfo()
            vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
            var assembly = VkPipelineInputAssemblyStateCreateInfo()
            assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
            assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
            var viewportState = VkPipelineViewportStateCreateInfo()
            viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
            viewportState.viewportCount = 1
            viewportState.scissorCount = 1
            var raster = VkPipelineRasterizationStateCreateInfo()
            raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
            raster.polygonMode = VK_POLYGON_MODE_FILL
            raster.cullMode = VkCullModeFlags(VK_CULL_MODE_NONE.rawValue)
            raster.frontFace = VK_FRONT_FACE_CLOCKWISE
            raster.lineWidth = 1
            var multisample = VkPipelineMultisampleStateCreateInfo()
            multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
            multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
            var blendAttachment = VkPipelineColorBlendAttachmentState()
            blendAttachment.colorWriteMask = VkColorComponentFlags(
                VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue
                    | VK_COLOR_COMPONENT_B_BIT.rawValue | VK_COLOR_COMPONENT_A_BIT.rawValue)
            var blend = VkPipelineColorBlendStateCreateInfo()
            blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
            blend.attachmentCount = 1
            blend.pAttachments = withUnsafePointer(to: &blendAttachment) { $0 }
            var dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
            var dynamic = VkPipelineDynamicStateCreateInfo()
            dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
            dynamic.dynamicStateCount = 2
            dynamic.pDynamicStates = dynamicStates.withUnsafeMutableBufferPointer {
                UnsafePointer($0.baseAddress)
            }

            let result: VkResult = stages.withUnsafeBufferPointer { stages in
                var info = VkGraphicsPipelineCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                info.stageCount = 2
                info.pStages = stages.baseAddress
                info.pVertexInputState = withUnsafePointer(to: &vertexInput) { $0 }
                info.pInputAssemblyState = withUnsafePointer(to: &assembly) { $0 }
                info.pViewportState = withUnsafePointer(to: &viewportState) { $0 }
                info.pRasterizationState = withUnsafePointer(to: &raster) { $0 }
                info.pMultisampleState = withUnsafePointer(to: &multisample) { $0 }
                info.pColorBlendState = withUnsafePointer(to: &blend) { $0 }
                info.pDynamicState = withUnsafePointer(to: &dynamic) { $0 }
                info.layout = pipelineLayout
                info.renderPass = renderPass
                info.subpass = 0
                return vkCreateGraphicsPipelines(device, nil, 1, &info, nil, &pipeline)
            }
            try check(result, .pipeline)
        }

        // MARK: Destruição

        private func destroySwapchainObjects() {
            guard let device else { return }
            for semaphore in renderFinished { vkDestroySemaphore(device, semaphore, nil) }
            for framebuffer in framebuffers { vkDestroyFramebuffer(device, framebuffer, nil) }
            for view in imageViews { vkDestroyImageView(device, view, nil) }
            renderFinished = []
            framebuffers = []
            imageViews = []
            images = []
            if let pipeline { vkDestroyPipeline(device, pipeline, nil) }
            if let renderPass { vkDestroyRenderPass(device, renderPass, nil) }
            if let swapchain { vkDestroySwapchainKHR(device, swapchain, nil) }
            pipeline = nil
            renderPass = nil
            swapchain = nil
        }

        private func destroySurface() {
            if let surface, let instance { vkDestroySurfaceKHR(instance, surface, nil) }
            surface = nil
        }

        private func destroyDeviceObjects() {
            guard let device else { return }
            for frame in 0..<Self.framesInFlight {
                vkDestroySemaphore(device, imageAvailable[frame], nil)
                vkDestroyFence(device, inFlight[frame], nil)
            }
            if let pipelineLayout { vkDestroyPipelineLayout(device, pipelineLayout, nil) }
            if let vertexShader { vkDestroyShaderModule(device, vertexShader, nil) }
            if let fragmentShader { vkDestroyShaderModule(device, fragmentShader, nil) }
            if let commandPool { vkDestroyCommandPool(device, commandPool, nil) }
        }
    }
#endif
