// Especificações adotadas:
// - Khronos KTX File Format Specification v2.0 (https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html)
// - Khronos Data Format Specification v1.3 (https://registry.khronos.org/DataFormat/specs/1.3/dataformat.1.3.html)

/// Contêiner KTX 2.0 validado (somente cabeçalho, DFD, KVD e índice de níveis).
///
/// Este parser valida todos os campos e limites de ``AssetLimits`` antes de alocar,
/// mantendo os dados de imagem no buffer de entrada sem copiá-los.
///
/// - Note: Transcodificação Basis Universal (`ETC1S` / `UASTC`) **não** é implementada aqui;
///   ela pertence a um PR dedicado com dependência C. A descompressão de níveis Zstd/ZLIB
///   está disponível via ``decompressLevel(_:from:limits:)``. ``parse(_:limits:)`` apenas valida o contêiner.
/// - Note: Alinhamento de níveis adotado conforme a especificação KTX 2.0 (§3.12):
///   com `supercompressionScheme == .none`, exige `byteOffset` alinhado a 4 bytes
///   (mínimo garantido por `lcm(texelBlockSize, 4)` sem embutir tabela completa de `VkFormat`);
///   com supercompressão (`basisLZ`, `zstd`, `zlib`), aceita alinhamento de 1 byte.
///
/// ```swift
/// let container = try KTX2Container.parse(bytes)
/// let baseRange = try container.levelRange(0)
/// let baseLevelBytes = bytes[baseRange]
/// ```
public struct KTX2Container: Sendable {
    /// Entrada do índice de níveis (um nível de mipmap no arquivo KTX 2.0).
    public struct Level: Sendable, Equatable {
        /// Deslocamento em bytes a partir do início do arquivo até os dados deste nível.
        public let byteOffset: UInt64
        /// Tamanho em bytes armazenado no arquivo para este nível.
        public let byteLength: UInt64
        /// Tamanho em bytes após descompressão (igual a `byteLength` quando `supercompressionScheme == .none`).
        public let uncompressedByteLength: UInt64
    }

    /// Esquema de supercompressão definido pela especificação KTX 2.0 (§3.9).
    public enum SupercompressionScheme: UInt32, Sendable, Equatable {
        /// Sem supercompressão (`0`).
        case none = 0
        /// Basis Universal ETC1S / BasisLZ (`1`).
        case basisLZ = 1
        /// Zstandard (`2`).
        case zstd = 2
        /// ZLIB (`3`).
        case zlib = 3
    }

    /// Formato Vulkan (`VkFormat`), ou `0` (`VK_FORMAT_UNDEFINED`) para formatos Basis Universal.
    public let vkFormat: UInt32
    /// Tamanho do tipo em bytes para troca de endianness (`1` para formatos comprimidos ou `UNDEFINED`).
    public let typeSize: UInt32
    /// Largura do nível base em pixels (`> 0`).
    public let pixelWidth: UInt32
    /// Altura do nível base em pixels (`0` para textura 1D).
    public let pixelHeight: UInt32
    /// Profundidade do nível base em pixels (`0` para texturas 1D, 2D e cubemaps).
    public let pixelDepth: UInt32
    /// Número de camadas de array (`0` para texturas não-array).
    public let layerCount: UInt32
    /// Número de faces (`1` ou `6` para cubemaps).
    public let faceCount: UInt32
    /// Quantidade declarada de níveis de mip (`0` indica gerar mipmaps a partir do nível 0).
    public let levelCount: UInt32
    /// Esquema de supercompressão aplicado aos dados dos níveis.
    public let supercompressionScheme: SupercompressionScheme
    /// Índice de níveis do arquivo; o nível `0` (maior) aparece primeiro no índice e por último no arquivo.
    public let levels: [Level]
    /// Modelo de cor (`colorModel`) extraído do bloco básico do DFD.
    public let colorModel: UInt8
    /// Função de transferência (`transferFunction`) extraída do bloco básico do DFD.
    public let transferFunction: UInt8
    /// Flags (`flags`) extraídas do bloco básico do DFD (`0` alfa reto, `1` alfa pré-multiplicado).
    public let dfdFlags: UInt8
    /// Pares chave/valor (KVD) validados em UTF-8.
    public let keyValueData: [(key: String, value: [UInt8])]

    /// Retorna o intervalo válido em `bytes` correspondente ao nível de mipmap `i`.
    public func levelRange(_ i: Int) throws(AssetError) -> Range<Int> {
        guard i >= 0, i < levels.count else {
            throw .invalid(context: "ktx2.levels[\(i)]", reason: "índice de nível fora dos limites")
        }
        let level = levels[i]
        guard let start = Int(exactly: level.byteOffset),
            let length = Int(exactly: level.byteLength)
        else {
            throw .invalid(context: "ktx2.levels[\(i)]", reason: "offset ou comprimento excede Int")
        }
        let end = try checkedAdd(start, length, "ktx2.levels[\(i)]")
        return start..<end
    }

    /// Descomprime os bytes do nível de mipmap `i` a partir do arquivo `bytes` original.
    ///
    /// Suporta níveis sem supercompressão (`.none`), Zstandard (`.zstd`) e ZLIB (`.zlib`),
    /// verificando `uncompressedByteLength` contra `limits.maxOutputBytes` antes de alocar.
    /// Supercompressão `.basisLZ` lança `.unsupported` (depende de transcodificação Basis).
    public func decompressLevel(
        _ i: Int,
        from bytes: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> [UInt8] {
        let context = "ktx2.levels[\(i)]"
        let range = try levelRange(i)
        guard range.upperBound <= bytes.count else {
            throw .truncated(context: context)
        }
        let level = levels[i]
        guard let expectedSize = Int(exactly: level.uncompressedByteLength) else {
            throw .invalid(context: context, reason: "uncompressedByteLength excede Int")
        }
        try checkLimit(expectedSize, limits.maxOutputBytes, "\(context).output")

        switch supercompressionScheme {
        case .none:
            guard range.count == expectedSize else {
                throw .invalid(
                    context: context,
                    reason: "byteLength difere de uncompressedByteLength sem supercompressão"
                )
            }
            return Array(bytes[range])
        case .zstd:
            return try ZstdDecoder.decompressRange(
                bytes,
                range: range,
                expectedSize: expectedSize,
                limits: limits,
                context: "\(context).zstd"
            )
        case .zlib:
            try checkLimit(range.count, limits.maxInputBytes, "\(context).input")
            let decompressed = try Inflate.zlibDecompress(
                Array(bytes[range]),
                from: 0,
                maxOutput: expectedSize,
                context: "\(context).zlib"
            )
            guard decompressed.count == expectedSize else {
                throw .invalid(
                    context: "\(context).zlib",
                    reason: "tamanho descomprimido difere de uncompressedByteLength"
                )
            }
            return decompressed
        case .basisLZ:
            throw .unsupported(
                context: context,
                reason: "supercompressão BasisLZ requer transcodificação"
            )
        }
    }

    /// Faz o parse e a validação estrita de um contêiner KTX 2.0 a partir de `bytes`.
    public static func parse(
        _ bytes: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> KTX2Container {
        try checkLimit(bytes.count, limits.maxInputBytes, "ktx2.input")

        var reader = ByteReader(bytes)
        let magic = try reader.readBytes(ktx2Identifier.count, context: "ktx2.identifier")
        guard magic == ktx2Identifier else {
            throw .invalid(context: "ktx2.identifier", reason: "assinatura KTX 2.0 inválida")
        }

        let header = try readHeader(&reader, limits: limits)
        let actualLevelCount = try validateLevelCount(
            header.levelCount,
            width: header.pixelWidth,
            height: header.pixelHeight,
            depth: header.pixelDepth,
            limits: limits
        )

        let levelIndexBytes = try checkedMul(actualLevelCount, ktx2LevelEntrySize, "ktx2.levelIndex")
        let metadataEnd = try checkedAdd(ktx2HeaderSize, levelIndexBytes, "ktx2.levelIndex")
        guard bytes.count >= metadataEnd else {
            throw .truncated(context: "ktx2.levelIndex")
        }

        let dfdRange = try validateSectionRange(
            offset: UInt64(header.dfdByteOffset),
            length: UInt64(header.dfdByteLength),
            metadataEnd: metadataEnd,
            inputCount: bytes.count,
            allowZero: false,
            alignment: 4,
            context: "ktx2.dfd"
        )
        let kvdRange = try validateSectionRange(
            offset: UInt64(header.kvdByteOffset),
            length: UInt64(header.kvdByteLength),
            metadataEnd: metadataEnd,
            inputCount: bytes.count,
            allowZero: true,
            alignment: 4,
            context: "ktx2.kvd"
        )
        let sgdRange = try validateSectionRange(
            offset: header.sgdByteOffset,
            length: header.sgdByteLength,
            metadataEnd: metadataEnd,
            inputCount: bytes.count,
            allowZero: true,
            alignment: 8,
            context: "ktx2.sgd"
        )

        guard let dfdRange else {
            throw .invalid(context: "ktx2.dfd", reason: "DFD é obrigatório em KTX 2.0")
        }
        guard dfdRange.count >= ktx2MinimumDFDSize else {
            throw .invalid(context: "ktx2.dfd", reason: "DFD menor que o cabeçalho mínimo de 28 bytes")
        }
        if let kvdRange, kvdRange.count % 4 != 0 {
            throw .invalid(context: "ktx2.kvd", reason: "kvdByteLength deve ser múltiplo de 4")
        }
        if header.supercompressionScheme == .none, sgdRange != nil {
            throw .invalid(
                context: "ktx2.sgd",
                reason: "supercompressionGlobalData não é permitido quando supercompressionScheme == 0"
            )
        }

        let sectionRanges = collectSectionRanges(dfd: dfdRange, kvd: kvdRange, sgd: sgdRange)
        try ensureSectionsDoNotOverlap(sectionRanges)

        let levels = try readAndValidateLevels(
            &reader,
            count: actualLevelCount,
            scheme: header.supercompressionScheme,
            metadataEnd: metadataEnd,
            inputCount: bytes.count,
            sectionRanges: sectionRanges,
            limits: limits
        )

        let dfd = try parseDFD(bytes, range: dfdRange)
        if header.vkFormat == 0 {
            let isBasis =
                header.supercompressionScheme == .basisLZ
                || dfd.colorModel == kdfsColorModelETC1S
                || dfd.colorModel == kdfsColorModelUASTC
            guard isBasis else {
                throw .invalid(
                    context: "ktx2.vkFormat",
                    reason: "vkFormat UNDEFINED (0) exige BasisLZ ou DFD Basis (ETC1S/UASTC)"
                )
            }
        }

        let kvd = try parseKVD(bytes, range: kvdRange, maxElements: limits.maxElements)

        return KTX2Container(
            vkFormat: header.vkFormat,
            typeSize: header.typeSize,
            pixelWidth: header.pixelWidth,
            pixelHeight: header.pixelHeight,
            pixelDepth: header.pixelDepth,
            layerCount: header.layerCount,
            faceCount: header.faceCount,
            levelCount: header.levelCount,
            supercompressionScheme: header.supercompressionScheme,
            levels: levels,
            colorModel: dfd.colorModel,
            transferFunction: dfd.transferFunction,
            dfdFlags: dfd.flags,
            keyValueData: kvd
        )
    }
}

private let ktx2HeaderSize = 80
private let ktx2LevelEntrySize = 24
private let ktx2MinimumDFDSize = 28
private let kdfsColorModelETC1S: UInt8 = 163
private let kdfsColorModelUASTC: UInt8 = 166

private let ktx2Identifier: [UInt8] = [
    0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A,
]

private struct KTX2Header {
    let vkFormat: UInt32
    let typeSize: UInt32
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let pixelDepth: UInt32
    let layerCount: UInt32
    let faceCount: UInt32
    let levelCount: UInt32
    let supercompressionScheme: KTX2Container.SupercompressionScheme
    let dfdByteOffset: UInt32
    let dfdByteLength: UInt32
    let kvdByteOffset: UInt32
    let kvdByteLength: UInt32
    let sgdByteOffset: UInt64
    let sgdByteLength: UInt64
}

private struct KTX2DFDInfo {
    let colorModel: UInt8
    let transferFunction: UInt8
    let flags: UInt8
}

private func readHeader(
    _ reader: inout ByteReader,
    limits: AssetLimits
) throws(AssetError) -> KTX2Header {
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
        throw .invalid(
            context: "ktx2.pixelHeight",
            reason: "pixelHeight deve ser maior que zero quando pixelDepth > 0"
        )
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
                context: "ktx2.faceCount",
                reason: "cubemap (faceCount == 6) exige pixelWidth == pixelHeight e pixelDepth == 0"
            )
        }
    }

    guard let scheme = KTX2Container.SupercompressionScheme(rawValue: schemeRaw) else {
        throw .invalid(
            context: "ktx2.supercompressionScheme",
            reason: "supercompressionScheme desconhecido: \(schemeRaw)"
        )
    }

    return KTX2Header(
        vkFormat: vkFormat,
        typeSize: typeSize,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        pixelDepth: pixelDepth,
        layerCount: layerCount,
        faceCount: faceCount,
        levelCount: levelCount,
        supercompressionScheme: scheme,
        dfdByteOffset: dfdByteOffset,
        dfdByteLength: dfdByteLength,
        kvdByteOffset: kvdByteOffset,
        kvdByteLength: kvdByteLength,
        sgdByteOffset: sgdByteOffset,
        sgdByteLength: sgdByteLength
    )
}

private func validateLevelCount(
    _ levelCount: UInt32,
    width: UInt32,
    height: UInt32,
    depth: UInt32,
    limits: AssetLimits
) throws(AssetError) -> Int {
    if levelCount == 0 {
        return try checkLimitUInt64(1, limits.maxMipLevels, "ktx2.levelCount")
    }
    let validatedCount = try checkLimitUInt64(
        UInt64(levelCount),
        limits.maxMipLevels,
        "ktx2.levelCount"
    )
    let maxDimension = max(width, max(height, depth))
    let maxPossibleLevels = UInt32(UInt32.bitWidth - maxDimension.leadingZeroBitCount)
    guard levelCount <= maxPossibleLevels else {
        throw .invalid(
            context: "ktx2.levelCount",
            reason: "levelCount (\(levelCount)) excede máximo (\(maxPossibleLevels)) para as dimensões"
        )
    }
    return validatedCount
}

private func validateSectionRange(
    offset: UInt64,
    length: UInt64,
    metadataEnd: Int,
    inputCount: Int,
    allowZero: Bool,
    alignment: Int,
    context: String
) throws(AssetError) -> Range<Int>? {
    if length == 0 {
        guard allowZero else {
            throw .invalid(context: context, reason: "comprimento obrigatório não pode ser zero")
        }
        guard offset == 0 else {
            throw .invalid(context: context, reason: "offset deve ser zero quando comprimento é zero")
        }
        return nil
    }

    guard let start = Int(exactly: offset), let byteLength = Int(exactly: length) else {
        throw .invalid(context: context, reason: "offset ou comprimento excede Int")
    }
    let end = try checkedAdd(start, byteLength, context)
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

private func collectSectionRanges(
    dfd: Range<Int>,
    kvd: Range<Int>?,
    sgd: Range<Int>?
) -> [(name: String, range: Range<Int>)] {
    var ranges: [(name: String, range: Range<Int>)] = [("dfd", dfd)]
    if let kvd {
        ranges.append(("kvd", kvd))
    }
    if let sgd {
        ranges.append(("sgd", sgd))
    }
    return ranges
}

private func ensureSectionsDoNotOverlap(
    _ sections: [(name: String, range: Range<Int>)]
) throws(AssetError) {
    for i in 0..<sections.count {
        for j in (i + 1)..<sections.count {
            if rangesOverlap(sections[i].range, sections[j].range) {
                throw .invalid(
                    context: "ktx2.\(sections[i].name)",
                    reason: "seção \(sections[i].name) sobrepõe \(sections[j].name)"
                )
            }
        }
    }
}

private func readAndValidateLevels(
    _ reader: inout ByteReader,
    count: Int,
    scheme: KTX2Container.SupercompressionScheme,
    metadataEnd: Int,
    inputCount: Int,
    sectionRanges: [(name: String, range: Range<Int>)],
    limits: AssetLimits
) throws(AssetError) -> [KTX2Container.Level] {
    var levels: [KTX2Container.Level] = []
    levels.reserveCapacity(count)

    var totalUncompressed = 0
    var previousLevelStart = Int.max

    for i in 0..<count {
        let context = "ktx2.levels[\(i)]"
        let byteOffset = try reader.readU64LE("\(context).byteOffset")
        let byteLength = try reader.readU64LE("\(context).byteLength")
        let uncompressedByteLength = try reader.readU64LE("\(context).uncompressedByteLength")

        guard byteLength > 0 else {
            throw .invalid(
                context: "\(context).byteLength",
                reason: "comprimento de nível deve ser maior que zero"
            )
        }
        guard let start = Int(exactly: byteOffset), let length = Int(exactly: byteLength) else {
            throw .invalid(context: context, reason: "offset ou comprimento excede Int")
        }
        let end = try checkedAdd(start, length, context)
        guard start >= metadataEnd else {
            throw .invalid(context: context, reason: "nível sobrepõe cabeçalho ou índice de níveis")
        }
        guard end <= inputCount else {
            throw .truncated(context: context)
        }

        if scheme == .none {
            guard start % 4 == 0 else {
                throw .invalid(
                    context: "\(context).byteOffset",
                    reason: "nível sem supercompressão deve estar alinhado a 4 bytes"
                )
            }
            guard byteLength == uncompressedByteLength else {
                throw .invalid(
                    context: context,
                    reason: "supercompressionScheme == 0 exige byteLength == uncompressedByteLength"
                )
            }
        }

        let levelUncompressed = try checkLimitUInt64(
            uncompressedByteLength,
            limits.maxOutputBytes,
            "\(context).uncompressedByteLength"
        )
        totalUncompressed = try checkedAdd(
            totalUncompressed,
            levelUncompressed,
            "ktx2.uncompressedByteLength"
        )
        try checkLimit(totalUncompressed, limits.maxOutputBytes, "ktx2.uncompressedByteLength")

        if i > 0 {
            guard end <= previousLevelStart else {
                throw .invalid(
                    context: context,
                    reason: "níveis devem estar em ordem decrescente de offset e sem sobreposição"
                )
            }
        }
        previousLevelStart = start

        let levelRange = start..<end
        for section in sectionRanges where rangesOverlap(levelRange, section.range) {
            throw .invalid(
                context: context,
                reason: "nível sobrepõe seção \(section.name)"
            )
        }

        levels.append(
            KTX2Container.Level(
                byteOffset: byteOffset,
                byteLength: byteLength,
                uncompressedByteLength: uncompressedByteLength
            )
        )
    }

    return levels
}

private func parseDFD(_ bytes: [UInt8], range: Range<Int>) throws(AssetError) -> KTX2DFDInfo {
    var reader = ByteReader(bytes, offset: range.lowerBound)
    let totalSize = try reader.readU32LE("ktx2.dfd.totalSize")
    guard Int(exactly: totalSize) == range.count else {
        throw .invalid(
            context: "ktx2.dfd.totalSize",
            reason: "totalSize do DFD não corresponde a dfdByteLength"
        )
    }

    let word0 = try reader.readU32LE("ktx2.dfd.vendorAndType")
    let vendorID = word0 & 0x1FFFF
    let descriptorType = (word0 >> 17) & 0x7FFF
    guard vendorID == 0, descriptorType == 0 else {
        throw .invalid(
            context: "ktx2.dfd.descriptorType",
            reason: "bloco DFD inicial deve ser básico Khronos (vendorId=0, descriptorType=0)"
        )
    }

    let word1 = try reader.readU32LE("ktx2.dfd.versionAndSize")
    let versionNumber = word1 & 0xFFFF
    let descriptorBlockSize = (word1 >> 16) & 0xFFFF
    guard versionNumber == 2 else {
        throw .invalid(context: "ktx2.dfd.versionNumber", reason: "versão do DFD inválida (esperado 2)")
    }
    guard descriptorBlockSize >= 24, (descriptorBlockSize - 24) % 16 == 0 else {
        throw .invalid(
            context: "ktx2.dfd.descriptorBlockSize",
            reason: "tamanho de bloco DFD básico inválido"
        )
    }
    let blockEndOffset = try checkedAdd(4, Int(descriptorBlockSize), "ktx2.dfd.descriptorBlockSize")
    guard blockEndOffset <= range.count else {
        throw .truncated(context: "ktx2.dfd.descriptorBlockSize")
    }

    let colorModel = try reader.readU8("ktx2.dfd.colorModel")
    _ = try reader.readU8("ktx2.dfd.colorPrimaries")
    let transferFunction = try reader.readU8("ktx2.dfd.transferFunction")
    let flags = try reader.readU8("ktx2.dfd.flags")

    guard isValidKDFSColorModel(colorModel) else {
        throw .invalid(
            context: "ktx2.dfd.colorModel",
            reason: "colorModel fora da faixa válida KDFS: \(colorModel)"
        )
    }
    guard transferFunction <= 18 else {
        throw .invalid(
            context: "ktx2.dfd.transferFunction",
            reason: "transferFunction fora da faixa válida KDFS: \(transferFunction)"
        )
    }
    guard flags <= 1 else {
        throw .invalid(
            context: "ktx2.dfd.flags",
            reason: "flags de DFD inválidas (bits reservados devem ser zero): \(flags)"
        )
    }

    return KTX2DFDInfo(colorModel: colorModel, transferFunction: transferFunction, flags: flags)
}

private func isValidKDFSColorModel(_ model: UInt8) -> Bool {
    switch model {
    case 0...15, 128...134, 160...166:
        true
    default:
        false
    }
}

private func parseKVD(
    _ bytes: [UInt8],
    range: Range<Int>?,
    maxElements: Int
) throws(AssetError) -> [(key: String, value: [UInt8])] {
    guard let range else { return [] }

    var reader = ByteReader(bytes, offset: range.lowerBound)
    let end = range.upperBound
    var pairs: [(key: String, value: [UInt8])] = []

    while reader.offset < end {
        let nextCount = try checkedAdd(pairs.count, 1, "ktx2.kvd")
        try checkLimit(nextCount, maxElements, "ktx2.kvd")

        let entryLengthU32 = try reader.readU32LE("ktx2.kvd.keyAndValueByteLength")
        guard entryLengthU32 > 0 else {
            throw .invalid(
                context: "ktx2.kvd.keyAndValueByteLength",
                reason: "entrada KVD não pode ter tamanho 0"
            )
        }
        guard let entryLength = Int(exactly: entryLengthU32) else {
            throw .invalid(context: "ktx2.kvd.keyAndValueByteLength", reason: "tamanho de entrada excede Int")
        }

        let payloadStart = reader.offset
        let payloadEnd = try checkedAdd(payloadStart, entryLength, "ktx2.kvd")
        guard payloadEnd <= end else {
            throw .truncated(context: "ktx2.kvd")
        }

        var nulIndex: Int?
        for idx in payloadStart..<payloadEnd where bytes[idx] == 0 {
            nulIndex = idx
            break
        }
        guard let nulPos = nulIndex else {
            throw .invalid(context: "ktx2.kvd.key", reason: "chave KVD sem terminador NUL")
        }
        guard nulPos > payloadStart else {
            throw .invalid(context: "ktx2.kvd.key", reason: "chave KVD vazia")
        }

        let keyLength = nulPos - payloadStart
        if keyLength >= 3
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

        let value = Array(bytes[(nulPos + 1)..<payloadEnd])
        let padding = (4 - (entryLength & 3)) & 3
        let nextOffset = try checkedAdd(payloadEnd, padding, "ktx2.kvd.padding")
        guard nextOffset <= end else {
            throw .truncated(context: "ktx2.kvd.padding")
        }
        for padIdx in payloadEnd..<nextOffset where bytes[padIdx] != 0 {
            throw .invalid(context: "ktx2.kvd.padding", reason: "padding de KVD deve ser zero")
        }

        try reader.seek(to: nextOffset, context: "ktx2.kvd")
        pairs.append((key: key, value: value))
    }

    return pairs
}

@inline(__always)
private func rangesOverlap(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
    a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
}

@inline(__always)
private func checkLimitUInt64(
    _ requested: UInt64,
    _ limit: Int,
    _ context: String
) throws(AssetError) -> Int {
    guard limit >= 0 else {
        throw .limitExceeded(context: context, limit: limit, requested: Int(clamping: requested))
    }
    guard requested <= UInt64(limit) else {
        throw .limitExceeded(context: context, limit: limit, requested: Int(clamping: requested))
    }
    return Int(requested)
}
