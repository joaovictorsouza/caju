#if os(Android)
    import CVulkan
    import CajuRHI

    extension CajuPixelFormat {
        var vulkan: VkFormat {
            switch self {
            case .r8Unorm: VK_FORMAT_R8_UNORM
            case .rg8Unorm: VK_FORMAT_R8G8_UNORM
            case .rgba8Unorm: VK_FORMAT_R8G8B8A8_UNORM
            case .rgba8UnormSRGB: VK_FORMAT_R8G8B8A8_SRGB
            case .bgra8Unorm: VK_FORMAT_B8G8R8A8_UNORM
            case .bgra8UnormSRGB: VK_FORMAT_B8G8R8A8_SRGB
            case .rgba16Float: VK_FORMAT_R16G16B16A16_SFLOAT
            case .r32Float: VK_FORMAT_R32_SFLOAT
            case .rgb10a2Unorm: VK_FORMAT_A2B10G10R10_UNORM_PACK32
            case .depth16Unorm: VK_FORMAT_D16_UNORM
            case .depth32Float: VK_FORMAT_D32_SFLOAT
            case .depth32FloatStencil8: VK_FORMAT_D32_SFLOAT_S8_UINT
            case .astc4x4: VK_FORMAT_ASTC_4x4_UNORM_BLOCK
            case .astc4x4SRGB: VK_FORMAT_ASTC_4x4_SRGB_BLOCK
            case .astc5x5: VK_FORMAT_ASTC_5x5_UNORM_BLOCK
            case .astc5x5SRGB: VK_FORMAT_ASTC_5x5_SRGB_BLOCK
            case .astc6x6: VK_FORMAT_ASTC_6x6_UNORM_BLOCK
            case .astc6x6SRGB: VK_FORMAT_ASTC_6x6_SRGB_BLOCK
            case .astc8x8: VK_FORMAT_ASTC_8x8_UNORM_BLOCK
            case .astc8x8SRGB: VK_FORMAT_ASTC_8x8_SRGB_BLOCK
            }
        }

        /// Aspectos da imagem (cor, ou profundidade com estêncil quando houver).
        var vulkanAspect: VkImageAspectFlags {
            if hasStencil {
                return VkImageAspectFlags(
                    VK_IMAGE_ASPECT_DEPTH_BIT.rawValue | VK_IMAGE_ASPECT_STENCIL_BIT.rawValue)
            }
            return VkImageAspectFlags(
                (isDepth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT).rawValue)
        }
    }

    extension CajuFilterMode {
        var vulkan: VkFilter { self == .nearest ? VK_FILTER_NEAREST : VK_FILTER_LINEAR }
        var vulkanMip: VkSamplerMipmapMode {
            self == .nearest ? VK_SAMPLER_MIPMAP_MODE_NEAREST : VK_SAMPLER_MIPMAP_MODE_LINEAR
        }
    }

    extension CajuAddressMode {
        var vulkan: VkSamplerAddressMode {
            switch self {
            case .clampToEdge: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
            case .repeat: VK_SAMPLER_ADDRESS_MODE_REPEAT
            case .mirrorRepeat: VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT
            }
        }
    }

    extension CajuSampleCounts {
        /// Máscara `VkSampleCountFlags` (bit `n` = `1 << n` amostras, igual ao Vulkan).
        init(vulkan flags: VkSampleCountFlags) {
            var counts: CajuSampleCounts = []
            if flags & VK_SAMPLE_COUNT_1_BIT.rawValue != 0 { counts.insert(.x1) }
            if flags & VK_SAMPLE_COUNT_2_BIT.rawValue != 0 { counts.insert(.x2) }
            if flags & VK_SAMPLE_COUNT_4_BIT.rawValue != 0 { counts.insert(.x4) }
            if flags & VK_SAMPLE_COUNT_8_BIT.rawValue != 0 { counts.insert(.x8) }
            self = counts
        }
    }

    func vulkanSampleCount(_ count: Int) -> VkSampleCountFlagBits {
        switch count {
        case 2: VK_SAMPLE_COUNT_2_BIT
        case 4: VK_SAMPLE_COUNT_4_BIT
        case 8: VK_SAMPLE_COUNT_8_BIT
        default: VK_SAMPLE_COUNT_1_BIT
        }
    }
#endif
