#if canImport(Metal)
    import CajuRHI
    import Dispatch
    import Metal
    import QuartzCore

    /// Enpacota bytes em `DispatchData` (único uso de Dispatch: `makeLibrary(data:)`).
    enum DispatchDataBox {
        static func make(_ bytes: UnsafeRawBufferPointer) -> DispatchData { DispatchData(bytes: bytes) }
    }

    /// *Swapchain* sobre um `CAMetalLayer` fornecido pela plataforma (`nativeHandle` = endereço do layer).
    public final class CajuMetalSwapchain: CajuSwapchain {
        unowned let device: CajuMetalDevice
        private var layer: CAMetalLayer?
        public private(set) var format: CajuPixelFormat = .bgra8UnormSRGB
        public private(set) var pixelWidth = 0
        public private(set) var pixelHeight = 0
        private var frameIndex = 0
        /// Quantas vezes a superfície foi (re)criada (diagnóstico de ciclo de vida).
        public private(set) var recreateCount = 0

        init(device: CajuMetalDevice) { self.device = device }

        public func acquireNextImage() throws(CajuRHIError) -> CajuSwapchainImage {
            guard let layer else { throw .surfaceLost }
            guard Int(layer.drawableSize.width) == pixelWidth, Int(layer.drawableSize.height) == pixelHeight
            else {
                throw .surfaceOutOfDate
            }
            guard let drawable = layer.nextDrawable() else { throw .surfaceLost }
            let texture = drawable.texture
            let handle = device.textures.insert(
                MetalTexture(
                    texture: texture,
                    descriptor: CajuTextureDescriptor(
                        format: format, width: pixelWidth, height: pixelHeight, usage: .renderTarget,
                        label: "drawable"),
                    drawable: drawable))
            let index = frameIndex % 3
            frameIndex += 1
            return CajuSwapchainImage(
                texture: handle, width: pixelWidth, height: pixelHeight, format: format, imageIndex: index)
        }

        public func recreate(_ surface: CajuSurfaceDescriptor) throws(CajuRHIError) {
            guard surface.kind == .metalLayer,
                let pointer = UnsafeRawPointer(bitPattern: surface.nativeHandle)
            else { throw .unsupported(.presentMode(surface.presentMode)) }
            guard surface.pixelWidth > 0, surface.pixelHeight > 0 else { throw .invalidDescriptor(.zeroSize) }
            switch surface.preferredFormat {
            case .bgra8Unorm, .bgra8UnormSRGB, .rgba16Float, .rgb10a2Unorm: break
            default: throw .unsupported(.pixelFormat(surface.preferredFormat))
            }
            guard device.capabilities.presentModes.contains(surface.presentMode) else {
                throw .unsupported(.presentMode(surface.presentMode))
            }
            let layer = Unmanaged<CAMetalLayer>.fromOpaque(pointer).takeUnretainedValue()
            layer.device = device.mtlDevice
            layer.pixelFormat = surface.preferredFormat.metal
            layer.framebufferOnly = true
            layer.drawableSize = CGSize(width: surface.pixelWidth, height: surface.pixelHeight)
            layer.maximumDrawableCount = 3
            #if os(macOS)
                layer.displaySyncEnabled = surface.presentMode == .fifo
            #endif
            self.layer = layer
            format = surface.preferredFormat
            pixelWidth = surface.pixelWidth
            pixelHeight = surface.pixelHeight
            recreateCount += 1
        }

        public func releaseSurface() {
            layer = nil
        }
    }
#endif
