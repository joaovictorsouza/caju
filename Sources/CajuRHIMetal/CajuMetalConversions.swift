#if canImport(Metal)
    import CajuRHI
    import Metal

    // Conversões entre o contrato do RHI e a API Metal.

    extension CajuPixelFormat {
        var metal: MTLPixelFormat {
            switch self {
            case .r8Unorm: .r8Unorm
            case .rg8Unorm: .rg8Unorm
            case .rgba8Unorm: .rgba8Unorm
            case .rgba8UnormSRGB: .rgba8Unorm_srgb
            case .bgra8Unorm: .bgra8Unorm
            case .bgra8UnormSRGB: .bgra8Unorm_srgb
            case .rgba16Float: .rgba16Float
            case .r32Float: .r32Float
            case .rgb10a2Unorm: .rgb10a2Unorm
            case .depth16Unorm: .depth16Unorm
            case .depth32Float: .depth32Float
            case .depth32FloatStencil8: .depth32Float_stencil8
            case .astc4x4: .astc_4x4_ldr
            case .astc4x4SRGB: .astc_4x4_srgb
            case .astc5x5: .astc_5x5_ldr
            case .astc5x5SRGB: .astc_5x5_srgb
            case .astc6x6: .astc_6x6_ldr
            case .astc6x6SRGB: .astc_6x6_srgb
            case .astc8x8: .astc_8x8_ldr
            case .astc8x8SRGB: .astc_8x8_srgb
            }
        }
    }

    extension CajuVertexFormat {
        var metal: MTLVertexFormat {
            switch self {
            case .float: .float
            case .float2: .float2
            case .float3: .float3
            case .float4: .float4
            case .uint: .uint
            case .uint2: .uint2
            case .uint3: .uint3
            case .uint4: .uint4
            case .unorm8x4: .uchar4Normalized
            case .half2: .half2
            case .half4: .half4
            }
        }
    }

    extension CajuCompareFunction {
        var metal: MTLCompareFunction {
            switch self {
            case .never: .never
            case .less: .less
            case .equal: .equal
            case .lessEqual: .lessEqual
            case .greater: .greater
            case .notEqual: .notEqual
            case .greaterEqual: .greaterEqual
            case .always: .always
            }
        }
    }

    extension CajuBlendFactor {
        var metal: MTLBlendFactor {
            switch self {
            case .zero: .zero
            case .one: .one
            case .sourceAlpha: .sourceAlpha
            case .oneMinusSourceAlpha: .oneMinusSourceAlpha
            case .destinationAlpha: .destinationAlpha
            case .oneMinusDestinationAlpha: .oneMinusDestinationAlpha
            }
        }
    }

    extension CajuBlendOperation {
        var metal: MTLBlendOperation {
            switch self {
            case .add: .add
            case .subtract: .subtract
            case .reverseSubtract: .reverseSubtract
            case .min: .min
            case .max: .max
            }
        }
    }

    extension CajuPrimitiveTopology {
        var metal: MTLPrimitiveType {
            switch self {
            case .triangleList: .triangle
            case .triangleStrip: .triangleStrip
            case .lineList: .line
            case .pointList: .point
            }
        }

        var metalClass: MTLPrimitiveTopologyClass {
            switch self {
            case .triangleList, .triangleStrip: .triangle
            case .lineList: .line
            case .pointList: .point
            }
        }
    }

    extension CajuFilterMode {
        var metal: MTLSamplerMinMagFilter { self == .nearest ? .nearest : .linear }
        var metalMip: MTLSamplerMipFilter { self == .nearest ? .nearest : .linear }
    }

    extension CajuAddressMode {
        var metal: MTLSamplerAddressMode {
            switch self {
            case .clampToEdge: .clampToEdge
            case .repeat: .repeat
            case .mirrorRepeat: .mirrorRepeat
            }
        }
    }

    extension CajuLoadAction {
        var metal: MTLLoadAction {
            switch self {
            case .load: .load
            case .clear: .clear
            case .dontCare: .dontCare
            }
        }
    }

    extension CajuStoreAction {
        var metal: MTLStoreAction {
            switch self {
            case .store: .store
            case .dontCare: .dontCare
            case .resolve: .multisampleResolve
            case .storeAndResolve: .storeAndMultisampleResolve
            }
        }
    }

    extension CajuBufferUsage {
        /// Índice da tabela de buffers de vértice do Metal para o fluxo `i`: `30 - i` (ver `setVertexBuffer`).
        static func metalVertexSlot(_ stream: Int) -> Int { 30 - stream }
    }

    extension MTLSize {
        init(_ w: Int, _ h: Int, _ d: Int) { self.init(width: w, height: h, depth: d) }
    }
#endif
