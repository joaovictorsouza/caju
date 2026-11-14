import Testing

@testable import CajuRHIVulkan

@Suite("CajuVulkanSwapchainPlan")
struct CajuVulkanSwapchainPlanTests {
    typealias Plan = CajuVulkanSwapchainPlan

    @Test func imageCountIsMinPlusOneClampedToMax() {
        #expect(Plan.imageCount(min: 2, max: 0) == 3)
        #expect(Plan.imageCount(min: 2, max: 8) == 3)
        #expect(Plan.imageCount(min: 3, max: 3) == 3)
        #expect(Plan.imageCount(min: .max, max: 0) == 0)  // sem estouro (wrapping); o driver rejeita
    }

    @Test func extentUsesCurrentWhenDefined() {
        let result = Plan.extent(
            current: .init(width: 1080, height: 2340),
            minimum: .init(width: 1, height: 1), maximum: .init(width: 4096, height: 4096),
            fallback: .init(width: 10, height: 10))
        #expect(result == .init(width: 1080, height: 2340))
    }

    @Test func extentClampsFallbackWhenUndefined() {
        let undefined = Plan.Extent(width: Plan.undefinedExtent, height: Plan.undefinedExtent)
        let min = Plan.Extent(width: 100, height: 100)
        let max = Plan.Extent(width: 200, height: 200)
        #expect(
            Plan.extent(
                current: undefined, minimum: min, maximum: max, fallback: .init(width: 50, height: 500))
                == .init(width: 100, height: 200))
    }

    @Test func emptyExtentIsNotDrawable() {
        #expect(Plan.Extent(width: 0, height: 100).isEmpty)
        #expect(Plan.Extent(width: 100, height: 0).isEmpty)
        #expect(!Plan.Extent(width: 1, height: 1).isEmpty)
    }

    @Test func formatPreferenceOrder() {
        let unorm = Plan.SurfaceFormat(format: 44, colorSpace: 0)
        let rgbaSRGB = Plan.SurfaceFormat(format: 43, colorSpace: 0)
        let bgraSRGB = Plan.SurfaceFormat(format: 50, colorSpace: 0)
        #expect(Plan.chooseFormat([unorm, rgbaSRGB, bgraSRGB]) == bgraSRGB)
        #expect(Plan.chooseFormat([unorm, rgbaSRGB]) == rgbaSRGB)
        #expect(Plan.chooseFormat([unorm]) == unorm)
        #expect(Plan.chooseFormat([]) == nil)
        #expect(
            Plan.chooseFormat([.init(format: 50, colorSpace: 1_000_104_001)])
                == .init(format: 50, colorSpace: 1_000_104_001))
    }

    @Test func errorsAreEquatable() {
        #expect(CajuVulkanError.vulkan(step: .swapchain, code: -4) == .vulkan(step: .swapchain, code: -4))
        #expect(CajuVulkanError.noSuitableDevice != .noSurfaceFormat)
    }
}
