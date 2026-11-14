import CajuRHI
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
        #expect(
            Plan.chooseFormat([unorm, bgraSRGB], preferredFormat: 44) == unorm)
        #expect(
            Plan.chooseFormat([unorm, rgbaSRGB], preferredFormat: 50) == rgbaSRGB)
    }

    @Test func errorsAreEquatable() {
        #expect(CajuVulkanError.vulkan(step: .swapchain, code: -4) == .vulkan(step: .swapchain, code: -4))
        #expect(CajuVulkanError.noSuitableDevice != .noSurfaceFormat)
    }
}

@Suite("CajuVulkanTranslation")
struct CajuVulkanTranslationTests {
    typealias T = CajuVulkanTranslation

    @Test func pixelFormatsRoundTripAndMatchSpecConstants() {
        for format in CajuPixelFormat.allCases {
            let vk = T.vkFormat(for: format)
            #expect(T.pixelFormat(fromVkFormat: vk) == format)
        }
        #expect(T.vkFormat(for: .r8Unorm) == 9)
        #expect(T.vkFormat(for: .rg8Unorm) == 16)
        #expect(T.vkFormat(for: .rgba8Unorm) == 37)
        #expect(T.vkFormat(for: .rgba8UnormSRGB) == 43)
        #expect(T.vkFormat(for: .bgra8Unorm) == 44)
        #expect(T.vkFormat(for: .bgra8UnormSRGB) == 50)
        #expect(T.vkFormat(for: .rgb10a2Unorm) == 64)
        #expect(T.vkFormat(for: .rgba16Float) == 97)
        #expect(T.vkFormat(for: .r32Float) == 100)
        #expect(T.vkFormat(for: .depth16Unorm) == 124)
        #expect(T.vkFormat(for: .depth32Float) == 126)
        #expect(T.vkFormat(for: .depth32FloatStencil8) == 130)
        #expect(T.vkFormat(for: .astc4x4) == 157)
        #expect(T.vkFormat(for: .astc4x4SRGB) == 158)
        #expect(T.vkFormat(for: .astc5x5) == 161)
        #expect(T.vkFormat(for: .astc5x5SRGB) == 162)
        #expect(T.vkFormat(for: .astc6x6) == 165)
        #expect(T.vkFormat(for: .astc6x6SRGB) == 166)
        #expect(T.vkFormat(for: .astc8x8) == 171)
        #expect(T.vkFormat(for: .astc8x8SRGB) == 172)
        #expect(T.pixelFormat(fromVkFormat: 0) == nil)
    }

    @Test func vertexFormatsAndStepFunctions() {
        #expect(T.vkVertexFormat(for: .float) == 100)
        #expect(T.vkVertexFormat(for: .float2) == 103)
        #expect(T.vkVertexFormat(for: .float3) == 106)
        #expect(T.vkVertexFormat(for: .float4) == 109)
        #expect(T.vkVertexFormat(for: .uint) == 98)
        #expect(T.vkVertexFormat(for: .uint2) == 101)
        #expect(T.vkVertexFormat(for: .uint3) == 104)
        #expect(T.vkVertexFormat(for: .uint4) == 107)
        #expect(T.vkVertexFormat(for: .unorm8x4) == 37)
        #expect(T.vkVertexFormat(for: .half2) == 83)
        #expect(T.vkVertexFormat(for: .half4) == 97)
        #expect(T.vkVertexInputRate(for: .perVertex) == 0)
        #expect(T.vkVertexInputRate(for: .perInstance) == 1)
    }

    @Test func loadStoreOpsAndRenderPassVariants() {
        #expect(T.vkLoadOp(for: .load) == 0)
        #expect(T.vkLoadOp(for: .clear(SIMD4(0, 0, 0, 1))) == 1)
        #expect(T.vkLoadOp(for: .dontCare) == 2)

        #expect(T.vkStoreOp(for: .store) == 0)
        #expect(T.vkStoreOp(for: .storeAndResolve) == 0)
        #expect(T.vkStoreOp(for: .dontCare) == 1)
        #expect(T.vkStoreOp(for: .resolve) == 1)

        #expect(T.renderPassVariantIndex(load: .load, store: .store) == 0)
        #expect(T.renderPassVariantIndex(load: .load, store: .dontCare) == 1)
        #expect(T.renderPassVariantIndex(load: .clear(SIMD4(0, 0, 0, 1)), store: .store) == 2)
        #expect(T.renderPassVariantIndex(load: .clear(SIMD4(0, 0, 0, 1)), store: .dontCare) == 3)
        #expect(T.renderPassVariantIndex(load: .dontCare, store: .store) == 4)
        #expect(T.renderPassVariantIndex(load: .dontCare, store: .dontCare) == 5)
    }

    @Test func pipelineStateEnums() {
        #expect(T.vkPrimitiveTopology(for: .pointList) == 0)
        #expect(T.vkPrimitiveTopology(for: .lineList) == 1)
        #expect(T.vkPrimitiveTopology(for: .triangleList) == 3)
        #expect(T.vkPrimitiveTopology(for: .triangleStrip) == 4)

        #expect(T.vkCullMode(for: .none) == 0)
        #expect(T.vkCullMode(for: .front) == 1)
        #expect(T.vkCullMode(for: .back) == 2)

        #expect(T.vkFrontFace(for: .counterClockwise) == 0)
        #expect(T.vkFrontFace(for: .clockwise) == 1)

        #expect(T.vkCompareOp(for: .never) == 0)
        #expect(T.vkCompareOp(for: .less) == 1)
        #expect(T.vkCompareOp(for: .equal) == 2)
        #expect(T.vkCompareOp(for: .lessEqual) == 3)
        #expect(T.vkCompareOp(for: .greater) == 4)
        #expect(T.vkCompareOp(for: .notEqual) == 5)
        #expect(T.vkCompareOp(for: .greaterEqual) == 6)
        #expect(T.vkCompareOp(for: .always) == 7)

        #expect(T.vkBlendFactor(for: .zero) == 0)
        #expect(T.vkBlendFactor(for: .one) == 1)
        #expect(T.vkBlendFactor(for: .sourceAlpha) == 6)
        #expect(T.vkBlendFactor(for: .oneMinusSourceAlpha) == 7)
        #expect(T.vkBlendFactor(for: .destinationAlpha) == 8)
        #expect(T.vkBlendFactor(for: .oneMinusDestinationAlpha) == 9)

        #expect(T.vkBlendOp(for: .add) == 0)
        #expect(T.vkBlendOp(for: .subtract) == 1)
        #expect(T.vkBlendOp(for: .reverseSubtract) == 2)
        #expect(T.vkBlendOp(for: .min) == 3)
        #expect(T.vkBlendOp(for: .max) == 4)
    }

    @Test func indexStageBufferSampleAndPresentMappings() {
        #expect(T.vkIndexType(for: .uint16) == 0)
        #expect(T.vkIndexType(for: .uint32) == 1)

        #expect(T.vkShaderStage(for: .vertex) == 0x01)
        #expect(T.vkShaderStage(for: .fragment) == 0x10)
        #expect(T.vkShaderStage(for: .compute) == 0x20)

        let usage: CajuBufferUsage = [
            .copySource, .copyDestination, .uniform, .storage, .index, .vertex,
        ]
        #expect(T.vkBufferUsage(for: usage) == (0x01 | 0x02 | 0x10 | 0x20 | 0x40 | 0x80))

        #expect(T.vkPresentMode(for: .immediate) == 0)
        #expect(T.vkPresentMode(for: .mailbox) == 1)
        #expect(T.vkPresentMode(for: .fifo) == 2)

        #expect(T.vkSampleCount(for: 1) == 1)
        #expect(T.vkSampleCount(for: 2) == 2)
        #expect(T.vkSampleCount(for: 4) == 4)
        #expect(T.vkSampleCount(for: 8) == 8)
        #expect(T.vkSampleCount(for: 3) == nil)

        #expect(T.sampleCounts(fromVkMask: 0b0101) == [.x1, .x4])
        #expect(T.sampleCounts(fromVkMask: 0b1111) == [.x1, .x2, .x4, .x8])
    }

    @Test func vkResultToRHIError() {
        #expect(T.rhiError(fromVkResult: -1) == .outOfMemory)
        #expect(T.rhiError(fromVkResult: -2) == .outOfMemory)
        #expect(T.rhiError(fromVkResult: -4) == .deviceLost)
        #expect(T.rhiError(fromVkResult: -1_000_000_000) == .surfaceLost)
        #expect(T.rhiError(fromVkResult: -1_000_001_004) == .surfaceOutOfDate)
        #expect(T.rhiError(fromVkResult: -3) == .backend(code: -3))
    }

    @Test func findMemoryTypeSelectsMatchingBitAndFlags() {
        let props: [UInt32] = [0x01, 0x06, 0x07]
        #expect(T.findMemoryType(typeBits: 0b110, memoryPropertyFlags: props, requiredFlags: 0x06) == 1)
        #expect(T.findMemoryType(typeBits: 0b100, memoryPropertyFlags: props, requiredFlags: 0x07) == 2)
        #expect(T.findMemoryType(typeBits: 0b001, memoryPropertyFlags: props, requiredFlags: 0x06) == nil)
    }

    @Test func spirvWordsValidationAndPacking() throws {
        let desc = CajuShaderModuleDescriptor(
            format: .spirv, code: [0x03, 0x02, 0x23, 0x07, 0x00, 0x00, 0x01, 0x00])
        let words = try T.spirvWords(from: desc)
        #expect(words == [0x0723_0203, 0x0001_0000])

        #expect(throws: CajuRHIError.invalidDescriptor(.missingShader)) {
            _ = try T.spirvWords(from: CajuShaderModuleDescriptor(format: .spirv, code: []))
        }
        #expect(throws: CajuRHIError.invalidDescriptor(.missingShader)) {
            _ = try T.spirvWords(from: CajuShaderModuleDescriptor(format: .spirv, code: [1, 2, 3]))
        }
        #expect(throws: CajuRHIError.invalidDescriptor(.incompatibleUsage)) {
            _ = try T.spirvWords(
                from: CajuShaderModuleDescriptor(format: .metalSource, code: [1, 2, 3, 4]))
        }
    }

    @Test func descriptorValidations() throws {
        let caps = CajuDeviceCapabilities(
            backendName: "Vulkan", deviceName: "Test GPU", maxTextureDimension2D: 4096,
            maxBufferSize: 1024, presentModes: [.fifo])

        try T.validateBufferDescriptor(
            CajuBufferDescriptor(size: 64, usage: .vertex), capabilities: caps)
        #expect(throws: CajuRHIError.invalidDescriptor(.zeroSize)) {
            try T.validateBufferDescriptor(
                CajuBufferDescriptor(size: 0, usage: .vertex), capabilities: caps)
        }
        #expect(throws: CajuRHIError.invalidDescriptor(.exceedsDeviceLimit)) {
            try T.validateBufferDescriptor(
                CajuBufferDescriptor(size: 2048, usage: .vertex), capabilities: caps)
        }
        #expect(throws: CajuRHIError.invalidDescriptor(.emptyUsage)) {
            try T.validateBufferDescriptor(
                CajuBufferDescriptor(size: 16, usage: []), capabilities: caps)
        }
        #expect(throws: CajuRHIError.invalidDescriptor(.incompatibleUsage)) {
            try T.validateBufferDescriptor(
                CajuBufferDescriptor(size: 16, usage: .vertex, storage: .memoryless),
                capabilities: caps)
        }

        try T.validateSurfaceDescriptor(
            CajuSurfaceDescriptor(
                kind: .androidNativeWindow, nativeHandle: 0x1000, pixelWidth: 1080,
                pixelHeight: 2340),
            capabilities: caps)
        #expect(throws: CajuRHIError.invalidDescriptor(.incompatibleUsage)) {
            try T.validateSurfaceDescriptor(
                CajuSurfaceDescriptor(
                    kind: .metalLayer, nativeHandle: 0x1000, pixelWidth: 100, pixelHeight: 100),
                capabilities: caps)
        }
        #expect(throws: CajuRHIError.surfaceLost) {
            try T.validateSurfaceDescriptor(
                CajuSurfaceDescriptor(
                    kind: .androidNativeWindow, nativeHandle: 0, pixelWidth: 100, pixelHeight: 100),
                capabilities: caps)
        }
        #expect(throws: CajuRHIError.unsupported(.presentMode(.immediate))) {
            try T.validateSurfaceDescriptor(
                CajuSurfaceDescriptor(
                    kind: .androidNativeWindow, nativeHandle: 0x1000, pixelWidth: 100,
                    pixelHeight: 100, presentMode: .immediate),
                capabilities: caps)
        }
    }
}
