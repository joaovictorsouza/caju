import CajuMath

/// Parser de documentos glTF 2.0 em JSON puro (`.gltf`) ou container binário (`.glb`).
///
/// Valida estrutura, limites de `AssetLimits`, índices cruzados, alinhamento, strides e
/// hierarquia de nós sem usar `Foundation`.
///
/// ```swift
/// let doc = try GLTFParser.parse(bytes)
/// for mesh in doc.meshes {
///     for prim in mesh.primitives {
///         if let posIndex = prim.attributes.first(where: { $0.name == "POSITION" })?.accessorIndex {
///             let layout = try doc.accessorLayout(posIndex)
///             _ = layout
///         }
///     }
/// }
/// ```
public enum GLTFParser {
    private static let glbMagic: UInt32 = 0x4654_6C67  // "glTF"
    private static let glbChunkJSON: UInt32 = 0x4E4F_534A  // "JSON"
    private static let glbChunkBIN: UInt32 = 0x004E_4942  // "BIN\0"

    /// Faz o parsing e validação completa de um arquivo `.gltf` ou `.glb`.
    public static func parse(
        _ bytes: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> GLTFDocument {
        try checkLimit(bytes.count, limits.maxInputBytes, "gltf")
        guard !bytes.isEmpty else {
            throw .truncated(context: "gltf")
        }

        let isGLB = isGLBHeader(bytes)
        let jsonValue: JSONValue
        let glbBinary: Range<Int>?

        if isGLB {
            let (jsonRange, binRange) = try parseGLBContainer(bytes)
            glbBinary = binRange
            jsonValue = try JSONParser.parseSlice(bytes, range: jsonRange, limits: limits, context: "json")
        } else {
            glbBinary = nil
            jsonValue = try JSONParser.parse(bytes, limits: limits, context: "json")
        }

        return try decodeDocument(
            root: jsonValue,
            isGLB: isGLB,
            glbBinary: glbBinary,
            limits: limits
        )
    }

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
    ) throws(AssetError) -> (jsonRange: Range<Int>, binRange: Range<Int>?) {
        guard bytes.count >= 12 else {
            throw .truncated(context: "glb.header")
        }
        var reader = ByteReader(bytes)
        let magic = try reader.readU32LE("glb.magic")
        guard magic == glbMagic else {
            throw .invalid(context: "glb.magic", reason: "assinatura GLB inválida")
        }
        let version = try reader.readU32LE("glb.version")
        guard version == 2 else {
            throw .invalid(context: "glb.version", reason: "versão GLB \(version) não é 2")
        }
        let lengthU32 = try reader.readU32LE("glb.length")
        let totalLength = Int(lengthU32)
        guard totalLength >= 12 else {
            throw .invalid(context: "glb.length", reason: "comprimento GLB menor que cabeçalho")
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
            let chunkLengthU32 = try reader.readU32LE("\(ctx).length")
            let chunkType = try reader.readU32LE("\(ctx).type")
            let chunkLength = Int(chunkLengthU32)
            guard chunkLength % 4 == 0 else {
                throw .invalid(context: "\(ctx).length", reason: "comprimento de chunk não múltiplo de 4")
            }
            let payloadEnd = try checkedAdd(reader.offset, chunkLength, "\(ctx).length")
            guard payloadEnd <= totalLength else {
                throw .truncated(context: "\(ctx).data")
            }

            if chunkIndex == 0 {
                guard chunkType == glbChunkJSON else {
                    throw .invalid(context: "\(ctx).type", reason: "primeiro chunk GLB deve ser JSON")
                }
                guard chunkLength > 0 else {
                    throw .invalid(context: "\(ctx).length", reason: "chunk JSON vazio")
                }
                jsonRange = reader.offset..<payloadEnd
            } else {
                switch chunkType {
                case glbChunkJSON:
                    throw .invalid(context: "\(ctx).type", reason: "múltiplos chunks JSON no GLB")
                case glbChunkBIN:
                    guard binRange == nil else {
                        throw .invalid(context: "\(ctx).type", reason: "múltiplos chunks BIN no GLB")
                    }
                    binRange = reader.offset..<payloadEnd
                default:
                    break
                }
            }

            try reader.seek(to: payloadEnd, context: "\(ctx).data")
            chunkIndex += 1
        }

        guard let resolvedJSON = jsonRange else {
            throw .invalid(context: "glb.chunks", reason: "chunk JSON ausente")
        }
        return (resolvedJSON, binRange)
    }

    private static func decodeDocument(
        root: JSONValue,
        isGLB: Bool,
        glbBinary: Range<Int>?,
        limits: AssetLimits
    ) throws(AssetError) -> GLTFDocument {
        guard let rootPairs = root.objectPairs else {
            throw .invalid(context: "gltf", reason: "raiz glTF deve ser um objeto JSON")
        }
        _ = rootPairs

        let asset = try parseAsset(root.field("asset"))
        let buffers = try parseBuffers(root.field("buffers"), limits: limits)

        if isGLB {
            if let bin = glbBinary {
                guard !buffers.isEmpty else {
                    throw .invalid(context: "buffers", reason: "chunk BIN presente sem buffer 0")
                }
                if buffers[0].uri != nil {
                    throw .invalid(context: "buffers[0].uri", reason: "buffer 0 em GLB não pode ter uri")
                }
                guard buffers[0].byteLength <= bin.count else {
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

        let bufferViews = try parseBufferViews(
            root.field("bufferViews"),
            buffers: buffers,
            limits: limits
        )
        let accessors = try parseAccessors(
            root.field("accessors"),
            bufferViews: bufferViews,
            limits: limits
        )
        let materialCount = try parseObjectArrayCount(
            root.field("materials"),
            context: "materials",
            limits: limits
        )
        let textureCount = try parseObjectArrayCount(
            root.field("textures"),
            context: "textures",
            limits: limits
        )
        let imageCount = try parseObjectArrayCount(
            root.field("images"),
            context: "images",
            limits: limits
        )
        let meshes = try parseMeshes(
            root.field("meshes"),
            accessors: accessors,
            materialCount: materialCount,
            limits: limits
        )
        let (nodes, parentCounts) = try parseNodes(
            root.field("nodes"),
            meshCount: meshes.count,
            limits: limits
        )
        let scenes = try parseScenes(
            root.field("scenes"),
            nodeCount: nodes.count,
            parentCounts: parentCounts,
            limits: limits
        )

        let defaultScene: Int?
        if let sceneVal = root.field("scene") {
            let idx = try requireInt(sceneVal, context: "scene")
            guard idx >= 0, idx < scenes.count else {
                throw .invalid(context: "scene", reason: "índice de cena padrão fora da faixa")
            }
            defaultScene = idx
        } else {
            defaultScene = nil
        }

        return GLTFDocument(
            asset: asset,
            buffers: buffers,
            bufferViews: bufferViews,
            accessors: accessors,
            meshes: meshes,
            nodes: nodes,
            scenes: scenes,
            scene: defaultScene,
            materialCount: materialCount,
            textureCount: textureCount,
            imageCount: imageCount,
            glbBinary: glbBinary
        )
    }

    private static func parseAsset(_ value: JSONValue?) throws(AssetError) -> GLTFAsset {
        guard let value else {
            throw .invalid(context: "asset", reason: "campo asset obrigatório")
        }
        guard value.objectPairs != nil else {
            throw .invalid(context: "asset", reason: "asset deve ser um objeto")
        }
        guard let versionVal = value.field("version") else {
            throw .invalid(context: "asset.version", reason: "campo asset.version obrigatório")
        }
        guard let version = versionVal.stringValue else {
            throw .invalid(context: "asset.version", reason: "asset.version deve ser string")
        }
        guard isGLTF2Version(version) else {
            throw .invalid(context: "asset.version", reason: "versão '\(version)' incompatível; esperado 2.x")
        }
        return GLTFAsset(version: version)
    }

    private static func isGLTF2Version(_ version: String) -> Bool {
        let utf8 = Array(version.utf8)
        guard utf8.count >= 3, utf8[0] == 0x32, utf8[1] == 0x2E else { return false }
        for i in 2..<utf8.count {
            guard (0x30...0x39).contains(utf8[i]) else { return false }
        }
        return true
    }

    private static func parseBuffers(
        _ value: JSONValue?,
        limits: AssetLimits
    ) throws(AssetError) -> [GLTFBuffer] {
        guard let value else { return [] }
        guard let array = value.arrayValues else {
            throw .invalid(context: "buffers", reason: "buffers deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "buffers")
        var result: [GLTFBuffer] = []
        result.reserveCapacity(array.count)

        for (i, item) in array.enumerated() {
            let ctx = "buffers[\(i)]"
            guard item.objectPairs != nil else {
                throw .invalid(context: ctx, reason: "buffer deve ser um objeto")
            }
            guard let lenVal = item.field("byteLength") else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength obrigatório")
            }
            let byteLength = try requireInt(lenVal, context: "\(ctx).byteLength")
            guard byteLength >= 1 else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength deve ser >= 1")
            }
            let uri: String?
            if let uriVal = item.field("uri") {
                guard let s = uriVal.stringValue else {
                    throw .invalid(context: "\(ctx).uri", reason: "uri deve ser string")
                }
                uri = s
            } else {
                uri = nil
            }
            result.append(GLTFBuffer(byteLength: byteLength, uri: uri))
        }
        return result
    }

    private static func parseBufferViews(
        _ value: JSONValue?,
        buffers: [GLTFBuffer],
        limits: AssetLimits
    ) throws(AssetError) -> [GLTFBufferView] {
        guard let value else { return [] }
        guard let array = value.arrayValues else {
            throw .invalid(context: "bufferViews", reason: "bufferViews deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "bufferViews")
        var result: [GLTFBufferView] = []
        result.reserveCapacity(array.count)

        for (i, item) in array.enumerated() {
            let ctx = "bufferViews[\(i)]"
            guard item.objectPairs != nil else {
                throw .invalid(context: ctx, reason: "bufferView deve ser um objeto")
            }
            guard let bufVal = item.field("buffer") else {
                throw .invalid(context: "\(ctx).buffer", reason: "buffer obrigatório")
            }
            let bufferIndex = try requireInt(bufVal, context: "\(ctx).buffer")
            guard bufferIndex >= 0, bufferIndex < buffers.count else {
                throw .invalid(context: "\(ctx).buffer", reason: "índice de buffer fora da faixa")
            }

            let byteOffset: Int
            if let offVal = item.field("byteOffset") {
                byteOffset = try requireInt(offVal, context: "\(ctx).byteOffset")
                guard byteOffset >= 0 else {
                    throw .invalid(context: "\(ctx).byteOffset", reason: "byteOffset negativo")
                }
            } else {
                byteOffset = 0
            }

            guard let lenVal = item.field("byteLength") else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength obrigatório")
            }
            let byteLength = try requireInt(lenVal, context: "\(ctx).byteLength")
            guard byteLength >= 1 else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength deve ser >= 1")
            }

            let endOffset = try checkedAdd(byteOffset, byteLength, "\(ctx).byteLength")
            guard endOffset <= buffers[bufferIndex].byteLength else {
                throw .invalid(context: "\(ctx).byteLength", reason: "bufferView excede tamanho do buffer")
            }

            let byteStride: Int?
            if let strideVal = item.field("byteStride") {
                let s = try requireInt(strideVal, context: "\(ctx).byteStride")
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

            let target: GLTFBufferTarget?
            if let targetVal = item.field("target") {
                let raw = try requireInt(targetVal, context: "\(ctx).target")
                guard let parsed = GLTFBufferTarget(rawValue: raw) else {
                    throw .invalid(context: "\(ctx).target", reason: "target inválido: \(raw)")
                }
                target = parsed
            } else {
                target = nil
            }

            result.append(
                GLTFBufferView(
                    buffer: bufferIndex,
                    byteOffset: byteOffset,
                    byteLength: byteLength,
                    byteStride: byteStride,
                    target: target
                )
            )
        }
        return result
    }

    private static func parseAccessors(
        _ value: JSONValue?,
        bufferViews: [GLTFBufferView],
        limits: AssetLimits
    ) throws(AssetError) -> [GLTFAccessor] {
        guard let value else { return [] }
        guard let array = value.arrayValues else {
            throw .invalid(context: "accessors", reason: "accessors deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "accessors")
        var result: [GLTFAccessor] = []
        result.reserveCapacity(array.count)

        for (i, item) in array.enumerated() {
            let ctx = "accessors[\(i)]"
            guard item.objectPairs != nil else {
                throw .invalid(context: ctx, reason: "accessor deve ser um objeto")
            }
            if item.field("sparse") != nil {
                throw .unsupported(context: "\(ctx).sparse", reason: "sparse accessors não são suportados")
            }

            let bvIndex: Int?
            if let bvVal = item.field("bufferView") {
                let idx = try requireInt(bvVal, context: "\(ctx).bufferView")
                guard idx >= 0, idx < bufferViews.count else {
                    throw .invalid(context: "\(ctx).bufferView", reason: "índice de bufferView fora da faixa")
                }
                bvIndex = idx
            } else {
                bvIndex = nil
            }

            let byteOffset: Int
            if let offVal = item.field("byteOffset") {
                guard bvIndex != nil else {
                    throw .invalid(context: "\(ctx).byteOffset", reason: "byteOffset exige bufferView")
                }
                byteOffset = try requireInt(offVal, context: "\(ctx).byteOffset")
                guard byteOffset >= 0 else {
                    throw .invalid(context: "\(ctx).byteOffset", reason: "byteOffset negativo")
                }
            } else {
                byteOffset = 0
            }

            guard let compVal = item.field("componentType") else {
                throw .invalid(context: "\(ctx).componentType", reason: "componentType obrigatório")
            }
            let compRaw = try requireInt(compVal, context: "\(ctx).componentType")
            guard let componentType = GLTFComponentType(rawValue: compRaw) else {
                throw .invalid(context: "\(ctx).componentType", reason: "componentType inválido: \(compRaw)")
            }

            let normalized: Bool
            if let normVal = item.field("normalized") {
                guard let b = normVal.boolValue else {
                    throw .invalid(context: "\(ctx).normalized", reason: "normalized deve ser booleano")
                }
                normalized = b
            } else {
                normalized = false
            }
            if normalized, componentType == .float || componentType == .unsignedInt {
                throw .invalid(
                    context: "\(ctx).normalized",
                    reason: "normalized não permitido para FLOAT ou UNSIGNED_INT"
                )
            }

            guard let countVal = item.field("count") else {
                throw .invalid(context: "\(ctx).count", reason: "count obrigatório")
            }
            let count = try requireInt(countVal, context: "\(ctx).count")
            guard count >= 1 else {
                throw .invalid(context: "\(ctx).count", reason: "count deve ser >= 1")
            }

            guard let typeVal = item.field("type") else {
                throw .invalid(context: "\(ctx).type", reason: "type obrigatório")
            }
            guard let typeStr = typeVal.stringValue, let accType = GLTFAccessorType(rawValue: typeStr) else {
                throw .invalid(context: "\(ctx).type", reason: "type inválido")
            }

            let elementSize = try computeElementSize(
                type: accType, componentType: componentType, context: ctx)

            if let bvIndex {
                let bv = bufferViews[bvIndex]
                let compSize = componentType.byteSize
                guard byteOffset % compSize == 0 else {
                    throw .invalid(
                        context: "\(ctx).byteOffset",
                        reason: "byteOffset desalinhado para o tipo do componente"
                    )
                }
                let absOffset = try checkedAdd(bv.byteOffset, byteOffset, "\(ctx).byteOffset")
                guard absOffset % compSize == 0 else {
                    throw .invalid(
                        context: "\(ctx).byteOffset",
                        reason: "offset absoluto no buffer desalinhado para o tipo do componente"
                    )
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

            let minVals = try parseMinMax(
                item.field("min"),
                expectedCount: accType.componentCount,
                context: "\(ctx).min",
                limits: limits
            )
            let maxVals = try parseMinMax(
                item.field("max"),
                expectedCount: accType.componentCount,
                context: "\(ctx).max",
                limits: limits
            )

            result.append(
                GLTFAccessor(
                    bufferView: bvIndex,
                    byteOffset: byteOffset,
                    componentType: componentType,
                    normalized: normalized,
                    count: count,
                    type: accType,
                    elementSize: elementSize,
                    min: minVals,
                    max: maxVals
                )
            )
        }
        return result
    }

    private static func computeElementSize(
        type: GLTFAccessorType,
        componentType: GLTFComponentType,
        context: String
    ) throws(AssetError) -> Int {
        let compSize = componentType.byteSize
        switch type {
        case .scalar, .vec2, .vec3, .vec4:
            return try checkedMul(type.componentCount, compSize, context)
        case .mat2:
            let col = ((2 * compSize) + 3) & ~3
            return try checkedMul(2, col, context)
        case .mat3:
            let col = ((3 * compSize) + 3) & ~3
            return try checkedMul(3, col, context)
        case .mat4:
            let col = ((4 * compSize) + 3) & ~3
            return try checkedMul(4, col, context)
        }
    }

    private static func parseMinMax(
        _ value: JSONValue?,
        expectedCount: Int,
        context: String,
        limits: AssetLimits
    ) throws(AssetError) -> [Double]? {
        guard let value else { return nil }
        guard let arr = value.arrayValues else {
            throw .invalid(context: context, reason: "min/max deve ser um array")
        }
        try checkLimit(arr.count, limits.maxElements, context)
        guard arr.count == expectedCount else {
            throw .invalid(context: context, reason: "quantidade de elementos diferente de \(expectedCount)")
        }
        var out: [Double] = []
        out.reserveCapacity(arr.count)
        for (i, elem) in arr.enumerated() {
            guard let n = elem.numberValue, n.isFinite else {
                throw .invalid(context: "\(context)[\(i)]", reason: "número finito esperado")
            }
            out.append(n)
        }
        return out
    }

    private static func parseObjectArrayCount(
        _ value: JSONValue?,
        context: String,
        limits: AssetLimits
    ) throws(AssetError) -> Int {
        guard let value else { return 0 }
        guard let array = value.arrayValues else {
            throw .invalid(context: context, reason: "\(context) deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, context)
        for (i, item) in array.enumerated() where item.objectPairs == nil {
            throw .invalid(context: "\(context)[\(i)]", reason: "elemento deve ser um objeto")
        }
        return array.count
    }

    private static func parseMeshes(
        _ value: JSONValue?,
        accessors: [GLTFAccessor],
        materialCount: Int,
        limits: AssetLimits
    ) throws(AssetError) -> [GLTFMesh] {
        guard let value else { return [] }
        guard let array = value.arrayValues else {
            throw .invalid(context: "meshes", reason: "meshes deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "meshes")
        var result: [GLTFMesh] = []
        result.reserveCapacity(array.count)

        for (i, item) in array.enumerated() {
            let ctx = "meshes[\(i)]"
            guard item.objectPairs != nil else {
                throw .invalid(context: ctx, reason: "mesh deve ser um objeto")
            }
            let name = try optionalString(item.field("name"), context: "\(ctx).name")

            guard let primsVal = item.field("primitives"), let primsArr = primsVal.arrayValues else {
                throw .invalid(
                    context: "\(ctx).primitives", reason: "primitives obrigatório e deve ser array")
            }
            guard !primsArr.isEmpty else {
                throw .invalid(context: "\(ctx).primitives", reason: "primitives não pode ser vazio")
            }
            try checkLimit(primsArr.count, limits.maxElements, "\(ctx).primitives")

            var primitives: [GLTFPrimitive] = []
            primitives.reserveCapacity(primsArr.count)

            for (j, primVal) in primsArr.enumerated() {
                let pCtx = "\(ctx).primitives[\(j)]"
                let prim = try parsePrimitive(
                    primVal,
                    accessors: accessors,
                    materialCount: materialCount,
                    context: pCtx,
                    limits: limits
                )
                primitives.append(prim)
            }

            result.append(GLTFMesh(name: name, primitives: primitives))
        }
        return result
    }

    private static func parsePrimitive(
        _ value: JSONValue,
        accessors: [GLTFAccessor],
        materialCount: Int,
        context: String,
        limits: AssetLimits
    ) throws(AssetError) -> GLTFPrimitive {
        guard value.objectPairs != nil else {
            throw .invalid(context: context, reason: "primitive deve ser um objeto")
        }

        let mode: GLTFPrimitiveMode
        if let modeVal = value.field("mode") {
            let raw = try requireInt(modeVal, context: "\(context).mode")
            guard let parsed = GLTFPrimitiveMode(rawValue: raw) else {
                throw .invalid(context: "\(context).mode", reason: "mode inválido: \(raw)")
            }
            mode = parsed
        } else {
            mode = .triangles
        }

        guard let attrVal = value.field("attributes"), let attrPairs = attrVal.objectPairs else {
            throw .invalid(
                context: "\(context).attributes", reason: "attributes obrigatório e deve ser objeto")
        }
        guard !attrPairs.isEmpty else {
            throw .invalid(context: "\(context).attributes", reason: "attributes não pode ser vazio")
        }
        try checkLimit(attrPairs.count, limits.maxElements, "\(context).attributes")

        var attributes: [(name: String, accessorIndex: Int)] = []
        attributes.reserveCapacity(attrPairs.count)
        var expectedCount: Int?
        var hasPosition = false

        for (attrName, idxVal) in attrPairs {
            let attrCtx = "\(context).attributes.\(attrName)"
            let accIndex = try requireInt(idxVal, context: attrCtx)
            guard accIndex >= 0, accIndex < accessors.count else {
                throw .invalid(context: attrCtx, reason: "índice de accessor fora da faixa")
            }
            let acc = accessors[accIndex]
            if let firstCount = expectedCount {
                guard acc.count == firstCount else {
                    throw .invalid(
                        context: attrCtx,
                        reason: "contagem do atributo (\(acc.count)) difere dos demais (\(firstCount))"
                    )
                }
            } else {
                expectedCount = acc.count
            }
            if attrName == "POSITION" {
                guard acc.type == .vec3 else {
                    throw .invalid(context: attrCtx, reason: "POSITION deve ter tipo VEC3")
                }
                hasPosition = true
            }
            attributes.append((name: attrName, accessorIndex: accIndex))
        }

        if mode.requiresPosition, !hasPosition {
            throw .invalid(context: "\(context).attributes", reason: "atributo POSITION obrigatório ausente")
        }

        let indices: Int?
        if let idxVal = value.field("indices") {
            let idxCtx = "\(context).indices"
            let accIndex = try requireInt(idxVal, context: idxCtx)
            guard accIndex >= 0, accIndex < accessors.count else {
                throw .invalid(context: idxCtx, reason: "índice de accessor fora da faixa")
            }
            let acc = accessors[accIndex]
            guard acc.type == .scalar else {
                throw .invalid(context: idxCtx, reason: "indices deve ser SCALAR")
            }
            guard
                acc.componentType == .unsignedByte
                    || acc.componentType == .unsignedShort
                    || acc.componentType == .unsignedInt
            else {
                throw .invalid(
                    context: idxCtx,
                    reason: "indices deve usar UNSIGNED_BYTE, UNSIGNED_SHORT ou UNSIGNED_INT"
                )
            }
            guard !acc.normalized else {
                throw .invalid(context: idxCtx, reason: "indices não pode ser normalized")
            }
            indices = accIndex
        } else {
            indices = nil
        }

        let material: Int?
        if let matVal = value.field("material") {
            let matCtx = "\(context).material"
            let matIndex = try requireInt(matVal, context: matCtx)
            guard matIndex >= 0, matIndex < materialCount else {
                throw .invalid(context: matCtx, reason: "índice de material fora da faixa")
            }
            material = matIndex
        } else {
            material = nil
        }

        return GLTFPrimitive(attributes: attributes, indices: indices, material: material, mode: mode)
    }

    private static func parseNodes(
        _ value: JSONValue?,
        meshCount: Int,
        limits: AssetLimits
    ) throws(AssetError) -> (nodes: [GLTFNode], parentCounts: [Int]) {
        guard let value else { return ([], []) }
        guard let array = value.arrayValues else {
            throw .invalid(context: "nodes", reason: "nodes deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "nodes")

        var nodes: [GLTFNode] = []
        nodes.reserveCapacity(array.count)
        var parentCounts = [Int](repeating: 0, count: array.count)

        for (i, item) in array.enumerated() {
            let ctx = "nodes[\(i)]"
            guard item.objectPairs != nil else {
                throw .invalid(context: ctx, reason: "node deve ser um objeto")
            }
            let name = try optionalString(item.field("name"), context: "\(ctx).name")

            let mesh: Int?
            if let meshVal = item.field("mesh") {
                let m = try requireInt(meshVal, context: "\(ctx).mesh")
                guard m >= 0, m < meshCount else {
                    throw .invalid(context: "\(ctx).mesh", reason: "índice de mesh fora da faixa")
                }
                mesh = m
            } else {
                mesh = nil
            }

            let children: [Int]
            if let childrenVal = item.field("children") {
                guard let chArr = childrenVal.arrayValues else {
                    throw .invalid(context: "\(ctx).children", reason: "children deve ser um array")
                }
                try checkLimit(chArr.count, limits.maxElements, "\(ctx).children")
                var parsed: [Int] = []
                parsed.reserveCapacity(chArr.count)
                for (k, cVal) in chArr.enumerated() {
                    let cCtx = "\(ctx).children[\(k)]"
                    let c = try requireInt(cVal, context: cCtx)
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
                    parsed.append(c)
                }
                children = parsed
            } else {
                children = []
            }

            let translation = try parseVec3(item.field("translation"), context: "\(ctx).translation")
            let rotation = try parseQuat(item.field("rotation"), context: "\(ctx).rotation")
            let scale = try parseVec3(item.field("scale"), context: "\(ctx).scale")
            let matrix = try parseMat4(item.field("matrix"), context: "\(ctx).matrix")

            if matrix != nil, translation != nil || rotation != nil || scale != nil {
                throw .invalid(context: ctx, reason: "matrix e TRS são mutuamente exclusivos")
            }

            nodes.append(
                GLTFNode(
                    name: name,
                    mesh: mesh,
                    children: children,
                    translation: translation,
                    rotation: rotation,
                    scale: scale,
                    matrix: matrix
                )
            )
        }

        try validateNodeAcyclic(nodes)
        return (nodes, parentCounts)
    }

    private static func validateNodeAcyclic(_ nodes: [GLTFNode]) throws(AssetError) {
        // 0 = não visitado, 1 = na pilha, 2 = concluído (DFS iterativo sem recursão)
        var state = [UInt8](repeating: 0, count: nodes.count)
        var stack: [(node: Int, nextChild: Int)] = []

        for start in nodes.indices where state[start] == 0 {
            state[start] = 1
            stack.append((start, 0))
            while let top = stack.last {
                let u = top.node
                let ci = top.nextChild
                if ci < nodes[u].children.count {
                    stack[stack.count - 1].nextChild = ci + 1
                    let v = nodes[u].children[ci]
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
        _ value: JSONValue?,
        nodeCount: Int,
        parentCounts: [Int],
        limits: AssetLimits
    ) throws(AssetError) -> [GLTFScene] {
        guard let value else { return [] }
        guard let array = value.arrayValues else {
            throw .invalid(context: "scenes", reason: "scenes deve ser um array")
        }
        try checkLimit(array.count, limits.maxElements, "scenes")
        var result: [GLTFScene] = []
        result.reserveCapacity(array.count)

        for (i, item) in array.enumerated() {
            let ctx = "scenes[\(i)]"
            guard item.objectPairs != nil else {
                throw .invalid(context: ctx, reason: "scene deve ser um objeto")
            }
            let name = try optionalString(item.field("name"), context: "\(ctx).name")

            let sceneNodes: [Int]
            if let nodesVal = item.field("nodes") {
                guard let nArr = nodesVal.arrayValues else {
                    throw .invalid(context: "\(ctx).nodes", reason: "nodes deve ser um array")
                }
                try checkLimit(nArr.count, limits.maxElements, "\(ctx).nodes")
                var parsed: [Int] = []
                parsed.reserveCapacity(nArr.count)
                for (k, nVal) in nArr.enumerated() {
                    let nCtx = "\(ctx).nodes[\(k)]"
                    let n = try requireInt(nVal, context: nCtx)
                    guard n >= 0, n < nodeCount else {
                        throw .invalid(context: nCtx, reason: "índice de nó fora da faixa")
                    }
                    guard parentCounts[n] == 0 else {
                        throw .invalid(context: nCtx, reason: "nó raiz de cena possui pai")
                    }
                    guard !parsed.contains(n) else {
                        throw .invalid(context: nCtx, reason: "nó raiz duplicado na cena")
                    }
                    parsed.append(n)
                }
                sceneNodes = parsed
            } else {
                sceneNodes = []
            }

            result.append(GLTFScene(name: name, nodes: sceneNodes))
        }
        return result
    }

    private static func requireInt(_ value: JSONValue, context: String) throws(AssetError) -> Int {
        guard let d = value.numberValue, d.isFinite, let exact = Int(exactly: d) else {
            throw .invalid(context: context, reason: "inteiro esperado")
        }
        return exact
    }

    private static func optionalString(_ value: JSONValue?, context: String) throws(AssetError) -> String? {
        guard let value else { return nil }
        guard let s = value.stringValue else {
            throw .invalid(context: context, reason: "string esperada")
        }
        return s
    }

    private static func parseFloatArray(
        _ value: JSONValue?,
        expectedCount: Int,
        context: String
    ) throws(AssetError) -> [Float]? {
        guard let value else { return nil }
        guard let arr = value.arrayValues else {
            throw .invalid(context: context, reason: "array de números esperado")
        }
        guard arr.count == expectedCount else {
            throw .invalid(context: context, reason: "esperados \(expectedCount) componentes")
        }
        var floats: [Float] = []
        floats.reserveCapacity(expectedCount)
        for (i, elem) in arr.enumerated() {
            guard let d = elem.numberValue else {
                throw .invalid(context: "\(context)[\(i)]", reason: "número esperado")
            }
            let f = Float(d)
            guard f.isFinite else {
                throw .invalid(context: "\(context)[\(i)]", reason: "valor fora da faixa finita de Float")
            }
            floats.append(f)
        }
        return floats
    }

    private static func parseVec3(_ value: JSONValue?, context: String) throws(AssetError) -> CajuVec3? {
        guard let f = try parseFloatArray(value, expectedCount: 3, context: context) else { return nil }
        return CajuVec3(f[0], f[1], f[2])
    }

    private static func parseQuat(_ value: JSONValue?, context: String) throws(AssetError) -> CajuQuat? {
        guard let f = try parseFloatArray(value, expectedCount: 4, context: context) else { return nil }
        return CajuQuat(x: f[0], y: f[1], z: f[2], w: f[3])
    }

    private static func parseMat4(_ value: JSONValue?, context: String) throws(AssetError) -> CajuMat4? {
        guard let f = try parseFloatArray(value, expectedCount: 16, context: context) else { return nil }
        return CajuMat4(
            columns: SIMD4(f[0], f[1], f[2], f[3]),
            SIMD4(f[4], f[5], f[6], f[7]),
            SIMD4(f[8], f[9], f[10], f[11]),
            SIMD4(f[12], f[13], f[14], f[15])
        )
    }
}

/// Documento glTF 2.0 validado (estrutura em memória sem decodificar URIs externas).
public struct GLTFDocument: Sendable, Equatable {
    /// Metadados obrigatórios de versão do documento.
    public let asset: GLTFAsset
    /// Lista de buffers declarados.
    public let buffers: [GLTFBuffer]
    /// Lista de fatias (`bufferViews`) sobre os buffers.
    public let bufferViews: [GLTFBufferView]
    /// Lista de descritores de leitura tipada (`accessors`).
    public let accessors: [GLTFAccessor]
    /// Malhas e suas primitivas.
    public let meshes: [GLTFMesh]
    /// Grafo acíclico de nós da cena.
    public let nodes: [GLTFNode]
    /// Cenas raiz declaradas.
    public let scenes: [GLTFScene]
    /// Índice da cena padrão em `scenes`, quando presente.
    public let scene: Int?
    /// Quantidade de materiais declarados.
    public let materialCount: Int
    /// Quantidade de texturas declaradas.
    public let textureCount: Int
    /// Quantidade de imagens declaradas.
    public let imageCount: Int
    /// Faixa de bytes do chunk `BIN` na entrada original quando o arquivo é `.glb`.
    public let glbBinary: Range<Int>?

    /// Calcula o layout validado para leitura direta dos bytes de `accessors[index]`.
    public func accessorLayout(_ index: Int) throws(AssetError) -> GLTFAccessorLayout {
        guard index >= 0, index < accessors.count else {
            throw .invalid(context: "accessors[\(index)]", reason: "índice de accessor fora da faixa")
        }
        let acc = accessors[index]
        guard let bvIndex = acc.bufferView else {
            throw .invalid(context: "accessors[\(index)].bufferView", reason: "accessor sem bufferView")
        }
        let bv = bufferViews[bvIndex]
        let absoluteOffset = try checkedAdd(bv.byteOffset, acc.byteOffset, "accessors[\(index)].byteOffset")
        let stride = bv.byteStride ?? acc.elementSize
        return GLTFAccessorLayout(
            buffer: bv.buffer,
            byteOffset: absoluteOffset,
            stride: stride,
            count: acc.count,
            elementSize: acc.elementSize
        )
    }
}

/// Metadados `asset` de um documento glTF 2.0.
public struct GLTFAsset: Sendable, Equatable {
    /// Versão da especificação glTF (formato `"2.x"`).
    public let version: String
}

/// Declaração de um buffer glTF.
public struct GLTFBuffer: Sendable, Equatable {
    /// Tamanho do buffer em bytes.
    public let byteLength: Int
    /// URI opcional (caminho relativo ou `data:`, não decodificada por `CajuAssetsCore`).
    public let uri: String?
}

/// Alvo sugerido de vinculação na GPU para uma `GLTFBufferView`.
public enum GLTFBufferTarget: Int, Sendable, Equatable {
    /// `ARRAY_BUFFER` (34962), atributos de vértice.
    case arrayBuffer = 34962
    /// `ELEMENT_ARRAY_BUFFER` (34963), índices de primitiva.
    case elementArrayBuffer = 34963
}

/// Fatia contígua de um `GLTFBuffer`.
public struct GLTFBufferView: Sendable, Equatable {
    /// Índice em `GLTFDocument.buffers`.
    public let buffer: Int
    /// Deslocamento inicial em bytes no buffer.
    public let byteOffset: Int
    /// Comprimento da fatia em bytes.
    public let byteLength: Int
    /// Passo entre elementos consecutivos em bytes (`4...252`, múltiplo de 4), quando intercalado.
    public let byteStride: Int?
    /// Alvo opcional da GPU.
    public let target: GLTFBufferTarget?
}

/// Tipo numérico de cada componente de um `GLTFAccessor`.
public enum GLTFComponentType: Int, Sendable, Equatable {
    /// Inteiro com sinal de 8 bits (`5120`).
    case byte = 5120
    /// Inteiro sem sinal de 8 bits (`5121`).
    case unsignedByte = 5121
    /// Inteiro com sinal de 16 bits (`5122`).
    case short = 5122
    /// Inteiro sem sinal de 16 bits (`5123`).
    case unsignedShort = 5123
    /// Inteiro sem sinal de 32 bits (`5125`).
    case unsignedInt = 5125
    /// Ponto flutuante IEEE 754 de 32 bits (`5126`).
    case float = 5126

    /// Tamanho em bytes de um componente escalar.
    public var byteSize: Int {
        switch self {
        case .byte, .unsignedByte: 1
        case .short, .unsignedShort: 2
        case .unsignedInt, .float: 4
        }
    }
}

/// Forma algébrica de cada elemento de um `GLTFAccessor`.
public enum GLTFAccessorType: String, Sendable, Equatable {
    case scalar = "SCALAR"
    case vec2 = "VEC2"
    case vec3 = "VEC3"
    case vec4 = "VEC4"
    case mat2 = "MAT2"
    case mat3 = "MAT3"
    case mat4 = "MAT4"

    /// Quantidade de componentes escalares por elemento.
    public var componentCount: Int {
        switch self {
        case .scalar: 1
        case .vec2: 2
        case .vec3: 3
        case .vec4, .mat2: 4
        case .mat3: 9
        case .mat4: 16
        }
    }
}

/// Descritor de acesso tipado sobre uma `GLTFBufferView`.
public struct GLTFAccessor: Sendable, Equatable {
    /// Índice opcional em `GLTFDocument.bufferViews`.
    public let bufferView: Int?
    /// Deslocamento inicial em bytes dentro da `bufferView`.
    public let byteOffset: Int
    /// Tipo escalar de cada componente.
    public let componentType: GLTFComponentType
    /// Indica se inteiros devem ser normalizados para `[0, 1]` ou `[-1, 1]`.
    public let normalized: Bool
    /// Quantidade de elementos.
    public let count: Int
    /// Quantidade/arranjo de componentes por elemento.
    public let type: GLTFAccessorType
    /// Tamanho em bytes de um elemento (incluindo alinhamento de colunas de matrizes).
    public let elementSize: Int
    /// Valores mínimos opcionais por componente.
    public let min: [Double]?
    /// Valores máximos opcionais por componente.
    public let max: [Double]?
}

/// Layout absoluto pré-validado para leitura de um `GLTFAccessor` em seu buffer.
public struct GLTFAccessorLayout: Sendable, Equatable {
    /// Índice em `GLTFDocument.buffers`.
    public let buffer: Int
    /// Deslocamento absoluto em bytes a partir do início do buffer.
    public let byteOffset: Int
    /// Passo efetivo em bytes entre elementos consecutivos.
    public let stride: Int
    /// Quantidade de elementos.
    public let count: Int
    /// Tamanho útil de cada elemento em bytes.
    public let elementSize: Int
}

/// Topologia de desenho de uma `GLTFPrimitive`.
public enum GLTFPrimitiveMode: Int, Sendable, Equatable {
    case points = 0
    case lines = 1
    case lineLoop = 2
    case lineStrip = 3
    case triangles = 4
    case triangleStrip = 5
    case triangleFan = 6

    var requiresPosition: Bool {
        true
    }
}

/// Subconjunto desenhável de uma `GLTFMesh`.
public struct GLTFPrimitive: Sendable, Equatable {
    /// Pares `(nomeSemântico, índiceDeAccessor)` preservando a ordem do JSON.
    public let attributes: [(name: String, accessorIndex: Int)]
    /// Índice opcional de accessor de índices escalares.
    public let indices: Int?
    /// Índice opcional de material.
    public let material: Int?
    /// Topologia da primitiva.
    public let mode: GLTFPrimitiveMode

    public static func == (lhs: GLTFPrimitive, rhs: GLTFPrimitive) -> Bool {
        guard lhs.indices == rhs.indices,
            lhs.material == rhs.material,
            lhs.mode == rhs.mode,
            lhs.attributes.count == rhs.attributes.count
        else {
            return false
        }
        for i in lhs.attributes.indices {
            if lhs.attributes[i].name != rhs.attributes[i].name
                || lhs.attributes[i].accessorIndex != rhs.attributes[i].accessorIndex
            {
                return false
            }
        }
        return true
    }
}

/// Malha composta por uma ou mais primitivas.
public struct GLTFMesh: Sendable, Equatable {
    /// Nome opcional da malha.
    public let name: String?
    /// Lista não vazia de primitivas.
    public let primitives: [GLTFPrimitive]
}

/// Nó da hierarquia espacial de um documento glTF.
public struct GLTFNode: Sendable, Equatable {
    /// Nome opcional do nó.
    public let name: String?
    /// Índice opcional da malha associada em `GLTFDocument.meshes`.
    public let mesh: Int?
    /// Índices dos nós filhos em `GLTFDocument.nodes`.
    public let children: [Int]
    /// Translação local opcional.
    public let translation: CajuVec3?
    /// Rotação local opcional (quaternion `x, y, z, w`).
    public let rotation: CajuQuat?
    /// Escala local opcional.
    public let scale: CajuVec3?
    /// Matriz 4×4 local em ordem de colunas (mutuamente exclusiva com TRS).
    public let matrix: CajuMat4?
}

/// Cena raiz referenciando nós de topo.
public struct GLTFScene: Sendable, Equatable {
    /// Nome opcional da cena.
    public let name: String?
    /// Índices de nós raiz em `GLTFDocument.nodes`.
    public let nodes: [Int]
}
