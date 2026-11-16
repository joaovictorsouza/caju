#if os(Android)
    import CVulkan
    import CajuRHI

    /// *Swapchain* Vulkan sobre uma `ANativeWindow` (ADR 0024).
    ///
    /// - 2 quadros em voo: um semáforo de aquisição por quadro (reusado só depois da *fence* da submissão que
    ///   esperou por ele) e um semáforo de fim de render por imagem.
    /// - `preTransform = IDENTITY` na v1: o compositor gira a imagem. O tamanho segue a orientação lógica
    ///   (o Android informa `currentExtent` na orientação nativa e por isso ele é trocado em 90°/270°), e o
    ///   `SUBOPTIMAL` que o Android devolve quando a rotação difere é esperado e ignorado.
    /// - `OUT_OF_DATE` na aquisição vira `.surfaceOutOfDate`; na apresentação, marca a cadeia para a próxima
    ///   aquisição falhar com o mesmo erro. O chamador chama `recreate` com o descritor novo.
    /// - `releaseSurface` (ir para segundo plano) solta superfície, cadeia e imagens; os recursos do
    ///   dispositivo sobrevivem.
    public final class CajuVulkanSwapchain: CajuSwapchain {
        static let framesInFlight = 2

        public private(set) var format: CajuPixelFormat = .bgra8UnormSRGB
        public private(set) var pixelWidth = 0
        public private(set) var pixelHeight = 0
        /// Rotação que o compositor aplica (graus: 0, 90, 180, 270), para diagnóstico e evidências.
        public private(set) var compositorRotation = 0

        private unowned let device: CajuVulkanDevice
        private var context: CajuVulkanContext { device.context }
        private var window: UInt = 0
        private var surface: VkSurfaceKHR?
        private var swapchain: VkSwapchainKHR?
        private var images: [CajuTextureHandle] = []
        private var renderFinished: [VkSemaphore] = []
        private var imageAvailable: [VkSemaphore] = []
        private var slotSerial = [UInt64](repeating: 0, count: framesInFlight)
        private var slot = 0
        private var outOfDate = false

        init(device: CajuVulkanDevice, surface descriptor: CajuSurfaceDescriptor) throws(CajuRHIError) {
            self.device = device
            guard device.context.surfaceEnabled else {
                throw .unsupported(.presentMode(descriptor.presentMode))
            }
            for _ in 0..<Self.framesInFlight { imageAvailable.append(try makeSemaphore()) }
            try recreate(descriptor)
        }

        deinit {
            releaseSurface()
            for semaphore in imageAvailable { vkDestroySemaphore(context.device, semaphore, nil) }
        }

        // MARK: Contrato

        public func acquireNextImage() throws(CajuRHIError) -> CajuSwapchainImage {
            guard let swapchain else { throw .surfaceLost }
            guard !outOfDate else { throw .surfaceOutOfDate }
            // O semáforo deste quadro foi esperado pela submissão de 2 quadros atrás: espera ela terminar.
            try context.wait(for: slotSerial[slot])
            var index: UInt32 = 0
            let result = vkAcquireNextImageKHR(
                context.device, swapchain, UInt64.max, imageAvailable[slot], nil, &index)
            switch result {
            case VK_SUCCESS, VK_SUBOPTIMAL_KHR: break
            case VK_ERROR_OUT_OF_DATE_KHR:
                outOfDate = true
                throw .surfaceOutOfDate
            default: throw mapVkResult(result)
            }
            let texture = images[Int(index)]
            // A imagem voltou do compositor: o conteúdo anterior não importa.
            if let record = device.textures.value(for: texture) { record.layout = VK_IMAGE_LAYOUT_UNDEFINED }
            return CajuSwapchainImage(
                texture: texture, width: pixelWidth, height: pixelHeight, format: format,
                imageIndex: Int(index) << 8 | slot)
        }

        public func recreate(_ descriptor: CajuSurfaceDescriptor) throws(CajuRHIError) {
            guard descriptor.kind == .androidNativeWindow, descriptor.nativeHandle != 0 else {
                throw .surfaceLost
            }
            try context.waitIdle()
            device.collectGarbage()
            if descriptor.nativeHandle != window || surface == nil {
                releaseSurface()
                try createSurface(descriptor.nativeHandle)
            }
            try createSwapchain(descriptor)
        }

        public func releaseSurface() {
            try? context.waitIdle()
            destroyImages()
            device.collectGarbage(force: true)  // as views das imagens saem antes da cadeia
            if let swapchain { vkDestroySwapchainKHR(context.device, swapchain, nil) }
            swapchain = nil
            if let surface { vkDestroySurfaceKHR(context.instance, surface, nil) }
            surface = nil
            window = 0
        }

        // MARK: Apresentação (chamado pela fila)

        /// Semáforos da submissão que desenha na imagem `image` (`imageIndex` do `CajuSwapchainImage`).
        func semaphores(for image: Int) -> (wait: VkSemaphore, signal: VkSemaphore)? {
            let index = image >> 8
            let frame = image & 0xFF
            guard index < renderFinished.count, frame < imageAvailable.count else { return nil }
            return (imageAvailable[frame], renderFinished[index])
        }

        /// Depois de `vkQueueSubmit`: apresenta e avança o quadro em voo.
        func present(image: Int, serial: UInt64) throws(CajuRHIError) {
            guard swapchain != nil, let semaphores = semaphores(for: image) else { throw .surfaceLost }
            slotSerial[image & 0xFF] = serial
            slot = (slot + 1) % Self.framesInFlight
            var chain: VkSwapchainKHR? = swapchain
            var wait: VkSemaphore? = semaphores.signal
            var index = UInt32(image >> 8)
            let result: VkResult = withUnsafePointer(to: &wait) { wait in
                withUnsafePointer(to: &chain) { chain in
                    withUnsafePointer(to: &index) { index in
                        var info = VkPresentInfoKHR()
                        info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
                        info.waitSemaphoreCount = 1
                        info.pWaitSemaphores = wait
                        info.swapchainCount = 1
                        info.pSwapchains = chain
                        info.pImageIndices = index
                        return vkQueuePresentKHR(context.queue, &info)
                    }
                }
            }
            switch result {
            case VK_SUCCESS, VK_SUBOPTIMAL_KHR: break
            case VK_ERROR_OUT_OF_DATE_KHR: outOfDate = true
            default: throw mapVkResult(result)
            }
        }

        // MARK: Criação

        private func makeSemaphore() throws(CajuRHIError) -> VkSemaphore {
            var info = VkSemaphoreCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
            var semaphore: VkSemaphore?
            try vkCheck(vkCreateSemaphore(context.device, &info, nil, &semaphore))
            guard let semaphore else { throw .outOfMemory }
            return semaphore
        }

        private func createSurface(_ handle: UInt) throws(CajuRHIError) {
            guard let pointer = OpaquePointer(bitPattern: handle) else { throw .surfaceLost }
            var info = VkAndroidSurfaceCreateInfoKHR()
            info.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR
            info.window = pointer
            var created: VkSurfaceKHR?
            try vkCheck(vkCreateAndroidSurfaceKHR(context.instance, &info, nil, &created))
            guard let created else { throw .surfaceLost }
            var supported: VkBool32 = 0
            vkGetPhysicalDeviceSurfaceSupportKHR(
                context.physicalDevice, context.queueFamily, created, &supported)
            guard supported != 0 else {
                vkDestroySurfaceKHR(context.instance, created, nil)
                throw .unsupported(.presentMode(.fifo))
            }
            surface = created
            window = handle
        }

        private func destroyImages() {
            for handle in images { device.destroy(handle) }
            images.removeAll()
            for semaphore in renderFinished { vkDestroySemaphore(context.device, semaphore, nil) }
            renderFinished.removeAll()
        }

        private func createSwapchain(_ descriptor: CajuSurfaceDescriptor) throws(CajuRHIError) {
            guard let surface else { throw .surfaceLost }
            var caps = VkSurfaceCapabilitiesKHR()
            try vkCheck(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(context.physicalDevice, surface, &caps))
            let rotation = Self.rotation(caps.currentTransform)
            // Sem pré-rotação, a imagem tem o tamanho lógico da janela. `currentExtent` vem na orientação nativa
            // e, logo depois de girar, às vezes ainda com a orientação anterior; a janela é a fonte confiável.
            var current = CajuVulkanSwapchainPlan.Extent(
                width: caps.currentExtent.width, height: caps.currentExtent.height)
            if let native = OpaquePointer(bitPattern: window) {
                let width = ANativeWindow_getWidth(native)
                let height = ANativeWindow_getHeight(native)
                if width > 0, height > 0 { current = .init(width: UInt32(width), height: UInt32(height)) }
            } else if rotation == 90 || rotation == 270,
                current.width != CajuVulkanSwapchainPlan.undefinedExtent
            {
                swap(&current.width, &current.height)
            }
            let size = CajuVulkanSwapchainPlan.extent(
                current: current,
                minimum: .init(width: caps.minImageExtent.width, height: caps.minImageExtent.height),
                maximum: .init(
                    width: max(caps.maxImageExtent.width, caps.maxImageExtent.height),
                    height: max(caps.maxImageExtent.width, caps.maxImageExtent.height)),
                fallback: .init(
                    width: UInt32(clamping: descriptor.pixelWidth),
                    height: UInt32(clamping: descriptor.pixelHeight)))
            guard !size.isEmpty else { throw .surfaceOutOfDate }

            var formatCount: UInt32 = 0
            try vkCheck(
                vkGetPhysicalDeviceSurfaceFormatsKHR(context.physicalDevice, surface, &formatCount, nil))
            var formats = [VkSurfaceFormatKHR](repeating: VkSurfaceFormatKHR(), count: Int(formatCount))
            try vkCheck(
                vkGetPhysicalDeviceSurfaceFormatsKHR(context.physicalDevice, surface, &formatCount, &formats))
            let wanted = descriptor.preferredFormat.vulkan.rawValue
            let chosen =
                formats.first { $0.format.rawValue == wanted }.map {
                    CajuVulkanSwapchainPlan.SurfaceFormat(
                        format: $0.format.rawValue, colorSpace: $0.colorSpace.rawValue)
                }
                ?? CajuVulkanSwapchainPlan.chooseFormat(
                    formats.map { .init(format: $0.format.rawValue, colorSpace: $0.colorSpace.rawValue) })
            guard let chosen, let pixelFormat = CajuPixelFormat(vulkanSwapchainFormat: chosen.format) else {
                throw .unsupported(.pixelFormat(descriptor.preferredFormat))
            }

            var info = VkSwapchainCreateInfoKHR()
            info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
            info.surface = surface
            info.minImageCount = CajuVulkanSwapchainPlan.imageCount(
                min: caps.minImageCount, max: caps.maxImageCount)
            info.imageFormat = VkFormat(chosen.format)
            info.imageColorSpace = VkColorSpaceKHR(chosen.colorSpace)
            info.imageExtent = VkExtent2D(width: size.width, height: size.height)
            info.imageArrayLayers = 1
            info.imageUsage = VkImageUsageFlags(
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue)
            info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
            info.preTransform =
                caps.supportedTransforms
                    & VkSurfaceTransformFlagsKHR(VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR.rawValue)
                    != 0 ? VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR : caps.currentTransform
            let opaque = VkCompositeAlphaFlagsKHR(VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR.rawValue)
            info.compositeAlpha =
                caps.supportedCompositeAlpha & opaque != 0
                ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
            info.presentMode = VK_PRESENT_MODE_FIFO_KHR  // garantido pela especificação
            info.clipped = VkBool32(VK_TRUE)
            info.oldSwapchain = swapchain
            var created: VkSwapchainKHR?
            let result = vkCreateSwapchainKHR(context.device, &info, nil, &created)
            // A cadeia antiga sai de cena de qualquer jeito (o driver já a aposentou com `oldSwapchain`).
            destroyImages()
            device.collectGarbage(force: true)
            if let old = swapchain { vkDestroySwapchainKHR(context.device, old, nil) }
            swapchain = nil
            try vkCheck(result)
            guard let created else { throw .outOfMemory }
            swapchain = created

            var count: UInt32 = 0
            try vkCheck(vkGetSwapchainImagesKHR(context.device, created, &count, nil))
            var nativeImages = [VkImage?](repeating: nil, count: Int(count))
            try vkCheck(vkGetSwapchainImagesKHR(context.device, created, &count, &nativeImages))
            let textureDescriptor = CajuTextureDescriptor(
                format: pixelFormat, width: Int(size.width), height: Int(size.height),
                usage: [.renderTarget, .copyDestination], label: "swapchain")
            for case let image? in nativeImages {
                images.append(
                    try device.registerSwapchainImage(image, descriptor: textureDescriptor, owner: self))
                renderFinished.append(try makeSemaphore())
            }
            format = pixelFormat
            pixelWidth = Int(size.width)
            pixelHeight = Int(size.height)
            compositorRotation = rotation
            outOfDate = false
            slot = 0
        }

        private static func rotation(_ transform: VkSurfaceTransformFlagBitsKHR) -> Int {
            switch transform {
            case VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR: 90
            case VK_SURFACE_TRANSFORM_ROTATE_180_BIT_KHR: 180
            case VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR: 270
            default: 0
            }
        }
    }

    extension CajuPixelFormat {
        /// Formatos de *swapchain* que o contrato entende.
        init?(vulkanSwapchainFormat raw: UInt32) {
            switch VkFormat(raw) {
            case VK_FORMAT_B8G8R8A8_SRGB: self = .bgra8UnormSRGB
            case VK_FORMAT_B8G8R8A8_UNORM: self = .bgra8Unorm
            case VK_FORMAT_R8G8B8A8_SRGB: self = .rgba8UnormSRGB
            case VK_FORMAT_R8G8B8A8_UNORM: self = .rgba8Unorm
            case VK_FORMAT_A2B10G10R10_UNORM_PACK32: self = .rgb10a2Unorm
            default: return nil
            }
        }
    }

    extension CajuVulkanDevice {
        /// Registra uma imagem do *swapchain* como textura do RHI (o *swapchain* é o dono da imagem).
        func registerSwapchainImage(
            _ image: VkImage, descriptor: CajuTextureDescriptor, owner: CajuVulkanSwapchain
        ) throws(CajuRHIError)
            -> CajuTextureHandle
        {
            var info = VkImageViewCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
            info.image = image
            info.viewType = VK_IMAGE_VIEW_TYPE_2D
            info.format = descriptor.format.vulkan
            info.subresourceRange = VkImageSubresourceRange(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0, layerCount: 1)
            var view: VkImageView?
            try vkCheck(vkCreateImageView(context.device, &info, nil, &view))
            guard let view else { throw .outOfMemory }
            let texture = VulkanTexture(
                image: image, view: view, allocation: nil, descriptor: descriptor, layers: 1, ownsImage: false
            )
            texture.swapchain = owner
            return insertTexture(texture)
        }
    }
#endif
