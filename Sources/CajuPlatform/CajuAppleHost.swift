#if canImport(UIKit) || canImport(AppKit)
    import Foundation
    import QuartzCore

    #if canImport(UIKit)
        import UIKit
        public typealias CajuNativeView = UIView
    #else
        import AppKit
        public typealias CajuNativeView = NSView
    #endif

    // Host Apple (iOS e macOS): `CAMetalLayer` numa view, laço por *display link* e ciclo de vida a partir
    // das notificações do sistema. Foundation e UIKit/AppKit só aqui, na borda (ADR 0005, ADR 0008).

    /// View com um `CAMetalLayer`; entrega o `CajuPlatformSurface` atual e avisa mudanças de tamanho.
    @MainActor
    public final class CajuMetalView: CajuNativeView {
        public let metalLayer = CAMetalLayer()
        /// Chamado quando tamanho, escala ou janela mudam.
        var onSurfaceChange: (() -> Void)?

        public override init(frame: CGRect) {
            super.init(frame: frame)
            #if canImport(UIKit)
                layer.addSublayer(metalLayer)
                isMultipleTouchEnabled = true
            #else
                wantsLayer = true
                layer?.addSublayer(metalLayer)
            #endif
            metalLayer.isOpaque = true
        }

        public required init?(coder: NSCoder) { return nil }

        private var scale: CGFloat {
            #if canImport(UIKit)
                return window?.screen.scale ?? traitCollection.displayScale
            #else
                return window?.backingScaleFactor ?? 2
            #endif
        }

        private var maximumFramesPerSecond: Int {
            #if canImport(UIKit)
                return window?.screen.maximumFramesPerSecond ?? 60
            #else
                return window?.screen?.maximumFramesPerSecond ?? 60
            #endif
        }

        /// Descrição da superfície em pixels; `nil` enquanto a view não tem tamanho.
        public func currentSurface() -> CajuPlatformSurface? {
            let s = scale
            let w = Int((bounds.width * s).rounded())
            let h = Int((bounds.height * s).rounded())
            guard w > 0, h > 0 else { return nil }
            let handle = UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())
            #if canImport(UIKit)
                let i = safeAreaInsets
                let inset = CajuEdgeInsets(
                    top: Float(i.top * s), left: Float(i.left * s), bottom: Float(i.bottom * s),
                    right: Float(i.right * s))
            #else
                let inset = CajuEdgeInsets.zero
            #endif
            return CajuPlatformSurface(
                kind: .metalLayer, nativeHandle: handle, pixelWidth: w, pixelHeight: h, scale: Float(s),
                safeArea: inset, maximumFramesPerSecond: maximumFramesPerSecond)
        }

        private func syncLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.frame = bounds
            metalLayer.contentsScale = scale
            CATransaction.commit()
            onSurfaceChange?()
        }

        #if canImport(UIKit)
            public override func layoutSubviews() {
                super.layoutSubviews()
                syncLayer()
            }
            public override func didMoveToWindow() {
                super.didMoveToWindow()
                syncLayer()
            }
        #else
            public override func layout() {
                super.layout()
                syncLayer()
            }
            public override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                syncLayer()
            }
            public override func viewDidChangeBackingProperties() {
                super.viewDidChangeBackingProperties()
                syncLayer()
            }
        #endif
    }

    /// Alvo Objective-C do *display link* (o `CADisplayLink` exige `NSObject`).
    @MainActor
    private final class DisplayLinkTarget: NSObject {
        var tick: ((CFTimeInterval) -> Void)?
        @objc func fire(_ link: CADisplayLink) { tick?(link.timestamp) }
    }

    /// Host de plataforma para iOS e macOS.
    ///
    /// Uso: crie o host, coloque `host.view` na hierarquia de views e chame `run(_:window:)`. O laço roda
    /// na thread principal (ADR 0008); `@preconcurrency` na conformância porque o protocolo é agnóstico de
    /// ator e aqui todos os métodos são da thread principal.
    @MainActor
    public final class CajuAppleHost: @preconcurrency CajuPlatformHost {
        public let view = CajuMetalView(frame: .zero)
        public var renderPolicy: CajuRenderPolicy = .continuous {
            didSet { applyPolicy?(renderPolicy) }
        }
        public private(set) var surface: CajuPlatformSurface?

        private var post: ((CajuPlatformEvent) -> Void)?
        private var tick: ((CajuTimestamp) -> Void)?
        private var applyPolicy: ((CajuRenderPolicy) -> Void)?
        private var redraw: (() -> Void)?
        private var displayLink: CADisplayLink?
        private let target = DisplayLinkTarget()
        private var observers: [any NSObjectProtocol] = []
        private var preferredFPS = 0
        private var isBackground = false

        public init() {}

        isolated deinit {
            displayLink?.invalidate()
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }

        public func requestRedraw() { redraw?() }

        public func setPreferredFramesPerSecond(_ fps: Int) {
            preferredFPS = fps
            guard let displayLink else { return }
            if fps > 0 {
                displayLink.preferredFrameRateRange = CAFrameRateRange(
                    minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
            } else {
                displayLink.preferredFrameRateRange = .default
            }
        }

        public func run<App: CajuApplication>(_ app: sending App, window: CajuWindowConfiguration) {
            let box = LoopBox(loop: CajuMainLoop(app: app, renderPolicy: renderPolicy))
            post = { box.loop.post($0) }
            tick = { box.loop.tick(at: $0) }
            applyPolicy = { box.loop.renderPolicy = $0 }
            redraw = { box.loop.requestRedraw() }

            view.onSurfaceChange = { [unowned self] in self.surfaceDidChange() }
            installObservers()
            installDisplayLink()
            post?(.lifecycle(.willEnterForeground))
            post?(.lifecycle(.didBecomeActive))
            surfaceDidChange()
        }

        // MARK: Superfície

        private func surfaceDidChange() {
            guard !isBackground, let new = view.currentSurface() else { return }
            if let old = surface, old == new { return }
            let existed = surface != nil
            surface = new
            post?(existed ? .surfaceChanged(new) : .surfaceCreated(new))
        }

        // MARK: Ciclo de vida

        private func send(_ e: CajuLifecycleEvent) { post?(.lifecycle(e)) }

        private func enterBackground() {
            guard !isBackground else { return }
            send(.didEnterBackground)
            if surface != nil {
                post?(.surfaceDestroyed)
                surface = nil
            }
            isBackground = true
            displayLink?.isPaused = true
        }

        private func enterForeground() {
            guard isBackground else { return }
            isBackground = false
            send(.willEnterForeground)
            displayLink?.isPaused = false
            surfaceDidChange()
        }

        private func installObservers() {
            let center = NotificationCenter.default
            func watch(_ name: Notification.Name, _ handler: @escaping @MainActor (CajuAppleHost) -> Void) {
                let token = center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { if let self { handler(self) } }
                }
                observers.append(token)
            }
            #if canImport(UIKit)
                watch(UIApplication.didBecomeActiveNotification) { $0.send(.didBecomeActive) }
                watch(UIApplication.willResignActiveNotification) { $0.send(.willResignActive) }
                watch(UIApplication.didEnterBackgroundNotification) { $0.enterBackground() }
                watch(UIApplication.willEnterForegroundNotification) { $0.enterForeground() }
                watch(UIApplication.didReceiveMemoryWarningNotification) { $0.send(.lowMemory) }
                watch(UIApplication.willTerminateNotification) { $0.send(.willTerminate) }
            #else
                watch(NSApplication.didBecomeActiveNotification) { $0.send(.didBecomeActive) }
                watch(NSApplication.willResignActiveNotification) { $0.send(.willResignActive) }
                watch(NSApplication.didHideNotification) { $0.enterBackground() }
                watch(NSApplication.willUnhideNotification) { $0.enterForeground() }
                watch(NSApplication.willTerminateNotification) { $0.send(.willTerminate) }
            #endif
        }

        private func installDisplayLink() {
            target.tick = { [unowned self] t in self.tick?(CajuTimestamp(seconds: t)) }
            #if canImport(UIKit)
                let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.fire(_:)))
            #else
                let link = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.fire(_:)))
            #endif
            link.add(to: .main, forMode: .common)
            displayLink = link
            setPreferredFramesPerSecond(preferredFPS)
        }

        /// Caixa de classe para o laço: os closures do host compartilham o mesmo `CajuMainLoop`.
        private final class LoopBox<App: CajuApplication> {
            var loop: CajuMainLoop<App>
            init(loop: CajuMainLoop<App>) { self.loop = loop }
        }
    }
#endif
