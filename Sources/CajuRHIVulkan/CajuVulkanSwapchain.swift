#if os(Android)
    import CajuRHI

    /// *Swapchain* Vulkan (fatia E da V-1): hoje só existe para o contrato compilar.
    public final class CajuVulkanSwapchain: CajuSwapchain {
        public let format: CajuPixelFormat = .bgra8UnormSRGB
        public let pixelWidth = 0
        public let pixelHeight = 0

        public func acquireNextImage() throws(CajuRHIError) -> CajuSwapchainImage {
            throw .surfaceLost
        }

        public func recreate(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError) {
            throw .backend(code: cajuVulkanNotImplementedCode)
        }

        public func releaseSurface() {}
    }
#endif
