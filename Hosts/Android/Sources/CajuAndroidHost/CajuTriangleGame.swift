#if os(Android)
    import Android
    import CajuPlatform
    import CajuRHI
    import CajuRHIVulkan

    /// Jogo mínimo do host Android: um triângulo girando, desenhado pelo `CajuRHI` (backend Vulkan) na Game
    /// Thread. Exercita o ciclo de vida da superfície: criação, rotação (recriação do *swapchain*), Home/volta
    /// (`releaseSurface` e `recreate` com a janela nova).
    struct CajuTriangleGame: CajuAndroidGameDelegate {
        private var device: CajuVulkanDevice?
        private var swapchain: CajuVulkanSwapchain?
        private var vertex = CajuShaderHandle.null
        private var fragment = CajuShaderHandle.null
        private var pipeline = CajuRenderPipelineHandle.null
        private var pipelineFormat: CajuPixelFormat?
        private var window: CajuNativeWindow?
        private var needsRecreate = false
        private var failed = false
        private var frames = 0
        private var cycles = 0
        private var start = timespec()

        init() {
            clock_gettime(CLOCK_MONOTONIC, &start)
            do {
                #if DEBUG
                    let validation = true
                #else
                    let validation = false
                #endif
                let device = try CajuVulkanDevice(enableSurface: true, enableValidation: validation)
                vertex = try device.createShaderModule(
                    CajuShaderModuleDescriptor(format: .spirv, code: Self.bytes(TriangleShaders.vertex)))
                fragment = try device.createShaderModule(
                    CajuShaderModuleDescriptor(format: .spirv, code: Self.bytes(TriangleShaders.fragment)))
                self.device = device
                cajuLog(
                    "dispositivo: \(device.capabilities.deviceName) validação=\(device.validationEnabled)")
            } catch {
                cajuLog("falha ao criar o dispositivo: \(error)")
                failed = true
            }
        }

        private static func bytes(_ words: [UInt32]) -> [UInt8] { words.withUnsafeBytes { [UInt8]($0) } }

        private func descriptor(_ window: CajuNativeWindow) -> CajuSurfaceDescriptor {
            CajuSurfaceDescriptor(
                kind: .androidNativeWindow, nativeHandle: UInt(bitPattern: window.raw), pixelWidth: 1,
                pixelHeight: 1)
        }

        mutating func surfaceCreated(_ window: CajuNativeWindow) {
            guard let device else { return }
            self.window = window
            do {
                if let swapchain {
                    try swapchain.recreate(descriptor(window))
                } else {
                    swapchain = try device.createSwapchain(descriptor(window))
                }
                failed = false
                try makePipelineIfNeeded()
                logSurface("superfície criada")
            } catch {
                cajuLog("falha ao criar o swapchain: \(error)")
                failed = true
            }
        }

        mutating func surfaceResized() { needsRecreate = true }

        mutating func surfaceDestroyed() {
            swapchain?.releaseSurface()
            window = nil
            cycles += 1
            if let device {
                cajuLog(
                    "superfície destruída (ciclo \(cycles)): recursos vivos=\(device.liveResourceCount) "
                        + "pendentes=\(device.pendingDestructionCount) bytesVMA=\(device.allocatedBytes) "
                        + "validação erros=\(device.validationMessageCounts.errors) "
                        + "avisos=\(device.validationMessageCounts.warnings)")
            }
        }

        mutating func activeChanged(_ active: Bool) { cajuLog(active ? "ativo" : "inativo") }

        private mutating func makePipelineIfNeeded() throws(CajuRHIError) {
            guard let device, let swapchain, pipelineFormat != swapchain.format else { return }
            if pipeline.isNonNull { device.destroy(pipeline) }
            pipeline = try device.createRenderPipeline(
                CajuRenderPipelineDescriptor(
                    vertex: CajuShaderFunction(module: vertex, entryPoint: "main"),
                    fragment: CajuShaderFunction(module: fragment, entryPoint: "main"),
                    colorTargets: [CajuColorTargetState(format: swapchain.format)], cullMode: .none))
            pipelineFormat = swapchain.format
        }

        private func logSurface(_ what: String) {
            guard let swapchain else { return }
            cajuLog(
                "\(what): \(swapchain.pixelWidth)x\(swapchain.pixelHeight) \(swapchain.format) "
                    + "rotação do compositor=\(swapchain.compositorRotation)°")
        }

        private mutating func recreate() throws(CajuRHIError) {
            guard let swapchain, let window else { return }
            try swapchain.recreate(descriptor(window))
            try makePipelineIfNeeded()
        }

        mutating func drawFrame() {
            guard !failed, let device, let swapchain, window != nil else { return }
            do {
                if needsRecreate {
                    needsRecreate = false
                    try recreate()
                }
                let image: CajuSwapchainImage
                do { image = try swapchain.acquireNextImage() } catch .surfaceOutOfDate {
                    try recreate()
                    return
                } catch .surfaceLost { return }
                var now = timespec()
                clock_gettime(CLOCK_MONOTONIC, &now)
                let seconds = Float(now.tv_sec - start.tv_sec) + Float(now.tv_nsec - start.tv_nsec) * 1e-9
                var params: (Float, Float) = (
                    seconds * 1.2, Float(swapchain.pixelWidth) / Float(max(swapchain.pixelHeight, 1))
                )
                let pipeline = self.pipeline
                var commands = try device.queue.makeCommandBuffer(label: "quadro")
                try commands.withRenderPass(
                    CajuRenderPassDescriptor(colorAttachments: [
                        CajuColorAttachment(
                            texture: .texture(image.texture), load: .clear(SIMD4(0.04, 0.05, 0.09, 1)),
                            store: .store)
                    ])
                ) { encoder in
                    encoder.setPipeline(pipeline)
                    withUnsafeBytes(of: &params) { encoder.setBytes($0, index: 0, stage: .vertex) }
                    encoder.draw(vertexCount: 3)
                }
                try commands.present(image)
                try device.queue.submit(commands)
                frames += 1
                if frames % 600 == 0 {
                    cajuLog(
                        "quadros=\(frames) recursos vivos=\(device.liveResourceCount) bytesVMA=\(device.allocatedBytes) "
                            + "validação erros=\(device.validationMessageCounts.errors)")
                }
            } catch {
                cajuLog("falha no quadro: \(error)")
                failed = true
            }
        }

        mutating func touch(_ event: CajuTouchEvent) {
            guard event.phase == .began else { return }
            cajuLog("toque em (\(event.x), \(event.y))")
            // DIAGNÓSTICO TEMPORÁRIO: 100 recriações do swapchain e RSS antes/depois.
            let before = Self.residentKB()
            for _ in 0..<100 { try? recreate() }
            cajuLog("100 recriações: RSS \(before) → \(Self.residentKB()) kB")
        }

        static func residentKB() -> Int {
            guard let file = fopen("/proc/self/statm", "r") else { return -1 }
            defer { fclose(file) }
            var size = 0
            var resident = 0
            _ = withUnsafeMutablePointer(to: &size) { s in
                withUnsafeMutablePointer(to: &resident) { r in
                    withVaList([s, r]) { vfscanf(file, "%ld %ld", $0) }
                }
            }
            return resident * 4
        }
    }

    /// Ponto de entrada da `NativeActivity` (`android.app.lib_name = CajuAndroidHost`).
    @_cdecl("ANativeActivity_onCreate")
    public func cajuANativeActivityOnCreate(
        _ activity: UnsafeMutableRawPointer,
        _ savedState: UnsafeMutableRawPointer?,
        _ savedStateSize: Int
    ) {
        CajuAndroidActivity.onCreate(activity: activity) { channel in
            var game = CajuTriangleGame()
            CajuAndroidGameLoop.run(channel: channel, delegate: &game)
        }
    }
#endif
