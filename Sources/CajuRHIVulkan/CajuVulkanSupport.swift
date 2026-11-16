#if os(Android)
    import CVulkan
    import CajuRHI

    /// Código de `CajuRHIError.backend(code:)` devolvido por recursos ainda não implementados pelo backend
    /// (fatias V-1 seguintes). Fora da faixa dos `VkResult`.
    public let cajuVulkanNotImplementedCode: Int32 = -1_000_000

    /// Ponteiro C estático de um literal (sem alocar).
    func vkName(_ string: StaticString) -> UnsafePointer<CChar> {
        UnsafeRawPointer(string.utf8Start).assumingMemoryBound(to: CChar.self)
    }

    /// `VkResult` → erro do contrato do RHI (ADR 0015).
    func mapVkResult(_ result: VkResult) -> CajuRHIError {
        switch result {
        case VK_ERROR_OUT_OF_HOST_MEMORY, VK_ERROR_OUT_OF_DEVICE_MEMORY, VK_ERROR_OUT_OF_POOL_MEMORY,
            VK_ERROR_FRAGMENTED_POOL, VK_ERROR_MEMORY_MAP_FAILED:
            return .outOfMemory
        case VK_ERROR_DEVICE_LOST: return .deviceLost
        case VK_ERROR_SURFACE_LOST_KHR: return .surfaceLost
        case VK_ERROR_OUT_OF_DATE_KHR: return .surfaceOutOfDate
        default: return .backend(code: result.rawValue)
        }
    }

    @inline(__always)
    func vkCheck(_ result: VkResult) throws(CajuRHIError) {
        if result != VK_SUCCESS { throw mapVkResult(result) }
    }

    /// `VK_MAKE_API_VERSION(0, 1, 1, 0)`.
    let vulkan11: UInt32 = (1 << 22) | (1 << 12)

    @inline(__always)
    func vkFlags(_ bits: VkImageUsageFlagBits...) -> VkImageUsageFlags {
        bits.reduce(0) { $0 | VkImageUsageFlags($1.rawValue) }
    }
#endif
