import CajuRHI

/// Traduções puras (sem `CVulkan`) entre os descritores do `CajuRHI` e as constantes da
/// especificação Vulkan 1.1 (`VkFormat`, `VkAttachmentLoadOp`, `VkPrimitiveTopology`, etc.).
///
/// Compila em todas as plataformas (macOS, Linux e Android) para permitir testes de unidade
/// completos no host sem depender do NDK.
public enum CajuVulkanTranslation {
    // MARK: - Formatos de pixel (VkFormat)

    /// Converte um `CajuPixelFormat` para o valor numérico correspondente de `VkFormat`.
    public static func vkFormat(for format: CajuPixelFormat) -> UInt32 {
        switch format {
        case .r8Unorm: 9  // VK_FORMAT_R8_UNORM
        case .rg8Unorm: 16  // VK_FORMAT_R8G8_UNORM
        case .rgba8Unorm: 37  // VK_FORMAT_R8G8B8A8_UNORM
        case .rgba8UnormSRGB: 43  // VK_FORMAT_R8G8B8A8_SRGB
        case .bgra8Unorm: 44  // VK_FORMAT_B8G8R8A8_UNORM
        case .bgra8UnormSRGB: 50  // VK_FORMAT_B8G8R8A8_SRGB
        case .rgb10a2Unorm: 64  // VK_FORMAT_A2B10G10R10_UNORM_PACK32
        case .rgba16Float: 97  // VK_FORMAT_R16G16B16A16_SFLOAT
        case .r32Float: 100  // VK_FORMAT_R32_SFLOAT
        case .depth16Unorm: 124  // VK_FORMAT_D16_UNORM
        case .depth32Float: 126  // VK_FORMAT_D32_SFLOAT
        case .depth32FloatStencil8: 130  // VK_FORMAT_D32_SFLOAT_S8_UINT
        case .astc4x4: 157  // VK_FORMAT_ASTC_4x4_UNORM_BLOCK
        case .astc4x4SRGB: 158  // VK_FORMAT_ASTC_4x4_SRGB_BLOCK
        case .astc5x5: 161  // VK_FORMAT_ASTC_5x5_UNORM_BLOCK
        case .astc5x5SRGB: 162  // VK_FORMAT_ASTC_5x5_SRGB_BLOCK
        case .astc6x6: 165  // VK_FORMAT_ASTC_6x6_UNORM_BLOCK
        case .astc6x6SRGB: 166  // VK_FORMAT_ASTC_6x6_SRGB_BLOCK
        case .astc8x8: 171  // VK_FORMAT_ASTC_8x8_UNORM_BLOCK
        case .astc8x8SRGB: 172  // VK_FORMAT_ASTC_8x8_SRGB_BLOCK
        }
    }

    /// Converte um valor numérico de `VkFormat` de volta para `CajuPixelFormat`, ou `nil` se não mapeado.
    public static func pixelFormat(fromVkFormat vkFormat: UInt32) -> CajuPixelFormat? {
        switch vkFormat {
        case 9: .r8Unorm
        case 16: .rg8Unorm
        case 37: .rgba8Unorm
        case 43: .rgba8UnormSRGB
        case 44: .bgra8Unorm
        case 50: .bgra8UnormSRGB
        case 64: .rgb10a2Unorm
        case 97: .rgba16Float
        case 100: .r32Float
        case 124: .depth16Unorm
        case 126: .depth32Float
        case 130: .depth32FloatStencil8
        case 157: .astc4x4
        case 158: .astc4x4SRGB
        case 161: .astc5x5
        case 162: .astc5x5SRGB
        case 165: .astc6x6
        case 166: .astc6x6SRGB
        case 171: .astc8x8
        case 172: .astc8x8SRGB
        default: nil
        }
    }

    // MARK: - Formatos de atributo de vértice (VkFormat)

    /// Converte um `CajuVertexFormat` para o valor numérico correspondente de `VkFormat`.
    public static func vkVertexFormat(for format: CajuVertexFormat) -> UInt32 {
        switch format {
        case .float: 100  // VK_FORMAT_R32_SFLOAT
        case .float2: 103  // VK_FORMAT_R32G32_SFLOAT
        case .float3: 106  // VK_FORMAT_R32G32B32_SFLOAT
        case .float4: 109  // VK_FORMAT_R32G32B32A32_SFLOAT
        case .uint: 98  // VK_FORMAT_R32_UINT
        case .uint2: 101  // VK_FORMAT_R32G32_UINT
        case .uint3: 104  // VK_FORMAT_R32G32B32_UINT
        case .uint4: 107  // VK_FORMAT_R32G32B32A32_UINT
        case .unorm8x4: 37  // VK_FORMAT_R8G8B8A8_UNORM
        case .half2: 83  // VK_FORMAT_R16G16_SFLOAT
        case .half4: 97  // VK_FORMAT_R16G16B16A16_SFLOAT
        }
    }

    /// Converte `CajuVertexStepFunction` para `VkVertexInputRate`.
    public static func vkVertexInputRate(for step: CajuVertexStepFunction) -> UInt32 {
        switch step {
        case .perVertex: 0  // VK_VERTEX_INPUT_RATE_VERTEX
        case .perInstance: 1  // VK_VERTEX_INPUT_RATE_INSTANCE
        }
    }

    // MARK: - Operações de passe de render (VkAttachmentLoadOp / VkAttachmentStoreOp)

    /// Converte `CajuLoadAction` para `VkAttachmentLoadOp`.
    public static func vkLoadOp(for action: CajuLoadAction) -> UInt32 {
        switch action {
        case .load: 0  // VK_ATTACHMENT_LOAD_OP_LOAD
        case .clear: 1  // VK_ATTACHMENT_LOAD_OP_CLEAR
        case .dontCare: 2  // VK_ATTACHMENT_LOAD_OP_DONT_CARE
        }
    }

    /// Converte `CajuStoreAction` para `VkAttachmentStoreOp`.
    public static func vkStoreOp(for action: CajuStoreAction) -> UInt32 {
        switch action {
        case .store, .storeAndResolve: 0  // VK_ATTACHMENT_STORE_OP_STORE
        case .dontCare, .resolve: 1  // VK_ATTACHMENT_STORE_OP_DONT_CARE
        }
    }

    /// Índice `0..<6` da variante de `VkRenderPass` pré-criada na swapchain para `(load, store)`.
    public static func renderPassVariantIndex(load: CajuLoadAction, store: CajuStoreAction) -> Int {
        Int(vkLoadOp(for: load)) * 2 + Int(vkStoreOp(for: store))
    }

    // MARK: - Estado de pipeline (topologia, rasterização, profundidade, mistura)

    /// Converte `CajuPrimitiveTopology` para `VkPrimitiveTopology`.
    public static func vkPrimitiveTopology(for topology: CajuPrimitiveTopology) -> UInt32 {
        switch topology {
        case .pointList: 0  // VK_PRIMITIVE_TOPOLOGY_POINT_LIST
        case .lineList: 1  // VK_PRIMITIVE_TOPOLOGY_LINE_LIST
        case .triangleList: 3  // VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
        case .triangleStrip: 4  // VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
        }
    }

    /// Converte `CajuCullMode` para `VkCullModeFlags`.
    public static func vkCullMode(for mode: CajuCullMode) -> UInt32 {
        switch mode {
        case .none: 0  // VK_CULL_MODE_NONE
        case .front: 1  // VK_CULL_MODE_FRONT_BIT
        case .back: 2  // VK_CULL_MODE_BACK_BIT
        }
    }

    /// Converte `CajuWinding` para `VkFrontFace`.
    public static func vkFrontFace(for winding: CajuWinding) -> UInt32 {
        switch winding {
        case .counterClockwise: 0  // VK_FRONT_FACE_COUNTER_CLOCKWISE
        case .clockwise: 1  // VK_FRONT_FACE_CLOCKWISE
        }
    }

    /// Converte `CajuCompareFunction` para `VkCompareOp`.
    public static func vkCompareOp(for compare: CajuCompareFunction) -> UInt32 {
        switch compare {
        case .never: 0  // VK_COMPARE_OP_NEVER
        case .less: 1  // VK_COMPARE_OP_LESS
        case .equal: 2  // VK_COMPARE_OP_EQUAL
        case .lessEqual: 3  // VK_COMPARE_OP_LESS_OR_EQUAL
        case .greater: 4  // VK_COMPARE_OP_GREATER
        case .notEqual: 5  // VK_COMPARE_OP_NOT_EQUAL
        case .greaterEqual: 6  // VK_COMPARE_OP_GREATER_OR_EQUAL
        case .always: 7  // VK_COMPARE_OP_ALWAYS
        }
    }

    /// Converte `CajuBlendFactor` para `VkBlendFactor`.
    public static func vkBlendFactor(for factor: CajuBlendFactor) -> UInt32 {
        switch factor {
        case .zero: 0  // VK_BLEND_FACTOR_ZERO
        case .one: 1  // VK_BLEND_FACTOR_ONE
        case .sourceAlpha: 6  // VK_BLEND_FACTOR_SRC_ALPHA
        case .oneMinusSourceAlpha: 7  // VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        case .destinationAlpha: 8  // VK_BLEND_FACTOR_DST_ALPHA
        case .oneMinusDestinationAlpha: 9  // VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA
        }
    }

    /// Converte `CajuBlendOperation` para `VkBlendOp`.
    public static func vkBlendOp(for operation: CajuBlendOperation) -> UInt32 {
        switch operation {
        case .add: 0  // VK_BLEND_OP_ADD
        case .subtract: 1  // VK_BLEND_OP_SUBTRACT
        case .reverseSubtract: 2  // VK_BLEND_OP_REVERSE_SUBTRACT
        case .min: 3  // VK_BLEND_OP_MIN
        case .max: 4  // VK_BLEND_OP_MAX
        }
    }

    // MARK: - Índices, estágios, uso de buffer, amostras e apresentação

    /// Converte `CajuIndexType` para `VkIndexType`.
    public static func vkIndexType(for indexType: CajuIndexType) -> UInt32 {
        switch indexType {
        case .uint16: 0  // VK_INDEX_TYPE_UINT16
        case .uint32: 1  // VK_INDEX_TYPE_UINT32
        }
    }

    /// Converte `CajuShaderStage` para `VkShaderStageFlags`.
    public static func vkShaderStage(for stage: CajuShaderStage) -> UInt32 {
        switch stage {
        case .vertex: 0x0000_0001  // VK_SHADER_STAGE_VERTEX_BIT
        case .fragment: 0x0000_0010  // VK_SHADER_STAGE_FRAGMENT_BIT
        case .compute: 0x0000_0020  // VK_SHADER_STAGE_COMPUTE_BIT
        }
    }

    /// Converte `CajuBufferUsage` para `VkBufferUsageFlags`.
    public static func vkBufferUsage(for usage: CajuBufferUsage) -> UInt32 {
        var flags: UInt32 = 0
        if usage.contains(.copySource) { flags |= 0x0000_0001 }  // VK_BUFFER_USAGE_TRANSFER_SRC_BIT
        if usage.contains(.copyDestination) { flags |= 0x0000_0002 }  // VK_BUFFER_USAGE_TRANSFER_DST_BIT
        if usage.contains(.uniform) { flags |= 0x0000_0010 }  // VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT
        if usage.contains(.storage) { flags |= 0x0000_0020 }  // VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
        if usage.contains(.index) { flags |= 0x0000_0040 }  // VK_BUFFER_USAGE_INDEX_BUFFER_BIT
        if usage.contains(.vertex) { flags |= 0x0000_0080 }  // VK_BUFFER_USAGE_VERTEX_BUFFER_BIT
        return flags
    }

    /// Converte `CajuPresentMode` para `VkPresentModeKHR`.
    public static func vkPresentMode(for mode: CajuPresentMode) -> UInt32 {
        switch mode {
        case .immediate: 0  // VK_PRESENT_MODE_IMMEDIATE_KHR
        case .mailbox: 1  // VK_PRESENT_MODE_MAILBOX_KHR
        case .fifo: 2  // VK_PRESENT_MODE_FIFO_KHR
        }
    }

    /// Converte contagem de amostras (`1, 2, 4, 8`) para `VkSampleCountFlagBits`.
    public static func vkSampleCount(for count: Int) -> UInt32? {
        switch count {
        case 1: 1  // VK_SAMPLE_COUNT_1_BIT
        case 2: 2  // VK_SAMPLE_COUNT_2_BIT
        case 4: 4  // VK_SAMPLE_COUNT_4_BIT
        case 8: 8  // VK_SAMPLE_COUNT_8_BIT
        default: nil
        }
    }

    /// Converte uma máscara `VkSampleCountFlags` do dispositivo físico em `CajuSampleCounts`.
    public static func sampleCounts(fromVkMask mask: UInt32) -> CajuSampleCounts {
        var counts: CajuSampleCounts = []
        if mask & 1 != 0 { counts.insert(.x1) }
        if mask & 2 != 0 { counts.insert(.x2) }
        if mask & 4 != 0 { counts.insert(.x4) }
        if mask & 8 != 0 { counts.insert(.x8) }
        return counts
    }

    // MARK: - Erros, memória e SPIR-V

    /// Traduz um `VkResult` de falha para o `CajuRHIError` correspondente do contrato.
    public static func rhiError(fromVkResult code: Int32) -> CajuRHIError {
        switch code {
        case -1, -2:  // VK_ERROR_OUT_OF_HOST_MEMORY, VK_ERROR_OUT_OF_DEVICE_MEMORY
            .outOfMemory
        case -4:  // VK_ERROR_DEVICE_LOST
            .deviceLost
        case -1_000_000_000:  // VK_ERROR_SURFACE_LOST_KHR
            .surfaceLost
        case -1_000_001_004:  // VK_ERROR_OUT_OF_DATE_KHR
            .surfaceOutOfDate
        default:
            .backend(code: code)
        }
    }

    /// Seleciona o primeiro índice de tipo de memória aceito por `typeBits` que contenha `requiredFlags`.
    public static func findMemoryType(
        typeBits: UInt32, memoryPropertyFlags: [UInt32], requiredFlags: UInt32
    ) -> UInt32? {
        for (index, flags) in memoryPropertyFlags.enumerated() where index < 32 {
            let bit = UInt32(1) << UInt32(index)
            if (typeBits & bit) != 0 && (flags & requiredFlags) == requiredFlags {
                return UInt32(index)
            }
        }
        return nil
    }

    /// Valida um `CajuShaderModuleDescriptor` SPIR-V e empacota seus bytes em palavras `UInt32`
    /// alinhadas para `VkShaderModuleCreateInfo.pCode`.
    public static func spirvWords(from descriptor: CajuShaderModuleDescriptor) throws(CajuRHIError)
        -> [UInt32]
    {
        guard !descriptor.code.isEmpty, descriptor.code.count.isMultiple(of: 4) else {
            throw .invalidDescriptor(.missingShader)
        }
        guard descriptor.format == .spirv else {
            throw .invalidDescriptor(.incompatibleUsage)
        }
        let wordCount = descriptor.code.count / 4
        var words = [UInt32]()
        words.reserveCapacity(wordCount)
        for i in 0..<wordCount {
            let base = i * 4
            let b0 = UInt32(descriptor.code[base])
            let b1 = UInt32(descriptor.code[base + 1]) << 8
            let b2 = UInt32(descriptor.code[base + 2]) << 16
            let b3 = UInt32(descriptor.code[base + 3]) << 24
            words.append(b0 | b1 | b2 | b3)
        }
        return words
    }

    // MARK: - Validações puras de descritores

    /// Valida um `CajuBufferDescriptor` contra as capacidades do dispositivo.
    public static func validateBufferDescriptor(
        _ descriptor: CajuBufferDescriptor, capabilities: CajuDeviceCapabilities
    ) throws(CajuRHIError) {
        guard descriptor.size > 0 else { throw .invalidDescriptor(.zeroSize) }
        guard descriptor.size <= capabilities.maxBufferSize else {
            throw .invalidDescriptor(.exceedsDeviceLimit)
        }
        guard !descriptor.usage.isEmpty else { throw .invalidDescriptor(.emptyUsage) }
        guard descriptor.storage != .memoryless else { throw .invalidDescriptor(.incompatibleUsage) }
    }

    /// Valida um `CajuSurfaceDescriptor` para o backend Vulkan Android.
    public static func validateSurfaceDescriptor(
        _ surface: CajuSurfaceDescriptor, capabilities: CajuDeviceCapabilities
    ) throws(CajuRHIError) {
        guard surface.kind == .androidNativeWindow else {
            throw .invalidDescriptor(.incompatibleUsage)
        }
        guard surface.pixelWidth > 0, surface.pixelHeight > 0 else {
            throw .invalidDescriptor(.zeroSize)
        }
        guard surface.pixelWidth <= capabilities.maxTextureDimension2D,
            surface.pixelHeight <= capabilities.maxTextureDimension2D
        else {
            throw .invalidDescriptor(.exceedsDeviceLimit)
        }
        guard capabilities.presentModes.contains(surface.presentMode) else {
            throw .unsupported(.presentMode(surface.presentMode))
        }
        guard surface.nativeHandle != 0 else {
            throw .surfaceLost
        }
    }
}
