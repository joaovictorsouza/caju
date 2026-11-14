import CajuMath

// MARK: - Armazenamento e uso

/// Onde a memória do recurso vive.
public enum CajuStorageMode: UInt8, Sendable, Hashable {
    /// CPU e GPU enxergam a memória (uploads por quadro, uniformes).
    case shared
    /// Só a GPU (geometria e texturas estáticas; upload por cópia).
    case privateGPU
    /// Sem memória de apoio: o conteúdo vive só no *tile memory* durante um passe (ADR 0001).
    /// Só vale para texturas usadas como attachment de um único passe (`TransientAttachment`).
    case memoryless
}

public struct CajuBufferUsage: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let vertex = Self(rawValue: 1 << 0)
    public static let index = Self(rawValue: 1 << 1)
    public static let uniform = Self(rawValue: 1 << 2)
    public static let storage = Self(rawValue: 1 << 3)
    public static let copySource = Self(rawValue: 1 << 4)
    public static let copyDestination = Self(rawValue: 1 << 5)
}

public struct CajuTextureUsage: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let sampled = Self(rawValue: 1 << 0)
    public static let renderTarget = Self(rawValue: 1 << 1)
    public static let storage = Self(rawValue: 1 << 2)
    public static let copySource = Self(rawValue: 1 << 3)
    public static let copyDestination = Self(rawValue: 1 << 4)
}

// MARK: - Buffer, textura, sampler

public struct CajuBufferDescriptor: Sendable, Equatable {
    public var size: Int
    public var usage: CajuBufferUsage
    public var storage: CajuStorageMode
    /// Nome para depuração (capturas de GPU); pode ficar vazio.
    public var label: String

    public init(size: Int, usage: CajuBufferUsage, storage: CajuStorageMode = .shared, label: String = "") {
        self.size = size
        self.usage = usage
        self.storage = storage
        self.label = label
    }
}

public enum CajuTextureDimension: UInt8, Sendable, Hashable {
    case type2D
    case type2DArray
    case cube
    case type3D
}

public struct CajuTextureDescriptor: Sendable, Equatable {
    public var dimension: CajuTextureDimension
    public var format: CajuPixelFormat
    public var width: Int
    public var height: Int
    /// Profundidade (3D) ou número de camadas (array; cubo usa 6 implicitamente).
    public var depthOrLayers: Int
    public var mipLevels: Int
    /// 1 para textura comum; 2, 4 ou 8 para MSAA (só `type2D`, só `renderTarget`).
    public var sampleCount: Int
    public var usage: CajuTextureUsage
    public var storage: CajuStorageMode
    public var label: String

    public init(
        dimension: CajuTextureDimension = .type2D,
        format: CajuPixelFormat,
        width: Int,
        height: Int,
        depthOrLayers: Int = 1,
        mipLevels: Int = 1,
        sampleCount: Int = 1,
        usage: CajuTextureUsage,
        storage: CajuStorageMode = .privateGPU,
        label: String = ""
    ) {
        self.dimension = dimension
        self.format = format
        self.width = width
        self.height = height
        self.depthOrLayers = depthOrLayers
        self.mipLevels = mipLevels
        self.sampleCount = sampleCount
        self.usage = usage
        self.storage = storage
        self.label = label
    }

    /// Bytes estimados de memória de GPU (soma dos mips e amostras); `0` para `memoryless`.
    public var estimatedByteSize: Int {
        guard storage != .memoryless else { return 0 }
        var total = 0
        var w = width
        var h = height
        for _ in 0..<max(mipLevels, 1) {
            total += format.byteSize(width: max(w, 1), height: max(h, 1))
            w = max(w / 2, 1)
            h = max(h / 2, 1)
        }
        return total * max(depthOrLayers, 1) * max(sampleCount, 1)
    }
}

public enum CajuFilterMode: UInt8, Sendable, Hashable {
    case nearest
    case linear
}

public enum CajuAddressMode: UInt8, Sendable, Hashable {
    case clampToEdge
    case `repeat`
    case mirrorRepeat
}

public struct CajuSamplerDescriptor: Sendable, Equatable {
    public var minFilter: CajuFilterMode
    public var magFilter: CajuFilterMode
    public var mipFilter: CajuFilterMode
    public var addressU: CajuAddressMode
    public var addressV: CajuAddressMode
    public var addressW: CajuAddressMode
    /// 1 desliga anisotropia; valores até o limite do dispositivo.
    public var maxAnisotropy: Int

    public init(
        minFilter: CajuFilterMode = .linear,
        magFilter: CajuFilterMode = .linear,
        mipFilter: CajuFilterMode = .linear,
        addressU: CajuAddressMode = .clampToEdge,
        addressV: CajuAddressMode = .clampToEdge,
        addressW: CajuAddressMode = .clampToEdge,
        maxAnisotropy: Int = 1
    ) {
        self.minFilter = minFilter
        self.magFilter = magFilter
        self.mipFilter = mipFilter
        self.addressU = addressU
        self.addressV = addressV
        self.addressW = addressW
        self.maxAnisotropy = maxAnisotropy
    }
}

// MARK: - Shaders

/// Formato do código de shader compilado offline (Slang → MSL/SPIR-V; sem compilador em runtime).
public enum CajuShaderCodeFormat: UInt8, Sendable, Hashable {
    /// Biblioteca Metal pré-compilada (`.metallib`).
    case metalLibrary
    /// Código-fonte MSL (compilado na carga pelo driver; só para desenvolvimento e testes).
    case metalSource
    /// SPIR-V (Vulkan).
    case spirv
}

public struct CajuShaderModuleDescriptor: Sendable, Equatable {
    public var format: CajuShaderCodeFormat
    public var code: [UInt8]
    public var label: String

    public init(format: CajuShaderCodeFormat, code: [UInt8], label: String = "") {
        self.format = format
        self.code = code
        self.label = label
    }
}

/// Função de entrada dentro de um módulo de shader.
public struct CajuShaderFunction: Sendable, Equatable {
    public var module: CajuShaderHandle
    public var entryPoint: String

    public init(module: CajuShaderHandle, entryPoint: String) {
        self.module = module
        self.entryPoint = entryPoint
    }
}

// MARK: - Pipelines

public enum CajuVertexFormat: UInt8, Sendable, Hashable {
    case float, float2, float3, float4
    case uint, uint2, uint3, uint4
    case unorm8x4
    case half2, half4

    public var byteSize: Int {
        switch self {
        case .float, .uint, .unorm8x4, .half2: 4
        case .float2, .uint2, .half4: 8
        case .float3, .uint3: 12
        case .float4, .uint4: 16
        }
    }
}

public enum CajuVertexStepFunction: UInt8, Sendable, Hashable {
    case perVertex
    case perInstance
}

public struct CajuVertexAttribute: Sendable, Equatable {
    /// Posição do atributo no shader (`[[attribute(n)]]` / `location = n`).
    public var location: Int
    public var format: CajuVertexFormat
    public var offset: Int
    /// Índice da tabela de buffers de vértice (`setVertexBuffer(index:)`).
    public var bufferIndex: Int

    public init(location: Int, format: CajuVertexFormat, offset: Int, bufferIndex: Int) {
        self.location = location
        self.format = format
        self.offset = offset
        self.bufferIndex = bufferIndex
    }
}

public struct CajuVertexBufferLayout: Sendable, Equatable {
    public var bufferIndex: Int
    public var stride: Int
    public var step: CajuVertexStepFunction

    public init(bufferIndex: Int, stride: Int, step: CajuVertexStepFunction = .perVertex) {
        self.bufferIndex = bufferIndex
        self.stride = stride
        self.step = step
    }
}

public enum CajuPrimitiveTopology: UInt8, Sendable, Hashable {
    case triangleList
    case triangleStrip
    case lineList
    case pointList
}

public enum CajuCullMode: UInt8, Sendable, Hashable {
    case none, front, back
}

public enum CajuWinding: UInt8, Sendable, Hashable {
    case clockwise, counterClockwise
}

public enum CajuCompareFunction: UInt8, Sendable, Hashable {
    case never, less, equal, lessEqual, greater, notEqual, greaterEqual, always
}

public enum CajuBlendFactor: UInt8, Sendable, Hashable {
    case zero, one, sourceAlpha, oneMinusSourceAlpha, destinationAlpha, oneMinusDestinationAlpha
}

public enum CajuBlendOperation: UInt8, Sendable, Hashable {
    case add, subtract, reverseSubtract, min, max
}

public struct CajuBlendState: Sendable, Equatable {
    public var sourceColor: CajuBlendFactor
    public var destinationColor: CajuBlendFactor
    public var colorOperation: CajuBlendOperation
    public var sourceAlpha: CajuBlendFactor
    public var destinationAlpha: CajuBlendFactor
    public var alphaOperation: CajuBlendOperation

    public init(
        sourceColor: CajuBlendFactor,
        destinationColor: CajuBlendFactor,
        colorOperation: CajuBlendOperation = .add,
        sourceAlpha: CajuBlendFactor,
        destinationAlpha: CajuBlendFactor,
        alphaOperation: CajuBlendOperation = .add
    ) {
        self.sourceColor = sourceColor
        self.destinationColor = destinationColor
        self.colorOperation = colorOperation
        self.sourceAlpha = sourceAlpha
        self.destinationAlpha = destinationAlpha
        self.alphaOperation = alphaOperation
    }

    /// Mistura alfa padrão (não pré-multiplicada).
    public static let alpha = CajuBlendState(
        sourceColor: .sourceAlpha, destinationColor: .oneMinusSourceAlpha,
        sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha)

    /// Mistura alfa pré-multiplicada.
    public static let premultipliedAlpha = CajuBlendState(
        sourceColor: .one, destinationColor: .oneMinusSourceAlpha,
        sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha)
}

public struct CajuColorTargetState: Sendable, Equatable {
    public var format: CajuPixelFormat
    /// `nil` = sem mistura (escreve direto).
    public var blend: CajuBlendState?
    public var writesAllChannels: Bool

    public init(format: CajuPixelFormat, blend: CajuBlendState? = nil, writesAllChannels: Bool = true) {
        self.format = format
        self.blend = blend
        self.writesAllChannels = writesAllChannels
    }
}

public struct CajuDepthState: Sendable, Equatable {
    public var format: CajuPixelFormat
    public var compare: CajuCompareFunction
    public var writesDepth: Bool

    public init(format: CajuPixelFormat, compare: CajuCompareFunction = .less, writesDepth: Bool = true) {
        self.format = format
        self.compare = compare
        self.writesDepth = writesDepth
    }
}

/// Descrição completa de um pipeline gráfico (estado imutável, estilo Vulkan).
///
/// O estado de profundidade, as máscaras de cor e o número de amostras fazem parte do pipeline,
/// o que permite pré-compilar e guardar em cache (PSO persistido) sem travadas no quadro.
public struct CajuRenderPipelineDescriptor: Sendable, Equatable {
    public var vertex: CajuShaderFunction
    /// `nil` para passes só de profundidade.
    public var fragment: CajuShaderFunction?
    public var vertexAttributes: [CajuVertexAttribute]
    public var vertexLayouts: [CajuVertexBufferLayout]
    public var colorTargets: [CajuColorTargetState]
    public var depth: CajuDepthState?
    public var topology: CajuPrimitiveTopology
    public var cullMode: CajuCullMode
    public var frontFace: CajuWinding
    /// Deve coincidir com o `sampleCount` dos attachments do passe onde o pipeline é usado.
    public var sampleCount: Int
    public var label: String

    public init(
        vertex: CajuShaderFunction,
        fragment: CajuShaderFunction?,
        vertexAttributes: [CajuVertexAttribute] = [],
        vertexLayouts: [CajuVertexBufferLayout] = [],
        colorTargets: [CajuColorTargetState],
        depth: CajuDepthState? = nil,
        topology: CajuPrimitiveTopology = .triangleList,
        cullMode: CajuCullMode = .back,
        frontFace: CajuWinding = .counterClockwise,
        sampleCount: Int = 1,
        label: String = ""
    ) {
        self.vertex = vertex
        self.fragment = fragment
        self.vertexAttributes = vertexAttributes
        self.vertexLayouts = vertexLayouts
        self.colorTargets = colorTargets
        self.depth = depth
        self.topology = topology
        self.cullMode = cullMode
        self.frontFace = frontFace
        self.sampleCount = sampleCount
        self.label = label
    }
}

public struct CajuComputePipelineDescriptor: Sendable, Equatable {
    public var function: CajuShaderFunction
    public var label: String

    public init(function: CajuShaderFunction, label: String = "") {
        self.function = function
        self.label = label
    }
}

public enum CajuIndexType: UInt8, Sendable, Hashable {
    case uint16, uint32

    public var byteSize: Int { self == .uint16 ? 2 : 4 }
}

// MARK: - Render pass

public enum CajuLoadAction: Sendable, Equatable {
    /// Preserva o conteúdo anterior (custa leitura de memória: evite em mobile).
    case load
    /// Limpa com o valor (cor RGBA ou profundidade em `x`).
    case clear(SIMD4<Float>)
    /// Conteúdo anterior irrelevante (o mais barato).
    case dontCare
}

public enum CajuStoreAction: Sendable, Equatable {
    /// Grava o conteúdo na memória.
    case store
    /// Descarta (o mais barato; obrigatório em `TransientAttachment`).
    case dontCare
    /// Resolve MSAA para a textura de destino e descarta a textura multiamostrada.
    case resolve
    /// Resolve para a textura de destino e também grava a multiamostrada.
    case storeAndResolve
}

/// Textura de um attachment: uma textura concreta ou um recurso do *frame graph*
/// (`TransientAttachment` quando é transiente).
public enum CajuAttachmentTexture: Sendable, Equatable {
    /// Textura criada pelo usuário ou imagem do *swapchain* do quadro.
    case texture(CajuTextureHandle)
    /// Recurso do *frame graph* (transiente ou importado), resolvido para uma textura na execução.
    case resource(CajuFrameGraphResource)
}

public struct CajuColorAttachment: Sendable, Equatable {
    public var texture: CajuAttachmentTexture
    public var mipLevel: Int
    public var slice: Int
    public var load: CajuLoadAction
    public var store: CajuStoreAction
    /// Destino do *resolve* (textura de 1 amostra); obrigatório com `.resolve`/`.storeAndResolve`.
    public var resolveTexture: CajuAttachmentTexture?

    public init(
        texture: CajuAttachmentTexture,
        mipLevel: Int = 0,
        slice: Int = 0,
        load: CajuLoadAction = .clear(SIMD4(0, 0, 0, 1)),
        store: CajuStoreAction = .store,
        resolveTexture: CajuAttachmentTexture? = nil
    ) {
        self.texture = texture
        self.mipLevel = mipLevel
        self.slice = slice
        self.load = load
        self.store = store
        self.resolveTexture = resolveTexture
    }
}

public struct CajuDepthAttachment: Sendable, Equatable {
    public var texture: CajuAttachmentTexture
    public var load: CajuLoadAction
    public var store: CajuStoreAction

    public init(
        texture: CajuAttachmentTexture,
        load: CajuLoadAction = .clear(SIMD4(1, 0, 0, 0)),
        store: CajuStoreAction = .dontCare
    ) {
        self.texture = texture
        self.load = load
        self.store = store
    }
}

/// Descrição de um passe de render: attachments com operações de carga e armazenamento.
public struct CajuRenderPassDescriptor: Sendable, Equatable {
    public var colorAttachments: [CajuColorAttachment]
    public var depthAttachment: CajuDepthAttachment?
    public var label: String

    public init(
        colorAttachments: [CajuColorAttachment],
        depthAttachment: CajuDepthAttachment? = nil,
        label: String = ""
    ) {
        self.colorAttachments = colorAttachments
        self.depthAttachment = depthAttachment
        self.label = label
    }
}

public struct CajuViewport: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float
    public var near: Float
    public var far: Float

    public init(x: Float = 0, y: Float = 0, width: Float, height: Float, near: Float = 0, far: Float = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.near = near
        self.far = far
    }
}

public struct CajuScissorRect: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
