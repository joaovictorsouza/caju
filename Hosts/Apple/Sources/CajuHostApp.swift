import CajuMath
import SwiftUI

/// Host mínimo iOS/macOS do M0: prova que o pacote é consumido por um app.
/// A janela/superfície de render real chega com a trilha TB-2 (`CajuPlatform`).
@main
struct CajuHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Caju host (M0): \(CajuVec3(1, 2, 3).length)")
                .padding()
        }
    }
}
