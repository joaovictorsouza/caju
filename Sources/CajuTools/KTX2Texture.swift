import Foundation

/// Formato de saída suportado pelo subcomando `texture`.
public enum KTX2OutputFormat: String, Sendable, Equatable {
    /// RGBA8 não comprimido no espaço sRGB (`VK_FORMAT_R8G8B8A8_SRGB = 43`).
    case rgba8SRGB = "rgba8-srgb"
    /// RGBA8 não comprimido linear (`VK_FORMAT_R8G8B8A8_UNORM = 37`).
    case rgba8UNorm = "rgba8-unorm"
    /// ASTC 4×4 (ainda indisponível sem encoder externo / dependência C).
    case astc4x4 = "astc-4x4"

    var vkFormat: UInt32 {
        switch self {
        case .rgba8SRGB: 43
        case .rgba8UNorm: 37
        case .astc4x4: 0
        }
    }

    var transferFunction: UInt8 {
        switch self {
        case .rgba8SRGB: 2
        case .rgba8UNorm: 1
        case .astc4x4: 0
        }
    }

    static func parse(_ raw: String) -> KTX2OutputFormat? {
        switch raw.lowercased() {
        case "rgba8", "rgba8-srgb", "srgb":
            .rgba8SRGB
        case "rgba8-unorm", "rgba8-linear", "unorm", "linear":
            .rgba8UNorm
        case "astc", "astc-4x4", "astc-4x4-srgb", "astc-4x4-unorm":
            .astc4x4
        default:
            nil
        }
    }
}

/// Resumo validado de um contêiner KTX 2.0.
public struct KTX2ValidationSummary: Sendable, Equatable {
    public let vkFormat: UInt32
    public let typeSize: UInt32
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let pixelDepth: UInt32
    public let layerCount: UInt32
    public let faceCount: UInt32
    public let levelCount: UInt32
    public let supercompressionScheme: UInt32
    public let colorModel: UInt8
    public let transferFunction: UInt8
    public let dfdFlags: UInt8
    public let kvdCount: Int
    public let byteCount: Int
}

/// Codificador KTX2 RGBA8 e validador estrito de contêineres KTX 2.0.
///
/// - Note: Codificação ASTC real não está disponível sem dependência C/encoder externo
///   (ADR 0017); `encodeRGBA8` gera KTX 2.0 não comprimido em RGBA8 e valida o arquivo resultante.
public enum KTX2Codec {
    static let identifier: [UInt8] = [
        0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A,
    ]
    private static let headerSize = 80
    private static let levelEntrySize = 24
    private static let minimumDFDSize = 28
    private static let kdfsColorModelETC1S: UInt8 = 163
    private static let kdfsColorModelUASTC: UInt8 = 166

    /// Codifica pixels RGBA8 em um contêiner KTX 2.0 determinístico e o valida antes de retornar.
    public static func encodeRGBA8(
        width: Int,
        height: Int,
        pixels: [UInt8],
        format: KTX2OutputFormat = .rgba8SRGB,
        generateMipmaps: Bool = false,
        limits: ToolsLimits = .default
    ) throws(CajuToolsError) -> [UInt8] {
        guard format != .astc4x4 else {
            throw .unsupported(
                context: "texture.format",
                reason:
                    "codificação ASTC indisponível sem encoder externo/dependência C (ADR 0017); use rgba8-srgb ou rgba8-unorm"
            )
        }
        guard width > 0, height > 0 else {
            throw .invalid(context: "texture.dimensions", reason: "largura e altura devem ser > 0")
        }
        try checkLimit(width, limits.maxImageDimension, "texture.width")
        try checkLimit(height, limits.maxImageDimension, "texture.height")

        let expectedBytes = try checkedMul(try checkedMul(width, height, "texture.size"), 4, "texture.size")
        try checkLimit(expectedBytes, limits.maxOutputBytes, "texture.output")
        guard pixels.count == expectedBytes else {
            throw .invalid(
                context: "texture.pixels",
                reason: "contagem de bytes (\(pixels.count)) difere de \(expectedBytes)"
            )
        }

        let levels = buildMipChain(
            width: width,
            height: height,
            basePixels: pixels,
            generateMipmaps: generateMipmaps
        )
        try checkLimit(levels.count, limits.maxMipLevels, "texture.levelCount")

        let dfd = buildRGBA8DFD(transferFunction: format.transferFunction, isSRGB: format == .rgba8SRGB)
        let kvd = buildKVD([("KTXwriter", Array("caju-tools".utf8))])

        var out: [UInt8] = []
        let totalLevelBytes = levels.reduce(0) { $0 + $1.count }
        out.reserveCapacity(
            headerSize + levels.count * levelEntrySize + dfd.count + kvd.count + totalLevelBytes + 32)

        out.append(contentsOf: identifier)
        appendU32LE(format.vkFormat, to: &out)
        appendU32LE(1, to: &out)  // typeSize = 1 byte por canal
        appendU32LE(UInt32(width), to: &out)
        appendU32LE(UInt32(height), to: &out)
        appendU32LE(0, to: &out)  // pixelDepth (2D)
        appendU32LE(0, to: &out)  // layerCount (não array)
        appendU32LE(1, to: &out)  // faceCount
        appendU32LE(UInt32(levels.count), to: &out)
        appendU32LE(0, to: &out)  // supercompressionScheme = none

        // Offsets/tamanhos DFD, KVD e SGD (preenchidos abaixo)
        for _ in 0..<32 { out.append(0) }
        // Índice de níveis (preenchido abaixo)
        for _ in 0..<(levels.count * levelEntrySize) { out.append(0) }

        padToAlignment(4, buffer: &out)
        let dfdOffset = UInt32(out.count)
        out.append(contentsOf: dfd)
        writeU32LE(dfdOffset, at: 48, in: &out)
        writeU32LE(UInt32(dfd.count), at: 52, in: &out)

        padToAlignment(4, buffer: &out)
        let kvdOffset = UInt32(out.count)
        out.append(contentsOf: kvd)
        writeU32LE(kvdOffset, at: 56, in: &out)
        writeU32LE(UInt32(kvd.count), at: 60, in: &out)

        // KTX 2.0 exige níveis armazenados do menor para o maior (nível 0 por último)
        for i in stride(from: levels.count - 1, through: 0, by: -1) {
            padToAlignment(4, buffer: &out)
            let levelOffset = UInt64(out.count)
            let levelBytes = levels[i]
            out.append(contentsOf: levelBytes)
            let entryBase = headerSize + i * levelEntrySize
            let len = UInt64(levelBytes.count)
            writeU64LE(levelOffset, at: entryBase, in: &out)
            writeU64LE(len, at: entryBase + 8, in: &out)
            writeU64LE(len, at: entryBase + 16, in: &out)
        }

        _ = try validate(out, limits: limits)
        return out
    }

    /// Valida estritamente cabeçalho, DFD, KVD e índice de níveis de um contêiner KTX 2.0.
    public static func validate(
        _ bytes: [UInt8],
        limits: ToolsLimits = .default
    ) throws(CajuToolsError) -> KTX2ValidationSummary {
        try checkLimit(bytes.count, limits.maxInputBytes, "ktx2.input")
        var reader = ToolsByteReader(bytes)
        let magic = try reader.readBytes(identifier.count, context: "ktx2.identifier")
        guard magic == identifier else {
            throw .invalid(context: "ktx2.identifier", reason: "assinatura KTX 2.0 inválida")
        }

        let vkFormat = try reader.readU32LE("ktx2.header.vkFormat")
        let typeSize = try reader.readU32LE("ktx2.header.typeSize")
        let pixelWidth = try reader.readU32LE("ktx2.header.pixelWidth")
        let pixelHeight = try reader.readU32LE("ktx2.header.pixelHeight")
        let pixelDepth = try reader.readU32LE("ktx2.header.pixelDepth")
        let layerCount = try reader.readU32LE("ktx2.header.layerCount")
        let faceCount = try reader.readU32LE("ktx2.header.faceCount")
        let levelCount = try reader.readU32LE("ktx2.header.levelCount")
        let schemeRaw = try reader.readU32LE("ktx2.header.supercompressionScheme")
        let dfdByteOffset = try reader.readU32LE("ktx2.header.dfdByteOffset")
        let dfdByteLength = try reader.readU32LE("ktx2.header.dfdByteLength")
        let kvdByteOffset = try reader.readU32LE("ktx2.header.kvdByteOffset")
        let kvdByteLength = try reader.readU32LE("ktx2.header.kvdByteLength")
        let sgdByteOffset = try reader.readU64LE("ktx2.header.sgdByteOffset")
        let sgdByteLength = try reader.readU64LE("ktx2.header.sgdByteLength")

        guard pixelWidth > 0 else {
            throw .invalid(context: "ktx2.pixelWidth", reason: "pixelWidth deve ser maior que zero")
        }
        if pixelDepth > 0 && pixelHeight == 0 {
            throw .invalid(context: "ktx2.pixelHeight", reason: "pixelHeight deve ser > 0 para 3D")
        }
        _ = try checkLimitUInt64(UInt64(pixelWidth), limits.maxImageDimension, "ktx2.pixelWidth")
        _ = try checkLimitUInt64(UInt64(pixelHeight), limits.maxImageDimension, "ktx2.pixelHeight")
        _ = try checkLimitUInt64(UInt64(pixelDepth), limits.maxImageDimension, "ktx2.pixelDepth")

        guard faceCount == 1 || faceCount == 6 else {
            throw .invalid(context: "ktx2.faceCount", reason: "faceCount deve ser 1 ou 6")
        }
        if faceCount == 6 {
            guard pixelWidth == pixelHeight, pixelDepth == 0 else {
                throw .invalid(
                    context: "ktx2.faceCount", reason: "cubemap exige largura == altura e depth == 0")
            }
        }
        guard schemeRaw <= 3 else {
            throw .invalid(
                context: "ktx2.supercompressionScheme",
                reason: "supercompressionScheme desconhecido: \(schemeRaw)"
            )
        }

        let actualLevels = try validateLevelCount(
            levelCount,
            width: pixelWidth,
            height: pixelHeight,
            depth: pixelDepth,
            limits: limits
        )
        let levelIndexBytes = try checkedMul(actualLevels, levelEntrySize, "ktx2.levelIndex")
        let metadataEnd = try checkedAdd(headerSize, levelIndexBytes, "ktx2.levelIndex")
        guard bytes.count >= metadataEnd else {
            throw .truncated(context: "ktx2.levelIndex")
        }

        let dfdRange = try validateSectionRange(
            offset: UInt64(dfdByteOffset),
            length: UInt64(dfdByteLength),
            metadataEnd: metadataEnd,
            inputCount: bytes.count,
            allowZero: false,
            alignment: 4,
            context: "ktx2.dfd"
        )
        let kvdRange = try validateSectionRange(
            offset: UInt64(kvdByteOffset),
            length: UInt64(kvdByteLength),
            metadataEnd: metadataEnd,
            inputCount: bytes.count,
            allowZero: true,
            alignment: 4,
            context: "ktx2.kvd"
        )
        let sgdRange = try validateSectionRange(
            offset: sgdByteOffset,
            length: sgdByteLength,
            metadataEnd: metadataEnd,
            inputCount: bytes.count,
            allowZero: true,
            alignment: 8,
            context: "ktx2.sgd"
        )

        guard let dfdRange, dfdRange.count >= minimumDFDSize else {
            throw .invalid(context: "ktx2.dfd", reason: "DFD ausente ou menor que 28 bytes")
        }
        if let kvdRange, kvdRange.count % 4 != 0 {
            throw .invalid(context: "ktx2.kvd", reason: "kvdByteLength deve ser múltiplo de 4")
        }
        if schemeRaw == 0, sgdRange != nil {
            throw .invalid(context: "ktx2.sgd", reason: "SGD proibido quando supercompressionScheme == 0")
        }

        var sectionRanges: [(String, Range<Int>)] = [("dfd", dfdRange)]
        if let kvdRange { sectionRanges.append(("kvd", kvdRange)) }
        if let sgdRange { sectionRanges.append(("sgd", sgdRange)) }
        for i in 0..<sectionRanges.count {
            for j in (i + 1)..<sectionRanges.count {
                if rangesOverlap(sectionRanges[i].1, sectionRanges[j].1) {
                    throw .invalid(
                        context: "ktx2.\(sectionRanges[i].0)",
                        reason: "seção \(sectionRanges[i].0) sobrepõe \(sectionRanges[j].0)"
                    )
                }
            }
        }

        try validateLevels(
            &reader,
            count: actualLevels,
            scheme: schemeRaw,
            metadataEnd: metadataEnd,
            inputCount: bytes.count,
            sectionRanges: sectionRanges,
            limits: limits
        )

        let dfd = try parseDFD(bytes, range: dfdRange)
        if vkFormat == 0 {
            let isBasis =
                schemeRaw == 1
                || dfd.colorModel == kdfsColorModelETC1S
                || dfd.colorModel == kdfsColorModelUASTC
            guard isBasis else {
                throw .invalid(
                    context: "ktx2.vkFormat",
                    reason: "vkFormat UNDEFINED (0) exige BasisLZ ou DFD Basis (ETC1S/UASTC)"
                )
            }
        }

        let kvdCount = try countAndValidateKVD(bytes, range: kvdRange, maxElements: limits.maxElements)

        return KTX2ValidationSummary(
            vkFormat: vkFormat,
            typeSize: typeSize,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pixelDepth: pixelDepth,
            layerCount: layerCount,
            faceCount: faceCount,
            levelCount: levelCount,
            supercompressionScheme: schemeRaw,
            colorModel: dfd.colorModel,
            transferFunction: dfd.transferFunction,
            dfdFlags: dfd.flags,
            kvdCount: kvdCount,
            byteCount: bytes.count
        )
    }

    // MARK: - Helpers privados de geração e validação

    private static func buildMipChain(
        width: Int,
        height: Int,
        basePixels: [UInt8],
        generateMipmaps: Bool
    ) -> [[UInt8]] {
        var levels: [[UInt8]] = [basePixels]
        guard generateMipmaps else { return levels }

        var currW = width
        var currH = height
        var curr = basePixels
        while currW > 1 || currH > 1 {
            let nextW = max(1, currW / 2)
            let nextH = max(1, currH / 2)
            var next = [UInt8](repeating: 0, count: nextW * nextH * 4)
            for y in 0..<nextH {
                let sy0 = min(currH - 1, y * 2)
                let sy1 = min(currH - 1, sy0 + 1)
                for x in 0..<nextW {
                    let sx0 = min(currW - 1, x * 2)
                    let sx1 = min(currW - 1, sx0 + 1)
                    let i00 = (sy0 * currW + sx0) * 4
                    let i10 = (sy0 * currW + sx1) * 4
                    let i01 = (sy1 * currW + sx0) * 4
                    let i11 = (sy1 * currW + sx1) * 4
                    let dst = (y * nextW + x) * 4
                    for c in 0..<4 {
                        let sum =
                            Int(curr[i00 + c]) + Int(curr[i10 + c]) + Int(curr[i01 + c]) + Int(curr[i11 + c])
                        next[dst + c] = UInt8((sum + 2) / 4)
                    }
                }
            }
            levels.append(next)
            currW = nextW
            currH = nextH
            curr = next
        }
        return levels
    }

    private static func buildRGBA8DFD(transferFunction: UInt8, isSRGB: Bool) -> [UInt8] {
        let blockSize: UInt32 = 24 + 16 * 4  // 88 bytes
        let totalSize: UInt32 = 4 + blockSize  // 92 bytes
        var dfd: [UInt8] = []
        dfd.reserveCapacity(Int(totalSize))
        appendU32LE(totalSize, to: &dfd)
        appendU32LE(0, to: &dfd)  // vendorId=0, descriptorType=0
        appendU32LE(2 | (blockSize << 16), to: &dfd)
        dfd.append(2)  // KHR_DF_MODEL_RGBSDA
        dfd.append(1)  // KHR_DF_PRIMARIES_BT709
        dfd.append(transferFunction)
        dfd.append(0)  // flags = straight alpha
        for _ in 0..<4 { dfd.append(0) }  // texelBlockDimension 1x1x1x1 (armazenado como dim - 1)
        dfd.append(4)  // bytesPlane0 = 4 bytes por texel
        for _ in 0..<7 { dfd.append(0) }  // bytesPlane1..7

        let channels: [UInt8] = [0, 1, 2, isSRGB ? (15 | 0x10) : 15]
        for (idx, channelType) in channels.enumerated() {
            let bitOffset = UInt32(idx * 8)
            let bitLength: UInt32 = 7
            let word0 = bitOffset | (bitLength << 16) | (UInt32(channelType) << 24)
            appendU32LE(word0, to: &dfd)
            appendU32LE(0, to: &dfd)  // samplePosition
            appendU32LE(0, to: &dfd)  // sampleLower
            appendU32LE(255, to: &dfd)  // sampleUpper
        }
        return dfd
    }

    private static func buildKVD(_ pairs: [(String, [UInt8])]) -> [UInt8] {
        var kvd: [UInt8] = []
        for (key, value) in pairs {
            let keyBytes = Array(key.utf8)
            let entryLength = keyBytes.count + 1 + value.count
            appendU32LE(UInt32(entryLength), to: &kvd)
            kvd.append(contentsOf: keyBytes)
            kvd.append(0)
            kvd.append(contentsOf: value)
            let padding = (4 - (entryLength & 3)) & 3
            for _ in 0..<padding { kvd.append(0) }
        }
        return kvd
    }

    private static func validateLevelCount(
        _ levelCount: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        limits: ToolsLimits
    ) throws(CajuToolsError) -> Int {
        if levelCount == 0 {
            return try checkLimitUInt64(1, limits.maxMipLevels, "ktx2.levelCount")
        }
        let validated = try checkLimitUInt64(UInt64(levelCount), limits.maxMipLevels, "ktx2.levelCount")
        let maxDim = max(width, max(height, depth))
        let maxPossible = UInt32(UInt32.bitWidth - maxDim.leadingZeroBitCount)
        guard levelCount <= maxPossible else {
            throw .invalid(
                context: "ktx2.levelCount",
                reason: "levelCount (\(levelCount)) excede máximo (\(maxPossible)) para dimensões"
            )
        }
        return validated
    }

    private static func validateSectionRange(
        offset: UInt64,
        length: UInt64,
        metadataEnd: Int,
        inputCount: Int,
        allowZero: Bool,
        alignment: Int,
        context: String
    ) throws(CajuToolsError) -> Range<Int>? {
        if length == 0 {
            guard allowZero else {
                throw .invalid(context: context, reason: "comprimento obrigatório não pode ser zero")
            }
            guard offset == 0 else {
                throw .invalid(context: context, reason: "offset deve ser zero quando comprimento é zero")
            }
            return nil
        }
        guard let start = Int(exactly: offset), let byteLen = Int(exactly: length) else {
            throw .invalid(context: context, reason: "offset ou comprimento excede Int")
        }
        let end = try checkedAdd(start, byteLen, context)
        guard start >= metadataEnd else {
            throw .invalid(context: context, reason: "seção sobrepõe cabeçalho ou índice de níveis")
        }
        guard start % alignment == 0 else {
            throw .invalid(context: context, reason: "offset desalinhado (esperado múltiplo de \(alignment))")
        }
        guard end <= inputCount else {
            throw .truncated(context: context)
        }
        return start..<end
    }

    private static func validateLevels(
        _ reader: inout ToolsByteReader,
        count: Int,
        scheme: UInt32,
        metadataEnd: Int,
        inputCount: Int,
        sectionRanges: [(String, Range<Int>)],
        limits: ToolsLimits
    ) throws(CajuToolsError) {
        var totalUncompressed = 0
        var prevStart = Int.max
        for i in 0..<count {
            let ctx = "ktx2.levels[\(i)]"
            let byteOffset = try reader.readU64LE("\(ctx).byteOffset")
            let byteLength = try reader.readU64LE("\(ctx).byteLength")
            let uncompressedLength = try reader.readU64LE("\(ctx).uncompressedByteLength")

            guard byteLength > 0 else {
                throw .invalid(context: "\(ctx).byteLength", reason: "byteLength deve ser > 0")
            }
            guard let start = Int(exactly: byteOffset), let len = Int(exactly: byteLength) else {
                throw .invalid(context: ctx, reason: "offset ou comprimento excede Int")
            }
            let end = try checkedAdd(start, len, ctx)
            guard start >= metadataEnd else {
                throw .invalid(context: ctx, reason: "nível sobrepõe cabeçalho ou índice de níveis")
            }
            guard end <= inputCount else {
                throw .truncated(context: ctx)
            }
            if scheme == 0 {
                guard start % 4 == 0 else {
                    throw .invalid(
                        context: "\(ctx).byteOffset", reason: "nível sem supercompressão deve alinhar em 4")
                }
                guard byteLength == uncompressedLength else {
                    throw .invalid(
                        context: ctx, reason: "scheme == 0 exige byteLength == uncompressedByteLength")
                }
            }
            let levelUncompressed = try checkLimitUInt64(
                uncompressedLength,
                limits.maxOutputBytes,
                "\(ctx).uncompressedByteLength"
            )
            totalUncompressed = try checkedAdd(totalUncompressed, levelUncompressed, "ktx2.uncompressed")
            try checkLimit(totalUncompressed, limits.maxOutputBytes, "ktx2.uncompressed")

            if i > 0 {
                guard end <= prevStart else {
                    throw .invalid(
                        context: ctx, reason: "níveis devem estar em ordem decrescente sem sobreposição")
                }
            }
            prevStart = start

            let levelRange = start..<end
            for (name, range) in sectionRanges where rangesOverlap(levelRange, range) {
                throw .invalid(context: ctx, reason: "nível sobrepõe seção \(name)")
            }
        }
    }

    private static func parseDFD(
        _ bytes: [UInt8],
        range: Range<Int>
    ) throws(CajuToolsError) -> (colorModel: UInt8, transferFunction: UInt8, flags: UInt8) {
        var reader = ToolsByteReader(bytes, offset: range.lowerBound)
        let totalSize = try reader.readU32LE("ktx2.dfd.totalSize")
        guard Int(exactly: totalSize) == range.count else {
            throw .invalid(context: "ktx2.dfd.totalSize", reason: "totalSize diverge de dfdByteLength")
        }
        let word0 = try reader.readU32LE("ktx2.dfd.vendorAndType")
        guard (word0 & 0x1FFFF) == 0, ((word0 >> 17) & 0x7FFF) == 0 else {
            throw .invalid(
                context: "ktx2.dfd.descriptorType", reason: "bloco DFD inicial deve ser básico Khronos")
        }
        let word1 = try reader.readU32LE("ktx2.dfd.versionAndSize")
        let versionNumber = word1 & 0xFFFF
        let blockSize = (word1 >> 16) & 0xFFFF
        guard versionNumber == 2 else {
            throw .invalid(context: "ktx2.dfd.versionNumber", reason: "versão DFD inválida (esperado 2)")
        }
        guard blockSize >= 24, (blockSize - 24) % 16 == 0 else {
            throw .invalid(context: "ktx2.dfd.descriptorBlockSize", reason: "tamanho de bloco DFD inválido")
        }
        let blockEnd = try checkedAdd(4, Int(blockSize), "ktx2.dfd.descriptorBlockSize")
        guard blockEnd <= range.count else {
            throw .truncated(context: "ktx2.dfd.descriptorBlockSize")
        }
        let colorModel = try reader.readU8("ktx2.dfd.colorModel")
        _ = try reader.readU8("ktx2.dfd.colorPrimaries")
        let transferFunction = try reader.readU8("ktx2.dfd.transferFunction")
        let flags = try reader.readU8("ktx2.dfd.flags")

        guard isValidKDFSColorModel(colorModel) else {
            throw .invalid(context: "ktx2.dfd.colorModel", reason: "colorModel inválido: \(colorModel)")
        }
        guard transferFunction <= 18 else {
            throw .invalid(context: "ktx2.dfd.transferFunction", reason: "transferFunction inválido")
        }
        guard flags <= 1 else {
            throw .invalid(context: "ktx2.dfd.flags", reason: "flags de DFD inválidas")
        }
        return (colorModel, transferFunction, flags)
    }

    private static func isValidKDFSColorModel(_ model: UInt8) -> Bool {
        switch model {
        case 0...15, 128...134, 160...166: true
        default: false
        }
    }

    private static func countAndValidateKVD(
        _ bytes: [UInt8],
        range: Range<Int>?,
        maxElements: Int
    ) throws(CajuToolsError) -> Int {
        guard let range else { return 0 }
        var reader = ToolsByteReader(bytes, offset: range.lowerBound)
        let end = range.upperBound
        var count = 0

        while reader.offset < end {
            count = try checkedAdd(count, 1, "ktx2.kvd")
            try checkLimit(count, maxElements, "ktx2.kvd")
            let entryLengthU32 = try reader.readU32LE("ktx2.kvd.keyAndValueByteLength")
            guard entryLengthU32 > 0, let entryLength = Int(exactly: entryLengthU32) else {
                throw .invalid(context: "ktx2.kvd", reason: "tamanho de entrada KVD inválido")
            }
            let payloadStart = reader.offset
            let payloadEnd = try checkedAdd(payloadStart, entryLength, "ktx2.kvd")
            guard payloadEnd <= end else {
                throw .truncated(context: "ktx2.kvd")
            }
            var nulPos: Int?
            for idx in payloadStart..<payloadEnd where bytes[idx] == 0 {
                nulPos = idx
                break
            }
            guard let nulPos, nulPos > payloadStart else {
                throw .invalid(context: "ktx2.kvd.key", reason: "chave KVD vazia ou sem NUL")
            }
            if nulPos - payloadStart >= 3
                && bytes[payloadStart] == 0xEF
                && bytes[payloadStart + 1] == 0xBB
                && bytes[payloadStart + 2] == 0xBF
            {
                throw .invalid(context: "ktx2.kvd.key", reason: "chave KVD não pode conter BOM UTF-8")
            }
            let key = String(decoding: bytes[payloadStart..<nulPos], as: UTF8.self)
            guard key.utf8.elementsEqual(bytes[payloadStart..<nulPos]) else {
                throw .invalid(context: "ktx2.kvd.key", reason: "chave KVD não é UTF-8 válido")
            }
            let padding = (4 - (entryLength & 3)) & 3
            let nextOffset = try checkedAdd(payloadEnd, padding, "ktx2.kvd.padding")
            guard nextOffset <= end else {
                throw .truncated(context: "ktx2.kvd.padding")
            }
            for padIdx in payloadEnd..<nextOffset where bytes[padIdx] != 0 {
                throw .invalid(context: "ktx2.kvd.padding", reason: "padding KVD deve ser zero")
            }
            try reader.seek(to: nextOffset, context: "ktx2.kvd")
        }
        return count
    }

    @inline(__always)
    private static func rangesOverlap(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }
}

/// Executor do subcomando `texture`.
public enum TextureCommand {
    public static let helpText = """
        uso: caju-tools texture <entrada> -o <saida.ktx2> [--format <fmt>] [--mipmaps]
             caju-tools texture --validate <arquivo.ktx2>

        opções:
          -o, --output <arquivo>   caminho do arquivo KTX2 de saída
          --format <fmt>           rgba8-srgb (padrão), rgba8-unorm (astc-4x4 ainda não suportado)
          --mipmaps                gera cadeia completa de mipmaps por média 2x2
          --validate <arquivo>     valida cabeçalho, DFD, KVD e índice de níveis de um .ktx2
          -h, --help               exibe esta ajuda
        """

    public static func run(arguments: [String]) throws(CajuToolsError) -> String {
        var inputPath: String?
        var outputPath: String?
        var validatePath: String?
        var format: KTX2OutputFormat = .rgba8SRGB
        var mipmaps = false

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "-o", "--output":
                guard i + 1 < arguments.count else {
                    throw .usage("opção '\(arg)' exige caminho de saída")
                }
                outputPath = arguments[i + 1]
                i += 2
            case "--format":
                guard i + 1 < arguments.count else {
                    throw .usage("opção '--format' exige um formato")
                }
                guard let parsed = KTX2OutputFormat.parse(arguments[i + 1]) else {
                    throw .usage("formato desconhecido '\(arguments[i + 1])'")
                }
                format = parsed
                i += 2
            case "--mipmaps":
                mipmaps = true
                i += 1
            case "--validate":
                guard i + 1 < arguments.count else {
                    throw .usage("opção '--validate' exige caminho de arquivo .ktx2")
                }
                validatePath = arguments[i + 1]
                i += 2
            default:
                if arg.hasPrefix("-") {
                    throw .usage("opção desconhecida '\(arg)'")
                }
                guard inputPath == nil else {
                    throw .usage("argumento posicional inesperado '\(arg)'")
                }
                inputPath = arg
                i += 1
            }
        }

        if let validatePath {
            guard inputPath == nil, outputPath == nil else {
                throw .usage("'--validate' não pode ser combinado com entrada/saída")
            }
            let bytes = try readFileBytes(atPath: validatePath, limits: .default)
            let summary = try KTX2Codec.validate(bytes, limits: .default)
            return formatSummary(summary, status: "VALID")
        }

        guard let inputPath else {
            throw .usage("caminho da imagem de entrada obrigatório")
        }
        guard let outputPath else {
            throw .usage("opção '-o <saida.ktx2>' obrigatória")
        }
        if format == .astc4x4 {
            throw .unsupported(
                context: "texture.format",
                reason:
                    "codificação ASTC indisponível sem encoder externo/dependência C (ADR 0017); use rgba8-srgb ou rgba8-unorm"
            )
        }

        let inputBytes = try readFileBytes(atPath: inputPath, limits: .default)
        let image = try ToolsImageDecoder.decode(inputBytes, limits: .default)
        let ktx2Bytes = try KTX2Codec.encodeRGBA8(
            width: image.width,
            height: image.height,
            pixels: image.pixels,
            format: format,
            generateMipmaps: mipmaps,
            limits: .default
        )
        try writeFileBytes(ktx2Bytes, toPath: outputPath)
        let summary = try KTX2Codec.validate(ktx2Bytes, limits: .default)
        return formatSummary(summary, status: "OK")
    }

    private static func formatSummary(_ s: KTX2ValidationSummary, status: String) -> String {
        let levels = s.levelCount == 0 ? 1 : s.levelCount
        return "\(status) ktx2 width=\(s.pixelWidth) height=\(s.pixelHeight) levels=\(levels) "
            + "vkFormat=\(s.vkFormat) scheme=\(s.supercompressionScheme) bytes=\(s.byteCount)\n"
    }
}
