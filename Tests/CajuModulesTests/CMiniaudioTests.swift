import CMiniaudio
import Testing

/// Garante que o miniaudio vendorizado compila, linka e é a versão fixada (Sources/CMiniaudio/VERSION).
@Suite("CMiniaudio")
struct CMiniaudioTests {
    @Test func versionIsPinned() {
        #expect(MA_VERSION_MAJOR == 0)
        #expect(MA_VERSION_MINOR == 11)
        #expect(MA_VERSION_REVISION == 26)
    }

    @Test func nullBackendContextInitializes() {
        var context = ma_context()
        var backend = ma_backend_null
        #expect(ma_context_init(&backend, 1, nil, &context) == MA_SUCCESS)
        #expect(ma_context_uninit(&context) == MA_SUCCESS)
    }
}
