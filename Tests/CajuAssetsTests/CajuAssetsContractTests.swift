import CajuAssets
import CajuAssetsCore
import Testing

private struct Mesh: CajuAsset, Equatable { var vertices: Int }
private struct Texture: CajuAsset {}

/// Contrato de A-1 (ADR 0021): handles geracionais, máquina de estados e posse. Ficam em `CajuModulesTests`
/// até existir o alvo `CajuAssetsTests` (PR dedicado ao `Package.swift`, como no ADR 0017).
@Suite("CajuAssets contrato")
struct CajuAssetsContractTests {
    @Test func handleIsSmallBitwiseCopyableAndInvalidNeverResolves() {
        #expect(MemoryLayout<CajuAssetHandle<Mesh>>.size == 8)
        var store = CajuAssetStore<Mesh>()
        _ = store.reserve()
        #expect(store.state(of: .invalid) == .stale)
        #expect(store.value(of: .invalid) == nil)
        #expect(store.revision(of: .invalid) == 0)
    }

    @Test func erasedHandleRoundTripsOnlyToItsType() {
        let h = CajuAssetHandle<Mesh>(index: 3, generation: 7)
        #expect(h.erased.typed(as: Mesh.self) == h)
        #expect(h.erased.typed(as: Texture.self) == nil)
    }

    @Test func happyPathLoadPublishesValueAndRevision() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        #expect(store.state(of: h) == .queued)
        #expect(store.value(of: h) == nil)
        let r1 = store.beginLoading(h)
        #expect(r1)
        #expect(store.state(of: h) == .loading && store.state(of: h).isPending)
        let r2 = store.complete(h, value: Mesh(vertices: 3))
        #expect(r2)
        #expect(store.state(of: h) == .loaded)
        #expect(store.value(of: h) == Mesh(vertices: 3))
        #expect(store.revision(of: h) == 1)
    }

    @Test func failedLoadKeepsErrorAndNoValue() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        store.beginLoading(h)
        let r3 = store.fail(h, error: .notFound(path: "a/b.glb"))
        #expect(r3)
        #expect(store.state(of: h) == .failed)
        #expect(store.error(of: h) == .notFound(path: "a/b.glb"))
        #expect(store.value(of: h) == nil)
        // Nova tentativa a partir de `failed` e sucesso limpam o erro.
        let r4 = store.beginReload(h)
        #expect(r4)
        #expect(store.state(of: h) == .loading)
        let r5 = store.complete(h, value: Mesh(vertices: 1))
        #expect(r5)
        #expect(store.error(of: h) == nil)
    }

    @Test func reloadKeepsOldValueUntilSwap() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        store.beginLoading(h)
        store.complete(h, value: Mesh(vertices: 1))
        let r6 = store.beginReload(h)
        #expect(r6)
        #expect(store.state(of: h) == .reloading)
        #expect(store.value(of: h) == Mesh(vertices: 1))
        let r7 = store.complete(h, value: Mesh(vertices: 2))
        #expect(r7)
        #expect(store.value(of: h) == Mesh(vertices: 2))
        #expect(store.revision(of: h) == 2)
    }

    @Test func failedReloadKeepsOldValueAndRecordsError() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        store.beginLoading(h)
        store.complete(h, value: Mesh(vertices: 1))
        store.beginReload(h)
        let r8 = store.fail(h, error: .cancelled)
        #expect(r8)
        #expect(store.state(of: h) == .loaded)
        #expect(store.value(of: h) == Mesh(vertices: 1))
        #expect(store.error(of: h) == .cancelled)
        #expect(store.revision(of: h) == 1)
    }

    @Test func illegalTransitionsAreRejected() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        let r9 = store.complete(h, value: Mesh(vertices: 1))
        #expect(!r9)  // queued não completa
        let r10 = store.fail(h, error: .cancelled)
        #expect(!r10)
        let r11 = store.beginReload(h)
        #expect(!r11)
        store.beginLoading(h)
        let r12 = store.beginLoading(h)
        #expect(!r12)
    }

    @Test func releaseToZeroInvalidatesHandleAndReusesSlotWithNewGeneration() {
        var store = CajuAssetStore<Mesh>()
        let a = store.reserve()
        store.beginLoading(a)
        store.complete(a, value: Mesh(vertices: 9))
        let r13 = store.retain(a)
        #expect(r13)
        let r14 = store.release(a)
        #expect(r14)
        #expect(store.state(of: a) == .loaded)  // ainda há uma posse
        let r15 = store.release(a)
        #expect(r15)
        #expect(store.state(of: a) == .stale)
        #expect(store.value(of: a) == nil)
        let r16 = store.release(a)
        #expect(!r16)  // handle velho
        let r17 = store.retain(a)
        #expect(!r17)
        #expect(store.liveCount == 0)

        let b = store.reserve()
        #expect(b.index == a.index && b.generation != a.generation)
        #expect(store.state(of: a) == .stale && store.state(of: b) == .queued)
        let r18 = store.complete(a, value: Mesh(vertices: 1))
        #expect(!r18)  // handle velho não escreve no slot novo
    }

    @Test func pathsAreValidated() throws {
        #expect(try CajuAssetPath("models/chair.glb").rawValue == "models/chair.glb")
        for bad in ["", "/a", "a/", "a//b", "a/../b", "./a", "a\\b", "a/.", "..", "a\0b"] {
            #expect(throws: CajuAssetError.self) { try CajuAssetPath(bad) }
        }
        #expect(try CajuAssetPath(".hidden/a..b").rawValue == ".hidden/a..b")
    }
}
