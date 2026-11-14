import CajuText
import Testing

@Suite("CajuText link")
struct CajuTextLinkTests {
    @Test func moduleLinks() {
        _ = CajuTextModule.self
    }
}
