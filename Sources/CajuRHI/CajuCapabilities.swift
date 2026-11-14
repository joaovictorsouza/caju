/// Capacidades e limites de um dispositivo de GPU, consultados uma vez na criação.
public struct CajuDeviceCapabilities: Sendable, Equatable {
    /// API nativa: `"Metal"`, `"Vulkan"` ou `"Null"`.
    public var backendName: String
    public var deviceName: String
    public var maxTextureDimension2D: Int
    public var maxColorAttachments: Int
    public var maxVertexBuffers: Int
    public var maxBufferSize: Int
    public var maxAnisotropy: Int
    /// Alinhamento de *offsets* em buffers de uniforme.
    public var uniformBufferAlignment: Int
    public var sampleCounts: CajuSampleCounts
    /// Texturas `memoryless` (TBDR: Apple, Adreno/Mali com extensão).
    public var supportsMemoryless: Bool
    public var supportsCompute: Bool
    /// ASTC LDR (todos os iPhones recentes e a maioria dos Androids).
    public var supportsASTC: Bool
    public var presentModes: [CajuPresentMode]

    public init(
        backendName: String,
        deviceName: String,
        maxTextureDimension2D: Int = 8192,
        maxColorAttachments: Int = 4,
        maxVertexBuffers: Int = 8,
        maxBufferSize: Int = 256 << 20,
        maxAnisotropy: Int = 16,
        uniformBufferAlignment: Int = 256,
        sampleCounts: CajuSampleCounts = [.x1, .x4],
        supportsMemoryless: Bool = true,
        supportsCompute: Bool = true,
        supportsASTC: Bool = true,
        presentModes: [CajuPresentMode] = [.fifo]
    ) {
        self.backendName = backendName
        self.deviceName = deviceName
        self.maxTextureDimension2D = maxTextureDimension2D
        self.maxColorAttachments = maxColorAttachments
        self.maxVertexBuffers = maxVertexBuffers
        self.maxBufferSize = maxBufferSize
        self.maxAnisotropy = maxAnisotropy
        self.uniformBufferAlignment = uniformBufferAlignment
        self.sampleCounts = sampleCounts
        self.supportsMemoryless = supportsMemoryless
        self.supportsCompute = supportsCompute
        self.supportsASTC = supportsASTC
        self.presentModes = presentModes
    }

    /// `true` se o dispositivo cria texturas deste formato.
    public func supports(_ format: CajuPixelFormat) -> Bool {
        format.isCompressed ? supportsASTC : true
    }
}
