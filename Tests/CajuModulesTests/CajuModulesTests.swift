import CajuAnim
import CajuAssets
import CajuAssetsCore
import CajuAudio
import CajuCollections
import CajuCore
import CajuInput
import CajuMath
import CajuNet
import CajuPhysics
import CajuPhysicsSpatial
import CajuPlatform
import CajuRHI
import CajuRHIMetal
import CajuRHIVulkan
import CajuRender
import CajuScene
import CajuScripting
import CajuTesting
import CajuText
import CajuUI
import CajuUILayout
import Testing

/// Garante que todos os módulos declarados no M0 compilam e linkam juntos.
@Suite("Módulos declarados")
struct CajuModulesTests {
    @Test func everyModuleLinks() {
        _ = CajuCoreModule.self
        _ = CajuCollectionsModule.self
        _ = CajuAssetsCoreModule.self
        _ = CajuTextModule.self
        _ = CajuUILayoutModule.self
        _ = CajuPhysicsSpatialModule.self
        _ = CajuPlatformModule.self
        _ = CajuRHIModule.self
        _ = CajuRHIMetalModule.self
        _ = CajuRHIVulkanModule.self
        _ = CajuSceneModule.self
        _ = CajuInputModule.self
        _ = CajuRenderModule.self
        _ = CajuAssetsModule.self
        _ = CajuAnimModule.self
        _ = CajuAudioModule.self
        _ = CajuUIModule.self
        _ = CajuPhysicsModule.self
        _ = CajuNetModule.self
        _ = CajuScriptingModule.self
        _ = CajuVec3.zero
        _ = CajuPCG32(seed: 0)
    }
}
