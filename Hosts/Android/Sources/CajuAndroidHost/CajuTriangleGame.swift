#if os(Android)
    import CajuPlatform
    import CajuRHIVulkan

    /// Jogo mínimo do TB-Android: um triângulo girando, na Game Thread.
    struct CajuTriangleGame: CajuAndroidGameDelegate {
        private var renderer: CajuVulkanTriangleRenderer?
        private var failed = false

        init() {
            do {
                renderer = try CajuVulkanTriangleRenderer()
            } catch {
                cajuLog("falha ao criar o renderer: \(error)")
                failed = true
            }
        }

        mutating func surfaceCreated(_ window: CajuNativeWindow) {
            do {
                try renderer?.attach(window: window.raw)
                failed = false
                cajuLog("superfície criada")
            } catch {
                cajuLog("falha no attach: \(error)")
                failed = true
            }
        }

        mutating func surfaceResized() { renderer?.resize() }

        mutating func surfaceDestroyed() {
            renderer?.detach()
            cajuLog("superfície destruída")
        }

        mutating func activeChanged(_ active: Bool) { cajuLog(active ? "ativo" : "inativo") }

        mutating func drawFrame() {
            guard !failed else { return }
            do {
                try renderer?.drawFrame()
            } catch {
                cajuLog("falha no quadro: \(error)")
                failed = true
            }
        }

        mutating func touch(_ event: CajuTouchEvent) {
            if event.phase == .began { cajuLog("toque em (\(event.x), \(event.y))") }
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
