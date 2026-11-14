import CajuPlatform
import CajuRHI
import CajuRHIMetal
import SwiftUI

/// Estado compartilhado entre os toques do SwiftUI e o laço de render. Tudo roda na thread principal
/// (gestos do SwiftUI e *display link* do host), por isso `@unchecked Sendable`.
// SAFETY: acessado só pela thread principal.
final class CajuDemoState: @unchecked Sendable {
    var spinning = true
    var taps = 0
    var buttonRect = SIMD4<Float>(0, 0, 0, 0)
    var scale: Float = 1
    /// Contadores de diagnóstico lidos pelos testes de aparelho (ciclos de superfície).
    var surfaceCreated = 0
    var surfaceDestroyed = 0
    var frames = 0

    func tap(atPoint p: CGPoint) {
        let x = Float(p.x) * scale
        let y = Float(p.y) * scale
        if x >= buttonRect.x, x <= buttonRect.x + buttonRect.z, y >= buttonRect.y, y <= buttonRect.y + buttonRect.w {
            spinning.toggle()
            taps += 1
        }
    }
}

/// Aplicativo da demo M2: cubo + botão com texto sobre Metal, dirigido por `CajuMainLoop`.
struct CajuDemoApp: CajuApplication {
    let state: CajuDemoState
    private var gpu: CajuDemoGPU?
    private var angle: Float = 0

    init(state: CajuDemoState) { self.state = state }

    private static func descriptor(_ s: CajuPlatformSurface) -> CajuSurfaceDescriptor {
        CajuSurfaceDescriptor(
            kind: .metalLayer, nativeHandle: s.nativeHandle, pixelWidth: s.pixelWidth, pixelHeight: s.pixelHeight,
            scale: s.scale, preferredFormat: .bgra8UnormSRGB, presentMode: .fifo)
    }

    mutating func handle(_ event: CajuPlatformEvent) {
        switch event {
        case .surfaceCreated(let s), .surfaceChanged(let s):
            state.scale = s.scale
            let d = Self.descriptor(s)
            do {
                if let gpu { try gpu.recreateSurface(d) } else { gpu = try CajuDemoGPU(surface: d) }
            } catch { print("caju demo: falha ao criar superfície: \(error)") }
            if case .surfaceCreated = event { state.surfaceCreated += 1 }
        case .surfaceDestroyed:
            gpu?.releaseSurface()
            state.surfaceDestroyed += 1
        case .lifecycle(.lowMemory):
            gpu?.device.releaseTransients()
        case .lifecycle:
            break
        }
    }

    mutating func update(_ tick: CajuFrameTick) {
        guard let gpu else { return }
        angle += Float(tick.deltaSeconds) * (state.spinning ? 1.1 : 0.0)
        do { try gpu.renderFrame(angle: angle, spinning: state.spinning) } catch {
            print("caju demo: erro de render: \(error)")
        }
        state.buttonRect = gpu.buttonRect
        state.frames += 1
    }
}

#if canImport(UIKit)
    struct CajuGameView: UIViewRepresentable {
        let state: CajuDemoState
        func makeUIView(context: Context) -> CajuMetalView {
            let host = CajuAppleHost()
            context.coordinator.host = host
            host.run(CajuDemoApp(state: state), window: CajuWindowConfiguration(title: "Caju"))
            return host.view
        }
        func updateUIView(_ view: CajuMetalView, context: Context) {}
        func makeCoordinator() -> Coordinator { Coordinator() }
        @MainActor final class Coordinator { var host: CajuAppleHost? }
    }
#else
    struct CajuGameView: NSViewRepresentable {
        let state: CajuDemoState
        func makeNSView(context: Context) -> CajuMetalView {
            let host = CajuAppleHost()
            context.coordinator.host = host
            host.run(CajuDemoApp(state: state), window: CajuWindowConfiguration(title: "Caju"))
            return host.view
        }
        func updateNSView(_ view: CajuMetalView, context: Context) {}
        func makeCoordinator() -> Coordinator { Coordinator() }
        @MainActor final class Coordinator { var host: CajuAppleHost? }
    }
#endif

@main
struct CajuHostApp: App {
    @State private var state = CajuDemoState()

    var body: some Scene {
        WindowGroup {
            CajuGameView(state: state)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { state.tap(atPoint: $0) }
        }
    }
}
