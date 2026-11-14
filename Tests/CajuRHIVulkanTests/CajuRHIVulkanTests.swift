import Testing

@testable import CajuRHIVulkan

@Test func moduleMarkerExists() {
    _ = CajuRHIVulkanModule.self
}
