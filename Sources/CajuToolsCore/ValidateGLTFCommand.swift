import Foundation

#if canImport(Darwin)
    import CoreFoundation
#endif

/// Resumo de um documento glTF 2.0 ou GLB validado.
public struct GLTFValidationSummary: Sendable, Equatable {
    public let format: String
    public let version: String
    public let scenes: Int
    public let nodes: Int
    public let meshes: Int
    public let materials: Int
    public let textures: Int
    public let images: Int
    public let accessors: Int
    public let bufferViews: Int
    public let buffers: Int
}

/// Validador estrito de arquivos glTF 2.0 (`.gltf`) e GLB v2 (`.glb`) usando `Foundation`.
public enum GLTFValidator {
    private static let glbMagic: UInt32 = 0x4654_6C67  // "glTF"
    private static let glbChunkJSON: UInt32 = 0x4E4F_534A  // "JSON"
    private static let glbChunkBIN: UInt32 = 0x004E_4942  // "BIN\0"

    /// Valida estrutura, limites, accessors/bufferViews e referências cruzadas de um glTF/GLB.
    public static func validate(
        _ bytes: [UInt8],
        limits: ToolsLimits = .default
    ) throws(CajuToolsError) -> GLTFValidationSummary {
        try checkLimit(bytes.count, limits.maxInputBytes, "gltf.input")
        guard !bytes.isEmpty else {
            throw .truncated(context: "gltf")
        }

        let isGLB = isGLBHeader(bytes)
        let jsonSlice: Range<Int>
        let glbBinaryLength: Int?

        if isGLB {
            let glb = try parseGLBContainer(bytes)
            jsonSlice = glb.jsonRange
            glbBinaryLength = glb.binRange?.count
        } else {
            jsonSlice = 0..<bytes.count
            glbBinaryLength = nil
        }

        try prevalidateJSONDepthAndUTF8(bytes, range: jsonSlice, maxDepth: limits.maxJSONDepth)

        let jsonData = Data(bytes[jsonSlice])
        let parsedAny: Any
        do {
            parsedAny = try JSONSerialization.jsonObject(with: jsonData, options: [])
        } catch {
            throw .invalid(context: "gltf.json", reason: "JSON inválido: \(error.localizedDescription)")
        }

        guard let root = parsedAny as? [String: Any] else {
            throw .invalid(context: "gltf", reason: "raiz glTF deve ser um objeto JSON")
        }

        let version = try parseAsset(root["asset"])
        let buffers = try parseBuffers(root["buffers"], limits: limits)

        if isGLB {
            if let binLen = glbBinaryLength {
                guard !buffers.isEmpty else {
                    throw .invalid(context: "buffers", reason: "chunk BIN presente sem buffer 0")
                }
                if buffers[0].uri != nil {
                    throw .invalid(context: "buffers[0].uri", reason: "buffer 0 em GLB não pode ter uri")
                }
                guard buffers[0].byteLength <= binLen else {
                    throw .invalid(
                        context: "buffers[0].byteLength",
                        reason: "buffer 0 excede tamanho do chunk BIN"
                    )
                }
            } else if !buffers.isEmpty, buffers[0].uri == nil {
                throw .invalid(
                    context: "buffers[0].uri",
                    reason: "buffer 0 sem uri exige chunk BIN no GLB"
                )
            }
        }

        let bufferViews = try parseBufferViews(root["bufferViews"], buffers: buffers, limits: limits)
        let accessors = try parseAccessors(root["accessors"], bufferViews: bufferViews, limits: limits)
        let samplerCount = try parseObjectArrayCount(root["samplers"], context: "samplers", limits: limits)
        let imageCount = try parseObjectArrayCount(root["images"], context: "images", limits: limits)
        let textureCount = try parseTextures(
            root["textures"],
            samplerCount: samplerCount,
            imageCount: imageCount,
            limits: limits
        )
        let materialCount = try parseMaterials(
            root["materials"],
            textureCount: textureCount,
            limits: limits
        )
        let cameraCount = try parseObjectArrayCount(root["cameras"], context: "cameras", limits: limits)
        let meshes = try parseMeshes(
            root["meshes"],
            accessors: accessors,
            materialCount: materialCount,
            limits: limits
        )
        let nodeCountPreliminary = try countNodes(root["nodes"], limits: limits)
        let skinCount = try parseSkins(
            root["skins"],
            accessors: accessors,
            nodeCount: nodeCountPreliminary,
            limits: limits
        )
        let parentCounts = try parseNodes(
            root["nodes"],
            meshCount: meshes.count,
            cameraCount: cameraCount,
            skinCount: skinCount,
            limits: limits
        )
        let sceneCount = try parseScenes(
            root["scenes"],
            nodeCount: parentCounts.count,
            parentCounts: parentCounts,
            limits: limits
        )

        if let sceneAny = root["scene"] {
            let sceneIdx = try requireInt(sceneAny, context: "scene")
            guard sceneIdx >= 0, sceneIdx < sceneCount else {
                throw .invalid(context: "scene", reason: "índice de cena padrão fora da faixa")
            }
        }

        return GLTFValidationSummary(
            format: isGLB ? "glb" : "gltf",
            version: version,
            scenes: sceneCount,
            nodes: parentCounts.count,
            meshes: meshes.count,
            materials: materialCount,
            textures: textureCount,
            images: imageCount,
            accessors: accessors.count,
            bufferViews: bufferViews.count,
            buffers: buffers.count
        )
    }

    // MARK: - GLB e pré-validação de JSON

    private static func isGLBHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let magic =
            UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return magic == glbMagic
    }

    private static func parseGLBContainer(
        _ bytes: [UInt8]
    ) throws(CajuToolsError) -> (jsonRange: Range<Int>, binRange: Range<Int>?) {
        guard bytes.count >= 12 else {
            throw .truncated(context: "glb.header")
        }
        var reader = ToolsByteReader(bytes)
        let magic = try reader.readU32LE("glb.magic")
        guard magic == glbMagic else {
            throw .invalid(context: "glb.magic", reason: "assinatura GLB inválida")
        }
        let version = try reader.readU32LE("glb.version")
        guard version == 2 else {
            throw .invalid(context: "glb.version", reason: "versão GLB \(version) não é 2")
        }
        let lengthU32 = try reader.readU32LE("glb.length")
        guard let totalLength = Int(exactly: lengthU32), totalLength >= 12 else {
            throw .invalid(context: "glb.length", reason: "comprimento GLB inválido")
        }
        guard totalLength % 4 == 0 else {
            throw .invalid(context: "glb.length", reason: "comprimento GLB não alinhado em 4 bytes")
        }
        guard totalLength <= bytes.count else {
            throw .truncated(context: "glb.length")
        }
        guard totalLength == bytes.count else {
            throw .invalid(context: "glb.length", reason: "bytes excedentes após o fim do GLB")
        }

        var jsonRange: Range<Int>?
        var binRange: Range<Int>?
        var chunkIndex = 0

        while reader.offset < totalLength {
            let ctx = "glb.chunks[\(chunkIndex)]"
            guard totalLength - reader.offset >= 8 else {
                throw .truncated(context: ctx)
            }
            let chunkLenU32 = try reader.readU32LE("\(ctx).length")
            let chunkType = try reader.readU32LE("\(ctx).type")
            guard let chunkLen = Int(exactly: chunkLenU32) else {
                throw .invalid(context: "\(ctx).length", reason: "tamanho de chunk excede Int")
            }
            guard chunkLen % 4 == 0 else {
                throw .invalid(context: "\(ctx).length", reason: "comprimento de chunk não múltiplo de 4")
            }
            let payloadEnd = try checkedAdd(reader.offset, chunkLen, "\(ctx).length")
            guard payloadEnd <= totalLength else {
                throw .truncated(context: "\(ctx).data")
            }

            if chunkIndex == 0 {
                guard chunkType == glbChunkJSON else {
                    throw .invalid(context: "\(ctx).type", reason: "primeiro chunk GLB deve ser JSON")
                }
                guard chunkLen > 0 else {
                    throw .invalid(context: "\(ctx).length", reason: "chunk JSON vazio")
                }
                jsonRange = reader.offset..<payloadEnd
            } else if chunkType == glbChunkJSON {
                throw .invalid(context: "\(ctx).type", reason: "múltiplos chunks JSON no GLB")
            } else if chunkType == glbChunkBIN {
                guard binRange == nil else {
                    throw .invalid(context: "\(ctx).type", reason: "múltiplos chunks BIN no GLB")
                }
                binRange = reader.offset..<payloadEnd
            }

            try reader.seek(to: payloadEnd, context: "\(ctx).data")
            chunkIndex += 1
        }

        guard let resolvedJSON = jsonRange else {
            throw .invalid(context: "glb.chunks", reason: "chunk JSON ausente")
        }
        return (resolvedJSON, binRange)
    }

    /// Garante UTF-8 válido e limita profundidade antes do `JSONSerialization` para evitar estouro de pilha.
    private static func prevalidateJSONDepthAndUTF8(
        _ bytes: [UInt8],
        range: Range<Int>,
        maxDepth: Int
    ) throws(CajuToolsError) {
        let slice = bytes[range]
        let decoded = String(decoding: slice, as: UTF8.self)
        guard decoded.utf8.elementsEqual(slice) else {
            throw .invalid(context: "gltf.json", reason: "bytes UTF-8 inválidos no JSON")
        }

        var depth = 0
        var inString = false
        var escaped = false
        for b in slice {
            if inString {
                if escaped {
                    escaped = false
                } else if b == 0x5C {  // '\\'
                    escaped = true
                } else if b == 0x22 {  // '"'
                    inString = false
                }
            } else {
                switch b {
                case 0x22:
                    inString = true
                case 0x5B, 0x7B:  // '[' ou '{'
                    depth += 1
                    try checkLimit(depth, maxDepth, "gltf.json.depth")
                case 0x5D, 0x7D:  // ']' ou '}'
                    depth -= 1
                    if depth < 0 {
                        throw .invalid(context: "gltf.json", reason: "fechamento sem abertura correspondente")
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - Modelos internos e validação semântica

    private struct GLTFBufferInfo {
        let byteLength: Int
        let uri: String?
    }

    private struct GLTFBufferViewInfo {
        let buffer: Int
        let byteOffset: Int
        let byteLength: Int
        let byteStride: Int?
    }

    private struct GLTFAccessorInfo {
        let bufferView: Int?
        let byteOffset: Int
        let componentType: Int
        let normalized: Bool
        let count: Int
        let type: String
        let componentCount: Int
        let elementSize: Int
    }

    private static func parseAsset(_ value: Any?) throws(CajuToolsError) -> String {
        guard let assetObj = value as? [String: Any] else {
            throw .invalid(context: "asset", reason: "campo objeto 'asset' obrigatório")
        }
        guard let version = assetObj["version"] as? String else {
            throw .invalid(context: "asset.version", reason: "campo string 'asset.version' obrigatório")
        }
        let utf8 = Array(version.utf8)
        guard utf8.count >= 3, utf8[0] == 0x32, utf8[1] == 0x2E else {
            throw .invalid(context: "asset.version", reason: "versão '\(version)' incompatível; esperado 2.x")
        }
        for i in 2..<utf8.count where !(0x30...0x39).contains(utf8[i]) {
            throw .invalid(context: "asset.version", reason: "versão '\(version)' incompatível; esperado 2.x")
        }
        return version
    }

    private static func parseBuffers(
        _ value: Any?,
        limits: ToolsLimits
    ) throws(CajuToolsError) -> [GLTFBufferInfo] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw .invalid(context: "buffers", reason: "buffers deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "buffers")

        var result: [GLTFBufferInfo] = []
        result.reserveCapacity(array.count)
        for (i, item) in array.enumerated() {
            let ctx = "buffers[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "buffer deve ser um objeto")
            }
            guard let lenAny = obj["byteLength"] else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength obrigatório")
            }
            let byteLength = try requireInt(lenAny, context: "\(ctx).byteLength")
            guard byteLength >= 1 else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength deve ser >= 1")
            }
            let uri = try optionalString(obj["uri"], context: "\(ctx).uri")
            result.append(GLTFBufferInfo(byteLength: byteLength, uri: uri))
        }
        return result
    }

    private static func parseBufferViews(
        _ value: Any?,
        buffers: [GLTFBufferInfo],
        limits: ToolsLimits
    ) throws(CajuToolsError) -> [GLTFBufferViewInfo] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw .invalid(context: "bufferViews", reason: "bufferViews deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "bufferViews")

        var result: [GLTFBufferViewInfo] = []
        result.reserveCapacity(array.count)
        for (i, item) in array.enumerated() {
            let ctx = "bufferViews[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "bufferView deve ser um objeto")
            }
            guard let bufAny = obj["buffer"] else {
                throw .invalid(context: "\(ctx).buffer", reason: "buffer obrigatório")
            }
            let bufferIdx = try requireInt(bufAny, context: "\(ctx).buffer")
            guard bufferIdx >= 0, bufferIdx < buffers.count else {
                throw .invalid(context: "\(ctx).buffer", reason: "índice de buffer fora da faixa")
            }

            let byteOffset: Int
            if let offAny = obj["byteOffset"] {
                byteOffset = try requireInt(offAny, context: "\(ctx).byteOffset")
                guard byteOffset >= 0 else {
                    throw .invalid(context: "\(ctx).byteOffset", reason: "byteOffset negativo")
                }
            } else {
                byteOffset = 0
            }

            guard let lenAny = obj["byteLength"] else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength obrigatório")
            }
            let byteLength = try requireInt(lenAny, context: "\(ctx).byteLength")
            guard byteLength >= 1 else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength deve ser >= 1")
            }
            let endOffset = try checkedAdd(byteOffset, byteLength, "\(ctx).byteLength")
            guard endOffset <= buffers[bufferIdx].byteLength else {
                throw .invalid(context: "\(ctx).byteLength", reason: "bufferView excede tamanho do buffer")
            }

            let byteStride: Int?
            if let strideAny = obj["byteStride"] {
                let s = try requireInt(strideAny, context: "\(ctx).byteStride")
                guard (4...252).contains(s), s % 4 == 0 else {
                    throw .invalid(
                        context: "\(ctx).byteStride",
                        reason: "byteStride deve estar em 4...252 e ser múltiplo de 4"
                    )
                }
                byteStride = s
            } else {
                byteStride = nil
            }

            if let targetAny = obj["target"] {
                let target = try requireInt(targetAny, context: "\(ctx).target")
                guard target == 34962 || target == 34963 else {
                    throw .invalid(context: "\(ctx).target", reason: "target inválido: \(target)")
                }
            }

            result.append(
                GLTFBufferViewInfo(
                    buffer: bufferIdx,
                    byteOffset: byteOffset,
                    byteLength: byteLength,
                    byteStride: byteStride
                )
            )
        }
        return result
    }

    private static func parseAccessors(
        _ value: Any?,
        bufferViews: [GLTFBufferViewInfo],
        limits: ToolsLimits
    ) throws(CajuToolsError) -> [GLTFAccessorInfo] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw .invalid(context: "accessors", reason: "accessors deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "accessors")

        var result: [GLTFAccessorInfo] = []
        result.reserveCapacity(array.count)
        for (i, item) in array.enumerated() {
            let ctx = "accessors[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "accessor deve ser um objeto")
            }

            let bvIndex: Int?
            if let bvAny = obj["bufferView"] {
                let idx = try requireInt(bvAny, context: "\(ctx).bufferView")
                guard idx >= 0, idx < bufferViews.count else {
                    throw .invalid(context: "\(ctx).bufferView", reason: "índice de bufferView fora da faixa")
                }
                bvIndex = idx
            } else {
                bvIndex = nil
            }

            let byteOffset: Int
            if let offAny = obj["byteOffset"] {
                guard bvIndex != nil else {
                    throw .invalid(context: "\(ctx).byteOffset", reason: "byteOffset exige bufferView")
                }
                byteOffset = try requireInt(offAny, context: "\(ctx).byteOffset")
                guard byteOffset >= 0 else {
                    throw .invalid(context: "\(ctx).byteOffset", reason: "byteOffset negativo")
                }
            } else {
                byteOffset = 0
            }

            guard let compAny = obj["componentType"] else {
                throw .invalid(context: "\(ctx).componentType", reason: "componentType obrigatório")
            }
            let compType = try requireInt(compAny, context: "\(ctx).componentType")
            let compSize = try componentByteSize(compType, context: "\(ctx).componentType")

            let normalized: Bool
            if let normAny = obj["normalized"] {
                guard let b = jsonBool(normAny) else {
                    throw .invalid(context: "\(ctx).normalized", reason: "normalized deve ser booleano")
                }
                normalized = b
            } else {
                normalized = false
            }
            if normalized, compType == 5126 || compType == 5125 {
                throw .invalid(
                    context: "\(ctx).normalized",
                    reason: "normalized não permitido para FLOAT ou UNSIGNED_INT"
                )
            }

            guard let countAny = obj["count"] else {
                throw .invalid(context: "\(ctx).count", reason: "count obrigatório")
            }
            let count = try requireInt(countAny, context: "\(ctx).count")
            guard count >= 1 else {
                throw .invalid(context: "\(ctx).count", reason: "count deve ser >= 1")
            }

            guard let typeStr = obj["type"] as? String else {
                throw .invalid(context: "\(ctx).type", reason: "type string obrigatório")
            }
            let compCount = try accessorComponentCount(typeStr, context: "\(ctx).type")
            let elementSize = try computeElementSize(type: typeStr, compSize: compSize, context: ctx)

            if let bvIndex {
                let bv = bufferViews[bvIndex]
                guard byteOffset % compSize == 0 else {
                    throw .invalid(context: "\(ctx).byteOffset", reason: "byteOffset desalinhado")
                }
                let absOffset = try checkedAdd(bv.byteOffset, byteOffset, "\(ctx).byteOffset")
                guard absOffset % compSize == 0 else {
                    throw .invalid(context: "\(ctx).byteOffset", reason: "offset absoluto desalinhado")
                }
                if let stride = bv.byteStride, stride < elementSize {
                    throw .invalid(
                        context: "\(ctx).bufferView",
                        reason: "byteStride (\(stride)) menor que elementSize (\(elementSize))"
                    )
                }
                let effectiveStride = bv.byteStride ?? elementSize
                let spanToLast = try checkedMul(count - 1, effectiveStride, "\(ctx).count")
                let lastEnd = try checkedAdd(spanToLast, elementSize, "\(ctx).count")
                let totalEnd = try checkedAdd(byteOffset, lastEnd, "\(ctx).byteOffset")
                guard totalEnd <= bv.byteLength else {
                    throw .invalid(context: "\(ctx).count", reason: "accessor excede tamanho do bufferView")
                }
            }

            try validateMinMax(obj["min"], expectedCount: compCount, context: "\(ctx).min", limits: limits)
            try validateMinMax(obj["max"], expectedCount: compCount, context: "\(ctx).max", limits: limits)

            if let sparseAny = obj["sparse"] {
                try validateSparseAccessor(
                    sparseAny,
                    accessorCount: count,
                    elementSize: elementSize,
                    bufferViews: bufferViews,
                    context: "\(ctx).sparse"
                )
            }

            result.append(
                GLTFAccessorInfo(
                    bufferView: bvIndex,
                    byteOffset: byteOffset,
                    componentType: compType,
                    normalized: normalized,
                    count: count,
                    type: typeStr,
                    componentCount: compCount,
                    elementSize: elementSize
                )
            )
        }
        return result
    }

    private static func validateSparseAccessor(
        _ value: Any,
        accessorCount: Int,
        elementSize: Int,
        bufferViews: [GLTFBufferViewInfo],
        context: String
    ) throws(CajuToolsError) {
        guard let sparse = value as? [String: Any] else {
            throw .invalid(context: context, reason: "sparse deve ser objeto")
        }
        guard let countAny = sparse["count"] else {
            throw .invalid(context: "\(context).count", reason: "sparse.count obrigatório")
        }
        let sparseCount = try requireInt(countAny, context: "\(context).count")
        guard sparseCount >= 1, sparseCount <= accessorCount else {
            throw .invalid(context: "\(context).count", reason: "sparse.count fora de 1...count")
        }

        guard let indicesObj = sparse["indices"] as? [String: Any] else {
            throw .invalid(context: "\(context).indices", reason: "sparse.indices obrigatório")
        }
        guard let idxBvAny = indicesObj["bufferView"] else {
            throw .invalid(context: "\(context).indices.bufferView", reason: "bufferView obrigatório")
        }
        let idxBvIndex = try requireInt(idxBvAny, context: "\(context).indices.bufferView")
        guard idxBvIndex >= 0, idxBvIndex < bufferViews.count else {
            throw .invalid(context: "\(context).indices.bufferView", reason: "bufferView fora da faixa")
        }
        let idxOffset: Int
        if let offAny = indicesObj["byteOffset"] {
            idxOffset = try requireInt(offAny, context: "\(context).indices.byteOffset")
            guard idxOffset >= 0 else {
                throw .invalid(context: "\(context).indices.byteOffset", reason: "byteOffset negativo")
            }
        } else {
            idxOffset = 0
        }
        guard let idxCompAny = indicesObj["componentType"] else {
            throw .invalid(context: "\(context).indices.componentType", reason: "componentType obrigatório")
        }
        let idxComp = try requireInt(idxCompAny, context: "\(context).indices.componentType")
        guard idxComp == 5121 || idxComp == 5123 || idxComp == 5125 else {
            throw .invalid(context: "\(context).indices.componentType", reason: "componentType inválido")
        }
        let idxCompSize = try componentByteSize(idxComp, context: "\(context).indices.componentType")
        let idxTotal = try checkedAdd(
            idxOffset,
            try checkedMul(sparseCount, idxCompSize, "\(context).indices"),
            "\(context).indices"
        )
        guard idxTotal <= bufferViews[idxBvIndex].byteLength else {
            throw .invalid(context: "\(context).indices", reason: "sparse.indices excede bufferView")
        }

        guard let valuesObj = sparse["values"] as? [String: Any] else {
            throw .invalid(context: "\(context).values", reason: "sparse.values obrigatório")
        }
        guard let valBvAny = valuesObj["bufferView"] else {
            throw .invalid(context: "\(context).values.bufferView", reason: "bufferView obrigatório")
        }
        let valBvIndex = try requireInt(valBvAny, context: "\(context).values.bufferView")
        guard valBvIndex >= 0, valBvIndex < bufferViews.count else {
            throw .invalid(context: "\(context).values.bufferView", reason: "bufferView fora da faixa")
        }
        let valOffset: Int
        if let offAny = valuesObj["byteOffset"] {
            valOffset = try requireInt(offAny, context: "\(context).values.byteOffset")
            guard valOffset >= 0 else {
                throw .invalid(context: "\(context).values.byteOffset", reason: "byteOffset negativo")
            }
        } else {
            valOffset = 0
        }
        let valTotal = try checkedAdd(
            valOffset,
            try checkedMul(sparseCount, elementSize, "\(context).values"),
            "\(context).values"
        )
        guard valTotal <= bufferViews[valBvIndex].byteLength else {
            throw .invalid(context: "\(context).values", reason: "sparse.values excede bufferView")
        }
    }

    private static func parseObjectArrayCount(
        _ value: Any?,
        context: String,
        limits: ToolsLimits
    ) throws(CajuToolsError) -> Int {
        guard let value else { return 0 }
        guard let array = value as? [Any] else {
            throw .invalid(context: context, reason: "\(context) deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, context)
        for (i, item) in array.enumerated() where !(item is [String: Any]) {
            throw .invalid(context: "\(context)[\(i)]", reason: "elemento deve ser um objeto")
        }
        return array.count
    }

    private static func parseTextures(
        _ value: Any?,
        samplerCount: Int,
        imageCount: Int,
        limits: ToolsLimits
    ) throws(CajuToolsError) -> Int {
        guard let value else { return 0 }
        guard let array = value as? [Any] else {
            throw .invalid(context: "textures", reason: "textures deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "textures")
        for (i, item) in array.enumerated() {
            let ctx = "textures[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "texture deve ser um objeto")
            }
            if let sAny = obj["sampler"] {
                let s = try requireInt(sAny, context: "\(ctx).sampler")
                guard s >= 0, s < samplerCount else {
                    throw .invalid(context: "\(ctx).sampler", reason: "índice de sampler fora da faixa")
                }
            }
            if let srcAny = obj["source"] {
                let src = try requireInt(srcAny, context: "\(ctx).source")
                guard src >= 0, src < imageCount else {
                    throw .invalid(context: "\(ctx).source", reason: "índice de image fora da faixa")
                }
            }
        }
        return array.count
    }

    private static func parseMaterials(
        _ value: Any?,
        textureCount: Int,
        limits: ToolsLimits
    ) throws(CajuToolsError) -> Int {
        guard let value else { return 0 }
        guard let array = value as? [Any] else {
            throw .invalid(context: "materials", reason: "materials deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "materials")

        for (i, item) in array.enumerated() {
            let ctx = "materials[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "material deve ser um objeto")
            }
            if let pbrAny = obj["pbrMetallicRoughness"] {
                guard let pbr = pbrAny as? [String: Any] else {
                    throw .invalid(context: "\(ctx).pbrMetallicRoughness", reason: "deve ser objeto")
                }
                try validateTextureRef(
                    pbr["baseColorTexture"],
                    textureCount: textureCount,
                    context: "\(ctx).pbrMetallicRoughness.baseColorTexture"
                )
                try validateTextureRef(
                    pbr["metallicRoughnessTexture"],
                    textureCount: textureCount,
                    context: "\(ctx).pbrMetallicRoughness.metallicRoughnessTexture"
                )
            }
            try validateTextureRef(
                obj["normalTexture"], textureCount: textureCount, context: "\(ctx).normalTexture")
            try validateTextureRef(
                obj["occlusionTexture"], textureCount: textureCount, context: "\(ctx).occlusionTexture")
            try validateTextureRef(
                obj["emissiveTexture"], textureCount: textureCount, context: "\(ctx).emissiveTexture")
        }
        return array.count
    }

    private static func validateTextureRef(
        _ value: Any?,
        textureCount: Int,
        context: String
    ) throws(CajuToolsError) {
        guard let value else { return }
        guard let obj = value as? [String: Any] else {
            throw .invalid(context: context, reason: "textureInfo deve ser objeto")
        }
        guard let idxAny = obj["index"] else {
            throw .invalid(context: "\(context).index", reason: "index obrigatório")
        }
        let idx = try requireInt(idxAny, context: "\(context).index")
        guard idx >= 0, idx < textureCount else {
            throw .invalid(context: "\(context).index", reason: "índice de texture fora da faixa")
        }
    }

    private static func parseMeshes(
        _ value: Any?,
        accessors: [GLTFAccessorInfo],
        materialCount: Int,
        limits: ToolsLimits
    ) throws(CajuToolsError) -> [Int] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw .invalid(context: "meshes", reason: "meshes deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "meshes")

        var primCounts: [Int] = []
        primCounts.reserveCapacity(array.count)
        for (i, item) in array.enumerated() {
            let ctx = "meshes[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "mesh deve ser um objeto")
            }
            _ = try optionalString(obj["name"], context: "\(ctx).name")
            guard let primsArr = obj["primitives"] as? [Any], !primsArr.isEmpty else {
                throw .invalid(context: "\(ctx).primitives", reason: "primitives obrigatório e não vazio")
            }
            try checkLimit(primsArr.count, limits.maxElements, "\(ctx).primitives")
            for (j, primAny) in primsArr.enumerated() {
                try validatePrimitive(
                    primAny,
                    accessors: accessors,
                    materialCount: materialCount,
                    context: "\(ctx).primitives[\(j)]",
                    limits: limits
                )
            }
            primCounts.append(primsArr.count)
        }
        return primCounts
    }

    private static func validatePrimitive(
        _ value: Any,
        accessors: [GLTFAccessorInfo],
        materialCount: Int,
        context: String,
        limits: ToolsLimits
    ) throws(CajuToolsError) {
        guard let obj = value as? [String: Any] else {
            throw .invalid(context: context, reason: "primitive deve ser um objeto")
        }
        if let modeAny = obj["mode"] {
            let mode = try requireInt(modeAny, context: "\(context).mode")
            guard (0...6).contains(mode) else {
                throw .invalid(context: "\(context).mode", reason: "mode inválido: \(mode)")
            }
        }
        guard let attrs = obj["attributes"] as? [String: Any], !attrs.isEmpty else {
            throw .invalid(context: "\(context).attributes", reason: "attributes obrigatório e não vazio")
        }
        try checkLimit(attrs.count, limits.maxElements, "\(context).attributes")

        var expectedCount: Int?
        var hasPosition = false
        for (attrName, idxAny) in attrs {
            let attrCtx = "\(context).attributes.\(attrName)"
            let accIdx = try requireInt(idxAny, context: attrCtx)
            guard accIdx >= 0, accIdx < accessors.count else {
                throw .invalid(context: attrCtx, reason: "índice de accessor fora da faixa")
            }
            let acc = accessors[accIdx]
            if let first = expectedCount {
                guard acc.count == first else {
                    throw .invalid(
                        context: attrCtx,
                        reason: "contagem do atributo (\(acc.count)) difere de \(first)"
                    )
                }
            } else {
                expectedCount = acc.count
            }
            if attrName == "POSITION" {
                guard acc.type == "VEC3" else {
                    throw .invalid(context: attrCtx, reason: "POSITION deve ter tipo VEC3")
                }
                hasPosition = true
            }
        }
        guard hasPosition else {
            throw .invalid(context: "\(context).attributes", reason: "atributo POSITION obrigatório ausente")
        }

        if let idxAny = obj["indices"] {
            let idxCtx = "\(context).indices"
            let accIdx = try requireInt(idxAny, context: idxCtx)
            guard accIdx >= 0, accIdx < accessors.count else {
                throw .invalid(context: idxCtx, reason: "índice de accessor fora da faixa")
            }
            let acc = accessors[accIdx]
            guard acc.type == "SCALAR" else {
                throw .invalid(context: idxCtx, reason: "indices deve ser SCALAR")
            }
            guard acc.componentType == 5121 || acc.componentType == 5123 || acc.componentType == 5125 else {
                throw .invalid(
                    context: idxCtx,
                    reason: "indices deve usar UNSIGNED_BYTE, UNSIGNED_SHORT ou UNSIGNED_INT"
                )
            }
            guard !acc.normalized else {
                throw .invalid(context: idxCtx, reason: "indices não pode ser normalized")
            }
        }

        if let matAny = obj["material"] {
            let matCtx = "\(context).material"
            let matIdx = try requireInt(matAny, context: matCtx)
            guard matIdx >= 0, matIdx < materialCount else {
                throw .invalid(context: matCtx, reason: "índice de material fora da faixa")
            }
        }
    }

    private static func countNodes(_ value: Any?, limits: ToolsLimits) throws(CajuToolsError) -> Int {
        guard let value else { return 0 }
        guard let array = value as? [Any] else {
            throw .invalid(context: "nodes", reason: "nodes deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "nodes")
        return array.count
    }

    private static func parseSkins(
        _ value: Any?,
        accessors: [GLTFAccessorInfo],
        nodeCount: Int,
        limits: ToolsLimits
    ) throws(CajuToolsError) -> Int {
        guard let value else { return 0 }
        guard let array = value as? [Any] else {
            throw .invalid(context: "skins", reason: "skins deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "skins")
        for (i, item) in array.enumerated() {
            let ctx = "skins[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "skin deve ser um objeto")
            }
            guard let jointsArr = obj["joints"] as? [Any], !jointsArr.isEmpty else {
                throw .invalid(context: "\(ctx).joints", reason: "joints obrigatório e não vazio")
            }
            try checkLimit(jointsArr.count, limits.maxElements, "\(ctx).joints")
            for (k, jAny) in jointsArr.enumerated() {
                let j = try requireInt(jAny, context: "\(ctx).joints[\(k)]")
                guard j >= 0, j < nodeCount else {
                    throw .invalid(context: "\(ctx).joints[\(k)]", reason: "índice de nó fora da faixa")
                }
            }
            if let skelAny = obj["skeleton"] {
                let skel = try requireInt(skelAny, context: "\(ctx).skeleton")
                guard skel >= 0, skel < nodeCount else {
                    throw .invalid(context: "\(ctx).skeleton", reason: "índice de nó fora da faixa")
                }
            }
            if let ibmAny = obj["inverseBindMatrices"] {
                let accIdx = try requireInt(ibmAny, context: "\(ctx).inverseBindMatrices")
                guard accIdx >= 0, accIdx < accessors.count else {
                    throw .invalid(context: "\(ctx).inverseBindMatrices", reason: "accessor fora da faixa")
                }
                let acc = accessors[accIdx]
                guard acc.type == "MAT4", acc.componentType == 5126, acc.count >= jointsArr.count else {
                    throw .invalid(
                        context: "\(ctx).inverseBindMatrices",
                        reason: "inverseBindMatrices deve ser MAT4 FLOAT com count >= joints.count"
                    )
                }
            }
        }
        return array.count
    }

    private static func parseNodes(
        _ value: Any?,
        meshCount: Int,
        cameraCount: Int,
        skinCount: Int,
        limits: ToolsLimits
    ) throws(CajuToolsError) -> [Int] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw .invalid(context: "nodes", reason: "nodes deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "nodes")

        var parentCounts = [Int](repeating: 0, count: array.count)
        var adjacency: [[Int]] = Array(repeating: [], count: array.count)

        for (i, item) in array.enumerated() {
            let ctx = "nodes[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "node deve ser um objeto")
            }
            _ = try optionalString(obj["name"], context: "\(ctx).name")

            var hasMesh = false
            if let meshAny = obj["mesh"] {
                let m = try requireInt(meshAny, context: "\(ctx).mesh")
                guard m >= 0, m < meshCount else {
                    throw .invalid(context: "\(ctx).mesh", reason: "índice de mesh fora da faixa")
                }
                hasMesh = true
            }
            if let camAny = obj["camera"] {
                let c = try requireInt(camAny, context: "\(ctx).camera")
                guard c >= 0, c < cameraCount else {
                    throw .invalid(context: "\(ctx).camera", reason: "índice de camera fora da faixa")
                }
            }
            if let skinAny = obj["skin"] {
                let s = try requireInt(skinAny, context: "\(ctx).skin")
                guard s >= 0, s < skinCount else {
                    throw .invalid(context: "\(ctx).skin", reason: "índice de skin fora da faixa")
                }
                guard hasMesh else {
                    throw .invalid(context: "\(ctx).skin", reason: "nó com skin deve referenciar mesh")
                }
            }

            if let childrenAny = obj["children"] {
                guard let chArr = childrenAny as? [Any] else {
                    throw .invalid(context: "\(ctx).children", reason: "children deve ser um array")
                }
                try checkLimit(chArr.count, limits.maxElements, "\(ctx).children")
                var children: [Int] = []
                children.reserveCapacity(chArr.count)
                for (k, cAny) in chArr.enumerated() {
                    let cCtx = "\(ctx).children[\(k)]"
                    let c = try requireInt(cAny, context: cCtx)
                    guard c >= 0, c < array.count else {
                        throw .invalid(context: cCtx, reason: "índice de nó filho fora da faixa")
                    }
                    guard c != i else {
                        throw .invalid(context: cCtx, reason: "nó não pode ser filho de si mesmo")
                    }
                    parentCounts[c] += 1
                    guard parentCounts[c] == 1 else {
                        throw .invalid(context: cCtx, reason: "nó \(c) possui mais de um pai")
                    }
                    children.append(c)
                }
                adjacency[i] = children
            }

            let hasTranslation = try validateFloatArray(
                obj["translation"], count: 3, context: "\(ctx).translation")
            let hasRotation = try validateFloatArray(obj["rotation"], count: 4, context: "\(ctx).rotation")
            let hasScale = try validateFloatArray(obj["scale"], count: 3, context: "\(ctx).scale")
            let hasMatrix = try validateFloatArray(obj["matrix"], count: 16, context: "\(ctx).matrix")

            if hasMatrix, hasTranslation || hasRotation || hasScale {
                throw .invalid(context: ctx, reason: "matrix e TRS são mutuamente exclusivos")
            }
        }

        try validateNodeAcyclic(adjacency)
        return parentCounts
    }

    private static func validateNodeAcyclic(_ adjacency: [[Int]]) throws(CajuToolsError) {
        var state = [UInt8](repeating: 0, count: adjacency.count)
        var stack: [(node: Int, nextChild: Int)] = []

        for start in adjacency.indices where state[start] == 0 {
            state[start] = 1
            stack.append((start, 0))
            while let top = stack.last {
                let u = top.node
                let ci = top.nextChild
                if ci < adjacency[u].count {
                    stack[stack.count - 1].nextChild = ci + 1
                    let v = adjacency[u][ci]
                    if state[v] == 1 {
                        throw .invalid(
                            context: "nodes[\(u)].children[\(ci)]",
                            reason: "ciclo detectado na hierarquia de nós"
                        )
                    }
                    if state[v] == 0 {
                        state[v] = 1
                        stack.append((v, 0))
                    }
                } else {
                    state[u] = 2
                    stack.removeLast()
                }
            }
        }
    }

    private static func parseScenes(
        _ value: Any?,
        nodeCount: Int,
        parentCounts: [Int],
        limits: ToolsLimits
    ) throws(CajuToolsError) -> Int {
        guard let value else { return 0 }
        guard let array = value as? [Any] else {
            throw .invalid(context: "scenes", reason: "scenes deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "scenes")

        for (i, item) in array.enumerated() {
            let ctx = "scenes[\(i)]"
            guard let obj = item as? [String: Any] else {
                throw .invalid(context: ctx, reason: "scene deve ser um objeto")
            }
            _ = try optionalString(obj["name"], context: "\(ctx).name")
            if let nodesAny = obj["nodes"] {
                guard let nArr = nodesAny as? [Any] else {
                    throw .invalid(context: "\(ctx).nodes", reason: "nodes deve ser um array")
                }
                try checkLimit(nArr.count, limits.maxElements, "\(ctx).nodes")
                var seenRoots = Set<Int>()
                for (k, nAny) in nArr.enumerated() {
                    let nCtx = "\(ctx).nodes[\(k)]"
                    let n = try requireInt(nAny, context: nCtx)
                    guard n >= 0, n < nodeCount else {
                        throw .invalid(context: nCtx, reason: "índice de nó fora da faixa")
                    }
                    guard parentCounts[n] == 0 else {
                        throw .invalid(context: nCtx, reason: "nó raiz de cena possui pai")
                    }
                    guard seenRoots.insert(n).inserted else {
                        throw .invalid(context: nCtx, reason: "nó raiz duplicado na cena")
                    }
                }
            }
        }
        return array.count
    }

    // MARK: - Helpers de tipos JSON (Foundation)

    private static func jsonBool(_ value: Any) -> Bool? {
        #if canImport(Darwin)
            if let num = value as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue
            }
            return nil
        #else
            return value as? Bool
        #endif
    }

    private static func isJSONBool(_ value: Any) -> Bool {
        jsonBool(value) != nil
    }

    private static func jsonDouble(_ value: Any) -> Double? {
        guard !isJSONBool(value), let num = value as? NSNumber else { return nil }
        let d = num.doubleValue
        return d.isFinite ? d : nil
    }

    private static func requireInt(_ value: Any, context: String) throws(CajuToolsError) -> Int {
        guard !isJSONBool(value), let num = value as? NSNumber else {
            throw .invalid(context: context, reason: "inteiro esperado")
        }
        #if canImport(Darwin)
            if CFNumberIsFloatType(num) {
                let d = num.doubleValue
                guard d.isFinite, let exact = Int(exactly: d) else {
                    throw .invalid(context: context, reason: "inteiro esperado")
                }
                return exact
            }
        #endif
        let d = num.doubleValue
        guard d.isFinite else {
            throw .invalid(context: context, reason: "inteiro esperado")
        }
        if let exact = Int(exactly: num.int64Value), Double(exact) == d {
            return exact
        }
        guard let exactD = Int(exactly: d) else {
            throw .invalid(context: context, reason: "inteiro esperado")
        }
        return exactD
    }

    private static func optionalString(_ value: Any?, context: String) throws(CajuToolsError) -> String? {
        guard let value else { return nil }
        guard let s = value as? String else {
            throw .invalid(context: context, reason: "string esperada")
        }
        return s
    }

    private static func validateFloatArray(
        _ value: Any?,
        count: Int,
        context: String
    ) throws(CajuToolsError) -> Bool {
        guard let value else { return false }
        guard let arr = value as? [Any] else {
            throw .invalid(context: context, reason: "array numérico esperado")
        }
        guard arr.count == count else {
            throw .invalid(context: context, reason: "esperados \(count) componentes")
        }
        for (i, elem) in arr.enumerated() {
            guard let d = jsonDouble(elem), Float(d).isFinite else {
                throw .invalid(context: "\(context)[\(i)]", reason: "número finito esperado")
            }
        }
        return true
    }

    private static func validateMinMax(
        _ value: Any?,
        expectedCount: Int,
        context: String,
        limits: ToolsLimits
    ) throws(CajuToolsError) {
        guard let value else { return }
        guard let arr = value as? [Any] else {
            throw .invalid(context: context, reason: "min/max deve ser array")
        }
        try checkLimit(arr.count, limits.maxElements, context)
        guard arr.count == expectedCount else {
            throw .invalid(context: context, reason: "quantidade diferente de \(expectedCount)")
        }
        for (i, elem) in arr.enumerated() {
            guard jsonDouble(elem) != nil else {
                throw .invalid(context: "\(context)[\(i)]", reason: "número finito esperado")
            }
        }
    }

    private static func componentByteSize(_ compType: Int, context: String) throws(CajuToolsError) -> Int {
        switch compType {
        case 5120, 5121: 1
        case 5122, 5123: 2
        case 5125, 5126: 4
        default: throw .invalid(context: context, reason: "componentType inválido: \(compType)")
        }
    }

    private static func accessorComponentCount(_ type: String, context: String) throws(CajuToolsError) -> Int
    {
        switch type {
        case "SCALAR": 1
        case "VEC2": 2
        case "VEC3": 3
        case "VEC4", "MAT2": 4
        case "MAT3": 9
        case "MAT4": 16
        default: throw .invalid(context: context, reason: "type inválido: \(type)")
        }
    }

    private static func computeElementSize(
        type: String,
        compSize: Int,
        context: String
    ) throws(CajuToolsError) -> Int {
        switch type {
        case "SCALAR": return compSize
        case "VEC2": return try checkedMul(2, compSize, context)
        case "VEC3": return try checkedMul(3, compSize, context)
        case "VEC4": return try checkedMul(4, compSize, context)
        case "MAT2": return try checkedMul(2, ((2 * compSize) + 3) & ~3, context)
        case "MAT3": return try checkedMul(3, ((3 * compSize) + 3) & ~3, context)
        case "MAT4": return try checkedMul(4, ((4 * compSize) + 3) & ~3, context)
        default: throw .invalid(context: context, reason: "type inválido: \(type)")
        }
    }
}

/// Executor do subcomando `validate-gltf`.
public enum ValidateGLTFCommand {
    public static let helpText = """
        uso: caju-tools validate-gltf <arquivo.gltf|arquivo.glb> [--json]

        opções:
          --json       emite resumo estruturado em JSON determinístico (chaves ordenadas)
          -h, --help   exibe esta ajuda
        """

    public static func run(arguments: [String]) throws(CajuToolsError) -> String {
        var inputPath: String?
        var emitJSON = false

        for arg in arguments {
            switch arg {
            case "--json":
                emitJSON = true
            default:
                if arg.hasPrefix("-") {
                    throw .usage("opção desconhecida '\(arg)'")
                }
                guard inputPath == nil else {
                    throw .usage("argumento posicional inesperado '\(arg)'")
                }
                inputPath = arg
            }
        }

        guard let inputPath else {
            throw .usage("caminho do arquivo glTF/GLB obrigatório")
        }

        let bytes = try readFileBytes(atPath: inputPath, limits: .default)
        let summary = try GLTFValidator.validate(bytes, limits: .default)
        return formatSummary(summary, asJSON: emitJSON)
    }

    static func formatSummary(_ s: GLTFValidationSummary, asJSON: Bool) -> String {
        if asJSON {
            let doc: DeterministicJSON = .object([
                ("accessors", .int(s.accessors)),
                ("bufferViews", .int(s.bufferViews)),
                ("buffers", .int(s.buffers)),
                ("format", .string(s.format)),
                ("images", .int(s.images)),
                ("materials", .int(s.materials)),
                ("meshes", .int(s.meshes)),
                ("nodes", .int(s.nodes)),
                ("scenes", .int(s.scenes)),
                ("textures", .int(s.textures)),
                ("valid", .bool(true)),
                ("version", .string(s.version)),
            ])
            return doc.format()
        }
        return "OK format=\(s.format) version=\(s.version) scenes=\(s.scenes) nodes=\(s.nodes) "
            + "meshes=\(s.meshes) materials=\(s.materials) textures=\(s.textures) "
            + "images=\(s.images) accessors=\(s.accessors) bufferViews=\(s.bufferViews) buffers=\(s.buffers)\n"
    }
}
