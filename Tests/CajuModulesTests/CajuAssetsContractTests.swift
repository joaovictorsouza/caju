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
        #expect(store.beginLoading(h))
        #expect(store.state(of: h) == .loading && store.state(of: h).isPending)
        #expect(store.complete(h, value: Mesh(vertices: 3)))
        #expect(store.state(of: h) == .loaded)
        #expect(store.value(of: h) == Mesh(vertices: 3))
        #expect(store.revision(of: h) == 1)
    }

    @Test func failedLoadKeepsErrorAndNoValue() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        store.beginLoading(h)
        #expect(store.fail(h, error: .notFound(path: "a/b.glb")))
        #expect(store.state(of: h) == .failed)
        #expect(store.error(of: h) == .notFound(path: "a/b.glb"))
        #expect(store.value(of: h) == nil)
        // Nova tentativa a partir de `failed` e sucesso limpam o erro.
        #expect(store.beginReload(h))
        #expect(store.state(of: h) == .loading)
        #expect(store.complete(h, value: Mesh(vertices: 1)))
        #expect(store.error(of: h) == nil)
    }

    @Test func reloadKeepsOldValueUntilSwap() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        store.beginLoading(h)
        store.complete(h, value: Mesh(vertices: 1))
        #expect(store.beginReload(h))
        #expect(store.state(of: h) == .reloading)
        #expect(store.value(of: h) == Mesh(vertices: 1))
        #expect(store.complete(h, value: Mesh(vertices: 2)))
        #expect(store.value(of: h) == Mesh(vertices: 2))
        #expect(store.revision(of: h) == 2)
    }

    @Test func failedReloadKeepsOldValueAndRecordsError() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        store.beginLoading(h)
        store.complete(h, value: Mesh(vertices: 1))
        store.beginReload(h)
        #expect(store.fail(h, error: .cancelled))
        #expect(store.state(of: h) == .loaded)
        #expect(store.value(of: h) == Mesh(vertices: 1))
        #expect(store.error(of: h) == .cancelled)
        #expect(store.revision(of: h) == 1)
    }

    @Test func illegalTransitionsAreRejected() {
        var store = CajuAssetStore<Mesh>()
        let h = store.reserve()
        #expect(!store.complete(h, value: Mesh(vertices: 1)))  // queued não completa
        #expect(!store.fail(h, error: .cancelled))
        #expect(!store.beginReload(h))
        store.beginLoading(h)
        #expect(!store.beginLoading(h))
    }

    @Test func releaseToZeroInvalidatesHandleAndReusesSlotWithNewGeneration() {
        var store = CajuAssetStore<Mesh>()
        let a = store.reserve()
        store.beginLoading(a)
        store.complete(a, value: Mesh(vertices: 9))
        #expect(store.retain(a))
        #expect(store.release(a))
        #expect(store.state(of: a) == .loaded)  // ainda há uma posse
        #expect(store.release(a))
        #expect(store.state(of: a) == .stale)
        #expect(store.value(of: a) == nil)
        #expect(!store.release(a))  // handle velho
        #expect(!store.retain(a))
        #expect(store.liveCount == 0)

        let b = store.reserve()
        #expect(b.index == a.index && b.generation != a.generation)
        #expect(store.state(of: a) == .stale && store.state(of: b) == .queued)
        #expect(!store.complete(a, value: Mesh(vertices: 1)))  // handle velho não escreve no slot novo
    }

    @Test func pathsAreValidated() throws {
        #expect(try CajuAssetPath("models/chair.glb").rawValue == "models/chair.glb")
        for bad in ["", "/a", "a/", "a//b", "a/../b", "./a", "a\\b", "a/.", "..", "a\0b"] {
            #expect(throws: CajuAssetError.self) { try CajuAssetPath(bad) }
        }
        #expect(try CajuAssetPath(".hidden/a..b").rawValue == ".hidden/a..b")
    }
}
