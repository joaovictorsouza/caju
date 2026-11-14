/// Escolhas puras (sem Vulkan) para criar a swapchain; testáveis no host.
///
/// Os valores numéricos de formato/espaço de cor seguem a especificação Vulkan
/// (`VkFormat`, `VkColorSpaceKHR`).
public enum CajuVulkanSwapchainPlan {
    /// `VkSurfaceCapabilitiesKHR::currentExtent == 0xFFFFFFFF` significa "o app decide".
    public static let undefinedExtent: UInt32 = .max

    public struct Extent: Equatable, Sendable {
        public var width: UInt32
        public var height: UInt32
        public init(width: UInt32, height: UInt32) {
            self.width = width
            self.height = height
        }
        /// Superfície minimizada/sem área (largura ou altura zero): não dá para desenhar.
        public var isEmpty: Bool { width == 0 || height == 0 }
    }

    public struct SurfaceFormat: Equatable, Sendable {
        public var format: UInt32
        public var colorSpace: UInt32
        public init(format: UInt32, colorSpace: UInt32) {
            self.format = format
            self.colorSpace = colorSpace
        }
    }

    /// `minImageCount + 1` (para não esperar o driver), limitado a `maxImageCount` (0 = sem limite).
    public static func imageCount(min: UInt32, max: UInt32) -> UInt32 {
        let wanted = min &+ 1
        return max == 0 ? wanted : Swift.min(wanted, max)
    }

    /// Usa `current` quando definido; senão limita `fallback` ao intervalo aceito.
    public static func extent(
        current: Extent, minimum: Extent, maximum: Extent, fallback: Extent
    ) -> Extent {
        if current.width != undefinedExtent && current.height != undefinedExtent { return current }
        return Extent(
            width: Swift.min(Swift.max(fallback.width, minimum.width), maximum.width),
            height: Swift.min(Swift.max(fallback.height, minimum.height), maximum.height))
    }

    /// Prefere B8G8R8A8_SRGB, depois R8G8B8A8_SRGB (cor linear no shader, sRGB na tela);
    /// senão o primeiro. `nil` se a lista é vazia.
    public static func chooseFormat(_ formats: [SurfaceFormat]) -> SurfaceFormat? {
        let srgbNonlinear: UInt32 = 0
        let preferred: [UInt32] = [50, 43]  // B8G8R8A8_SRGB, R8G8B8A8_SRGB
        for format in preferred {
            if let match = formats.first(where: { $0.format == format && $0.colorSpace == srgbNonlinear }) {
                return match
            }
        }
        return formats.first
    }

    /// Prefere `preferredFormat` (primeiro em espaço sRGB não linear, depois em qualquer espaço);
    /// se indisponível na superfície, cai na ordem padrão de `chooseFormat(_:)`.
    public static func chooseFormat(
        _ formats: [SurfaceFormat], preferredFormat: UInt32
    ) -> SurfaceFormat? {
        let srgbNonlinear: UInt32 = 0
        if let match = formats.first(where: {
            $0.format == preferredFormat && $0.colorSpace == srgbNonlinear
        }) {
            return match
        }
        if let match = formats.first(where: { $0.format == preferredFormat }) {
            return match
        }
        return chooseFormat(formats)
    }
}
