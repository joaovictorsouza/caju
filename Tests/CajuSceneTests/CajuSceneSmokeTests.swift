import CajuScene
import Testing

@Suite("CajuScene")
struct CajuSceneSmokeTests {
    @Test func moduleLinks() {
        _ = CajuSceneModule.self
    }
}
