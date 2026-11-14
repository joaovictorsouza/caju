import CajuCore
import Testing

@Suite("CajuCore")
struct CajuCoreSmokeTests {
    @Test func moduleLinks() {
        _ = CajuCoreModule.self
    }
}
