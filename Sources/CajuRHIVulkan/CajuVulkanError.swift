/// Etapa do backend Vulkan em que um erro ocorreu.
public enum CajuVulkanStep: UInt8, Sendable {
    case loader, instance, surface, enumerateDevices, device, swapchain, imageViews
    case renderPass, shaderModule, pipelineLayout, pipeline, framebuffer
    case commandPool, commandBuffer, synchronization
    case acquire, submit, present, record
}

/// Erros tipados do backend Vulkan (sem `fatalError`; ADR 0009).
public enum CajuVulkanError: Error, Equatable, Sendable {
    /// Uma chamada Vulkan devolveu `VkResult` diferente de `VK_SUCCESS`.
    case vulkan(step: CajuVulkanStep, code: Int32)
    /// Nenhum dispositivo físico tem fila gráfica com suporte a apresentação.
    case noSuitableDevice
    /// O sistema não ofereceu nenhum formato de superfície.
    case noSurfaceFormat
}
