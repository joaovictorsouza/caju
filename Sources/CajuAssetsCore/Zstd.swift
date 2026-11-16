// Especificação adotada:
// - RFC 8878: Zstandard Compression and the 'application/zstd' Media Type

/// Descompressor Zstandard (RFC 8878) puro em Swift (sem `Foundation`).
///
/// Suporta quadros padrão (`0xFD2FB528`) com blocos `raw`, `RLE` e `compressed`
/// (literais Huffman de 1 ou 4 fluxos com pesos diretos ou comprimidos por FSE,
/// e sequências com tabelas FSE predefinidas, comprimidas, RLE ou repetidas),
/// além da verificação opcional de checksum `XXH64` (32 bits inferiores).
///
/// Dicionários, quadros ignoráveis/legados e entradas ou saídas acima de ``AssetLimits``
/// (ou `expectedSize`) são rejeitados antes de alocar.
///
/// ```swift
/// let uncompressed = try ZstdDecoder.decompress(compressedBytes, expectedSize: 64)
/// ```
public enum ZstdDecoder: Sendable {
    private static let standardMagic: UInt32 = 0xFD2F_B528
    private static let maxBlockSize = 131_072
    private static let maxHuffmanBits = 11
    private static let maxLiteralLengthSymbol = 35
    private static let maxOffsetSymbol = 31
    private static let maxMatchLengthSymbol = 52
    private static let maxFSEWeightAccuracyLog = 6
    private static let maxFSELLMLAccuracyLog = 9
    private static let maxFSEOffsetAccuracyLog = 8

    /// Descomprime um fluxo Zstandard padrão a partir de `bytes`.
    ///
    /// - Parameters:
    ///   - bytes: Dados comprimidos no formato Zstandard.
    ///   - expectedSize: Tamanho esperado da saída, se conhecido (por exemplo no KTX2).
    ///   - limits: Limites aplicados antes de alocar.
    /// - Returns: Bytes descomprimidos.
    public static func decompress(
        _ bytes: [UInt8],
        expectedSize: Int? = nil,
        limits: AssetLimits = .default
    ) throws(AssetError) -> [UInt8] {
        try decompressRange(
            bytes,
            range: 0..<bytes.count,
            expectedSize: expectedSize,
            limits: limits,
            context: "zstd"
        )
    }

    static func decompressRange(
        _ bytes: [UInt8],
        range: Range<Int>,
        expectedSize: Int? = nil,
        limits: AssetLimits = .default,
        context: String = "zstd"
    ) throws(AssetError) -> [UInt8] {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            throw .truncated(context: context)
        }
        let inputCount = range.count
        try checkLimit(inputCount, limits.maxInputBytes, "\(context).input")

        if let expectedSize {
            guard expectedSize >= 0 else {
                throw .invalid(context: "\(context).expectedSize", reason: "tamanho esperado negativo")
            }
            try checkLimit(expectedSize, limits.maxOutputBytes, "\(context).output")
        }

        guard inputCount > 0 else {
            throw .truncated(context: "\(context).frame")
        }

        let effectiveMaxOutput = expectedSize ?? limits.maxOutputBytes
        var output: [UInt8] = []
        var pos = range.lowerBound
        let end = range.upperBound

        while pos < end {
            try decodeFrame(
                bytes: bytes,
                pos: &pos,
                end: end,
                effectiveMaxOutput: effectiveMaxOutput,
                limits: limits,
                output: &output,
                context: context
            )
        }

        if let expectedSize, output.count != expectedSize {
            throw .invalid(
                context: "\(context).expectedSize",
                reason: "tamanho descomprimido (\(output.count)) difere de expectedSize (\(expectedSize))"
            )
        }

        return output
    }

    // MARK: - Quadro (Frame)

    private static func decodeFrame(
        bytes: [UInt8],
        pos: inout Int,
        end: Int,
        effectiveMaxOutput: Int,
        limits: AssetLimits,
        output: inout [UInt8],
        context: String
    ) throws(AssetError) {
        let magic = try readU32LE(bytes, pos: &pos, end: end, context: "\(context).magic")
        if (magic & 0xFFFF_FFF0) == 0x184D_2A50 {
            throw .unsupported(
                context: "\(context).frame",
                reason: "quadro ignorável Zstd não suportado"
            )
        }
        if magic >= 0xFD2F_B522 && magic <= 0xFD2F_B527 {
            throw .unsupported(
                context: "\(context).frame",
                reason: "quadro Zstd legado não suportado"
            )
        }
        guard magic == standardMagic else {
            throw .invalid(context: "\(context).magic", reason: "assinatura Zstd inválida")
        }

        let fhd = try readU8(bytes, pos: &pos, end: end, context: "\(context).header")
        let fcsFlag = (fhd >> 6) & 0x03
        let singleSegment = (fhd & 0x20) != 0
        let unusedBit = (fhd & 0x10) != 0
        let reservedBit = (fhd & 0x08) != 0
        let hasChecksum = (fhd & 0x04) != 0
        let dictIDFlag = fhd & 0x03

        guard !unusedBit, !reservedBit else {
            throw .invalid(
                context: "\(context).header", reason: "bits reservados do cabeçalho Zstd não são zero")
        }
        guard dictIDFlag == 0 else {
            throw .unsupported(context: "\(context).dict", reason: "dicionários Zstd não são suportados")
        }

        var windowSize: UInt64 = 0
        if !singleSegment {
            let windowByte = try readU8(bytes, pos: &pos, end: end, context: "\(context).window")
            let exponent = Int(windowByte >> 3)
            let mantissa = UInt64(windowByte & 0x07)
            let base = UInt64(1) << UInt64(10 + exponent)
            windowSize = base + (base >> 3) * mantissa
        }

        let fcsSize: Int
        switch fcsFlag {
        case 0:
            fcsSize = singleSegment ? 1 : 0
        case 1:
            fcsSize = 2
        case 2:
            fcsSize = 4
        default:
            fcsSize = 8
        }

        var frameContentSize: UInt64?
        if fcsSize > 0 {
            switch fcsSize {
            case 1:
                frameContentSize = UInt64(try readU8(bytes, pos: &pos, end: end, context: "\(context).fcs"))
            case 2:
                let raw = try readU16LE(bytes, pos: &pos, end: end, context: "\(context).fcs")
                frameContentSize = UInt64(raw) + 256
            case 4:
                frameContentSize = UInt64(
                    try readU32LE(bytes, pos: &pos, end: end, context: "\(context).fcs"))
            default:
                frameContentSize = try readU64LE(bytes, pos: &pos, end: end, context: "\(context).fcs")
            }
        }

        if singleSegment {
            windowSize = frameContentSize ?? 0
        }

        let remainingAllowed = effectiveMaxOutput - output.count
        if let fcs = frameContentSize {
            if fcs > UInt64(limits.maxOutputBytes) {
                throw .limitExceeded(
                    context: "\(context).output",
                    limit: limits.maxOutputBytes,
                    requested: Int(clamping: fcs)
                )
            }
            if fcs > UInt64(remainingAllowed) {
                throw .limitExceeded(
                    context: "\(context).output",
                    limit: effectiveMaxOutput,
                    requested: output.count + Int(clamping: fcs)
                )
            }
            let reserveBytes = min(Int(fcs), 1 << 20)
            output.reserveCapacity(output.count + reserveBytes)
        }

        let blockMaxSize = Int(min(windowSize, UInt64(maxBlockSize)))
        let frameOutputStart = output.count

        var huffmanTable: ZstdHuffmanTable?
        var prevLLTable: ZstdFSETable?
        var prevOFTable: ZstdFSETable?
        var prevMLTable: ZstdFSETable?
        var repeatOffsets = (1, 4, 8)
        var literalsScratch: [UInt8] = []

        var isLastBlock = false
        while !isLastBlock {
            let b0 = try readU8(bytes, pos: &pos, end: end, context: "\(context).blockHeader")
            let b1 = try readU8(bytes, pos: &pos, end: end, context: "\(context).blockHeader")
            let b2 = try readU8(bytes, pos: &pos, end: end, context: "\(context).blockHeader")
            let header = Int(b0) | (Int(b1) << 8) | (Int(b2) << 16)

            isLastBlock = (header & 1) != 0
            let blockType = (header >> 1) & 0x03
            let blockSize = header >> 3

            switch blockType {
            case 0:  // Raw_Block
                guard blockSize <= blockMaxSize else {
                    throw .invalid(context: "\(context).block", reason: "bloco raw excede Block_Maximum_Size")
                }
                guard blockSize <= effectiveMaxOutput - output.count else {
                    let requested = try checkedAdd(output.count, blockSize, "\(context).output")
                    throw .limitExceeded(
                        context: "\(context).output", limit: effectiveMaxOutput, requested: requested)
                }
                guard pos + blockSize <= end else {
                    throw .truncated(context: "\(context).rawBlock")
                }
                output.append(contentsOf: bytes[pos..<(pos + blockSize)])
                pos += blockSize

            case 1:  // RLE_Block
                guard blockSize <= blockMaxSize else {
                    throw .invalid(context: "\(context).block", reason: "bloco RLE excede tamanho máximo")
                }
                guard blockSize <= effectiveMaxOutput - output.count else {
                    let requested = try checkedAdd(output.count, blockSize, "\(context).output")
                    throw .limitExceeded(
                        context: "\(context).output", limit: effectiveMaxOutput, requested: requested)
                }
                let value = try readU8(bytes, pos: &pos, end: end, context: "\(context).rleBlock")
                if blockSize > 0 {
                    output.append(contentsOf: repeatElement(value, count: blockSize))
                }

            case 2:  // Compressed_Block
                guard blockSize > 0, blockSize <= blockMaxSize else {
                    throw .invalid(
                        context: "\(context).block",
                        reason: "tamanho de bloco comprimido inválido"
                    )
                }
                guard pos + blockSize <= end else {
                    throw .truncated(context: "\(context).compressedBlock")
                }
                let blockEnd = pos + blockSize
                try decodeCompressedBlock(
                    bytes: bytes,
                    start: pos,
                    end: blockEnd,
                    blockMaxSize: blockMaxSize,
                    windowSize: windowSize,
                    frameOutputStart: frameOutputStart,
                    effectiveMaxOutput: effectiveMaxOutput,
                    huffmanTable: &huffmanTable,
                    prevLLTable: &prevLLTable,
                    prevOFTable: &prevOFTable,
                    prevMLTable: &prevMLTable,
                    repeatOffsets: &repeatOffsets,
                    literalsScratch: &literalsScratch,
                    output: &output,
                    context: context
                )
                pos = blockEnd

            default:  // 3: Reserved
                throw .invalid(context: "\(context).block", reason: "tipo de bloco reservado (3)")
            }
        }

        let frameDecodedCount = output.count - frameOutputStart
        if let fcs = frameContentSize, UInt64(frameDecodedCount) != fcs {
            throw .invalid(
                context: "\(context).fcs",
                reason: "tamanho do quadro (\(frameDecodedCount)) difere de Frame_Content_Size (\(fcs))"
            )
        }

        if hasChecksum {
            let expectedChecksum = try readU32LE(bytes, pos: &pos, end: end, context: "\(context).checksum")
            let actualHash = xxh64(bytes: output, start: frameOutputStart, end: output.count)
            let actualChecksum = UInt32(truncatingIfNeeded: actualHash)
            guard actualChecksum == expectedChecksum else {
                throw .invalid(context: "\(context).checksum", reason: "checksum XXH64 inválido")
            }
        }
    }

    // MARK: - Bloco Comprimido

    private static func decodeCompressedBlock(
        bytes: [UInt8],
        start: Int,
        end: Int,
        blockMaxSize: Int,
        windowSize: UInt64,
        frameOutputStart: Int,
        effectiveMaxOutput: Int,
        huffmanTable: inout ZstdHuffmanTable?,
        prevLLTable: inout ZstdFSETable?,
        prevOFTable: inout ZstdFSETable?,
        prevMLTable: inout ZstdFSETable?,
        repeatOffsets: inout (Int, Int, Int),
        literalsScratch: inout [UInt8],
        output: inout [UInt8],
        context: String
    ) throws(AssetError) {
        var pos = start

        // 1. Seção de Literais
        try decodeLiteralsSection(
            bytes: bytes,
            pos: &pos,
            end: end,
            blockMaxSize: blockMaxSize,
            remainingAllowedOutput: effectiveMaxOutput - output.count,
            huffmanTable: &huffmanTable,
            literals: &literalsScratch,
            context: context
        )

        // 2. Seção de Sequências
        let seqByte0 = try readU8(bytes, pos: &pos, end: end, context: "\(context).sequences")
        let numSequences: Int
        if seqByte0 == 0 {
            numSequences = 0
        } else if seqByte0 < 128 {
            numSequences = Int(seqByte0)
        } else if seqByte0 < 255 {
            let seqByte1 = try readU8(bytes, pos: &pos, end: end, context: "\(context).sequences")
            numSequences = ((Int(seqByte0) - 128) << 8) + Int(seqByte1)
        } else {
            let seqU16 = try readU16LE(bytes, pos: &pos, end: end, context: "\(context).sequences")
            numSequences = Int(seqU16) + 0x7F00
        }

        if numSequences == 0 {
            guard pos == end else {
                throw .invalid(context: "\(context).sequences", reason: "bytes extras após 0 sequências")
            }
            guard literalsScratch.count <= effectiveMaxOutput - output.count else {
                let requested = try checkedAdd(output.count, literalsScratch.count, "\(context).output")
                throw .limitExceeded(
                    context: "\(context).output", limit: effectiveMaxOutput, requested: requested)
            }
            output.append(contentsOf: literalsScratch)
            return
        }

        let modes = try readU8(bytes, pos: &pos, end: end, context: "\(context).sequences.modes")
        guard (modes & 0x03) == 0 else {
            throw .invalid(
                context: "\(context).sequences.modes",
                reason: "bits reservados de modos de sequência não são zero"
            )
        }

        let llMode = Int((modes >> 6) & 0x03)
        let ofMode = Int((modes >> 4) & 0x03)
        let mlMode = Int((modes >> 2) & 0x03)

        let llTable = try resolveSequenceFSETable(
            mode: llMode,
            bytes: bytes,
            pos: &pos,
            end: end,
            maxSymbol: maxLiteralLengthSymbol,
            maxAccuracyLog: maxFSELLMLAccuracyLog,
            predefined: ZstdTables.predefinedLLTable,
            previous: &prevLLTable,
            context: "\(context).fse.ll"
        )
        let ofTable = try resolveSequenceFSETable(
            mode: ofMode,
            bytes: bytes,
            pos: &pos,
            end: end,
            maxSymbol: maxOffsetSymbol,
            maxAccuracyLog: maxFSEOffsetAccuracyLog,
            predefined: ZstdTables.predefinedOFTable,
            previous: &prevOFTable,
            context: "\(context).fse.of"
        )
        let mlTable = try resolveSequenceFSETable(
            mode: mlMode,
            bytes: bytes,
            pos: &pos,
            end: end,
            maxSymbol: maxMatchLengthSymbol,
            maxAccuracyLog: maxFSELLMLAccuracyLog,
            predefined: ZstdTables.predefinedMLTable,
            previous: &prevMLTable,
            context: "\(context).fse.ml"
        )

        var bits = try ZstdReverseBitReader(bytes: bytes, start: pos, end: end, context: "\(context).seqBits")
        var llState = try bits.readBits(llTable.accuracyLog, context: "\(context).seqBits")
        var ofState = try bits.readBits(ofTable.accuracyLog, context: "\(context).seqBits")
        var mlState = try bits.readBits(mlTable.accuracyLog, context: "\(context).seqBits")

        var litIndex = 0
        let blockOutputStart = output.count

        for seqIdx in 0..<numSequences {
            let ofCode = Int(ofTable.symbol(at: ofState))
            let mlCode = Int(mlTable.symbol(at: mlState))
            let llCode = Int(llTable.symbol(at: llState))

            guard ofCode <= maxOffsetSymbol else {
                throw .invalid(context: "\(context).seq.of", reason: "código de offset fora da faixa")
            }
            guard mlCode <= maxMatchLengthSymbol else {
                throw .invalid(context: "\(context).seq.ml", reason: "código de match length fora da faixa")
            }
            guard llCode <= maxLiteralLengthSymbol else {
                throw .invalid(context: "\(context).seq.ll", reason: "código de literal length fora da faixa")
            }

            // Ordem RFC 8878 §3.1.1.3.2.1.2: Offset, Match_Length, Literal_Length.
            let ofExtra = try bits.readBits(ofCode, context: "\(context).seqBits")
            let offsetValue = (1 << ofCode) + ofExtra

            let mlExtraBits = ZstdTables.matchLengthExtraBits[mlCode]
            let mlExtra = try bits.readBits(mlExtraBits, context: "\(context).seqBits")
            let matchLength = ZstdTables.matchLengthBases[mlCode] + mlExtra

            let llExtraBits = ZstdTables.literalLengthExtraBits[llCode]
            let llExtra = try bits.readBits(llExtraBits, context: "\(context).seqBits")
            let literalLength = ZstdTables.literalLengthBases[llCode] + llExtra

            if seqIdx + 1 < numSequences {
                llState = try llTable.nextState(llState, bits: &bits, context: "\(context).seqBits")
                mlState = try mlTable.nextState(mlState, bits: &bits, context: "\(context).seqBits")
                ofState = try ofTable.nextState(ofState, bits: &bits, context: "\(context).seqBits")
            }

            let actualOffset = try resolveOffset(
                offsetValue: offsetValue,
                literalLength: literalLength,
                repeatOffsets: &repeatOffsets,
                context: context
            )

            guard literalLength <= literalsScratch.count - litIndex else {
                throw .invalid(
                    context: "\(context).seq.lit", reason: "literalLength excede literais restantes")
            }
            let seqTotalOut = try checkedAdd(literalLength, matchLength, "\(context).seq.out")
            guard output.count - blockOutputStart + seqTotalOut <= blockMaxSize else {
                throw .invalid(
                    context: "\(context).block", reason: "saída do bloco excede Block_Maximum_Size")
            }
            guard seqTotalOut <= effectiveMaxOutput - output.count else {
                let requested = try checkedAdd(output.count, seqTotalOut, "\(context).output")
                throw .limitExceeded(
                    context: "\(context).output", limit: effectiveMaxOutput, requested: requested)
            }

            if literalLength > 0 {
                output.append(contentsOf: literalsScratch[litIndex..<(litIndex + literalLength)])
                litIndex += literalLength
            }

            let currentHistoryCount = output.count - frameOutputStart
            guard actualOffset >= 1,
                actualOffset <= currentHistoryCount,
                UInt64(actualOffset) <= windowSize
            else {
                throw .invalid(
                    context: "\(context).seq.offset", reason: "offset de cópia fora do histórico/janela")
            }

            var matchSrc = output.count - actualOffset
            for _ in 0..<matchLength {
                output.append(output[matchSrc])
                matchSrc += 1
            }
        }

        guard bits.isExhausted else {
            throw .invalid(context: "\(context).seqBits", reason: "bits restantes após última sequência")
        }

        let trailingLiterals = literalsScratch.count - litIndex
        if trailingLiterals > 0 {
            guard output.count - blockOutputStart + trailingLiterals <= blockMaxSize else {
                throw .invalid(
                    context: "\(context).block", reason: "saída do bloco excede Block_Maximum_Size")
            }
            guard trailingLiterals <= effectiveMaxOutput - output.count else {
                let requested = try checkedAdd(output.count, trailingLiterals, "\(context).output")
                throw .limitExceeded(
                    context: "\(context).output", limit: effectiveMaxOutput, requested: requested)
            }
            output.append(contentsOf: literalsScratch[litIndex..<literalsScratch.count])
        }
    }

    @inline(__always)
    private static func resolveOffset(
        offsetValue: Int,
        literalLength: Int,
        repeatOffsets: inout (Int, Int, Int),
        context: String
    ) throws(AssetError) -> Int {
        if offsetValue > 3 {
            let actual = offsetValue - 3
            repeatOffsets = (actual, repeatOffsets.0, repeatOffsets.1)
            return actual
        }

        if literalLength > 0 {
            switch offsetValue {
            case 1:
                return repeatOffsets.0
            case 2:
                let actual = repeatOffsets.1
                repeatOffsets = (actual, repeatOffsets.0, repeatOffsets.2)
                return actual
            default:  // 3
                let actual = repeatOffsets.2
                repeatOffsets = (actual, repeatOffsets.0, repeatOffsets.1)
                return actual
            }
        } else {
            switch offsetValue {
            case 1:
                let actual = repeatOffsets.1
                repeatOffsets = (actual, repeatOffsets.0, repeatOffsets.2)
                return actual
            case 2:
                let actual = repeatOffsets.2
                repeatOffsets = (actual, repeatOffsets.0, repeatOffsets.1)
                return actual
            default:  // 3
                let actual = repeatOffsets.0 - 1
                guard actual >= 1 else {
                    throw .invalid(context: "\(context).seq.offset", reason: "offset repetido inválido (0)")
                }
                repeatOffsets = (actual, repeatOffsets.0, repeatOffsets.1)
                return actual
            }
        }
    }

    // MARK: - Literais

    private static func decodeLiteralsSection(
        bytes: [UInt8],
        pos: inout Int,
        end: Int,
        blockMaxSize: Int,
        remainingAllowedOutput: Int,
        huffmanTable: inout ZstdHuffmanTable?,
        literals: inout [UInt8],
        context: String
    ) throws(AssetError) {
        literals.removeAll(keepingCapacity: true)
        let b0 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals")
        let litType = b0 & 0x03
        let sizeFormat = (b0 >> 2) & 0x03

        if litType == 0 || litType == 1 {
            let regenSize: Int
            switch sizeFormat {
            case 0, 2:
                regenSize = Int(b0 >> 3)
            case 1:
                let b1 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.size")
                regenSize = (Int(b0) >> 4) | (Int(b1) << 4)
            default:  // 3
                let b1 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.size")
                let b2 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.size")
                regenSize = (Int(b0) >> 4) | (Int(b1) << 4) | (Int(b2) << 12)
            }

            guard regenSize <= blockMaxSize else {
                throw .invalid(context: "\(context).literals", reason: "literais excedem Block_Maximum_Size")
            }
            guard regenSize <= remainingAllowedOutput else {
                throw .limitExceeded(
                    context: "\(context).output",
                    limit: remainingAllowedOutput,
                    requested: regenSize
                )
            }

            if litType == 0 {
                guard pos + regenSize <= end else {
                    throw .truncated(context: "\(context).literals.raw")
                }
                literals.append(contentsOf: bytes[pos..<(pos + regenSize)])
                pos += regenSize
            } else {
                let value = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.rle")
                literals.append(contentsOf: repeatElement(value, count: regenSize))
            }
            return
        }

        // Compressed_Literals_Block (2) ou Treeless_Literals_Block (3)
        let numStreams = sizeFormat == 0 ? 1 : 4
        let regenSize: Int
        let compSize: Int

        switch sizeFormat {
        case 0, 1:
            let b1 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let b2 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let packed = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16)
            regenSize = Int((packed >> 4) & 0x3FF)
            compSize = Int((packed >> 14) & 0x3FF)
        case 2:
            let b1 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let b2 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let b3 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let packed = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
            regenSize = Int((packed >> 4) & 0x3FFF)
            compSize = Int((packed >> 18) & 0x3FFF)
        default:  // 3
            let b1 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let b2 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let b3 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let b4 = try readU8(bytes, pos: &pos, end: end, context: "\(context).literals.header")
            let packed =
                UInt64(b0)
                | (UInt64(b1) << 8)
                | (UInt64(b2) << 16)
                | (UInt64(b3) << 24)
                | (UInt64(b4) << 32)
            regenSize = Int((packed >> 4) & 0x3FFFF)
            compSize = Int((packed >> 22) & 0x3FFFF)
        }

        guard regenSize <= blockMaxSize else {
            throw .invalid(context: "\(context).literals", reason: "literais excedem Block_Maximum_Size")
        }
        guard regenSize <= remainingAllowedOutput else {
            throw .limitExceeded(
                context: "\(context).output",
                limit: remainingAllowedOutput,
                requested: regenSize
            )
        }
        guard pos + compSize <= end else {
            throw .truncated(context: "\(context).literals.compressed")
        }

        let payloadStart = pos
        let payloadEnd = pos + compSize
        pos = payloadEnd

        var streamPos = payloadStart
        let activeTable: ZstdHuffmanTable
        if litType == 2 {
            let table = try readHuffmanTable(
                bytes: bytes,
                pos: &streamPos,
                end: payloadEnd,
                context: "\(context).huffman"
            )
            huffmanTable = table
            activeTable = table
        } else {
            guard let previous = huffmanTable else {
                throw .invalid(
                    context: "\(context).huffman",
                    reason: "bloco de literais treeless sem tabela Huffman anterior"
                )
            }
            activeTable = previous
        }

        if regenSize == 0 {
            guard streamPos == payloadEnd else {
                throw .invalid(context: "\(context).literals", reason: "fluxo não vazio para 0 literais")
            }
            return
        }

        literals.reserveCapacity(regenSize)
        if numStreams == 1 {
            try activeTable.decodeStream(
                bytes: bytes,
                start: streamPos,
                end: payloadEnd,
                expectedCount: regenSize,
                into: &literals,
                context: "\(context).huffman"
            )
        } else {
            guard regenSize >= 6 else {
                throw .invalid(
                    context: "\(context).literals",
                    reason: "4 fluxos Huffman inválidos para regenSize < 6"
                )
            }
            let size1 = Int(
                try readU16LE(bytes, pos: &streamPos, end: payloadEnd, context: "\(context).literals.jump"))
            let size2 = Int(
                try readU16LE(bytes, pos: &streamPos, end: payloadEnd, context: "\(context).literals.jump"))
            let size3 = Int(
                try readU16LE(bytes, pos: &streamPos, end: payloadEnd, context: "\(context).literals.jump"))

            let s1Start = streamPos
            let s1End = s1Start + size1
            let s2End = s1End + size2
            let s3End = s2End + size3
            guard s3End < payloadEnd else {
                throw .truncated(context: "\(context).literals.streams")
            }

            let perStream = (regenSize + 3) / 4
            let lastStreamCount = regenSize - 3 * perStream
            guard lastStreamCount > 0 else {
                throw .invalid(context: "\(context).literals", reason: "contagem inválida para 4 fluxos")
            }

            try activeTable.decodeStream(
                bytes: bytes,
                start: s1Start,
                end: s1End,
                expectedCount: perStream,
                into: &literals,
                context: "\(context).huffman"
            )
            try activeTable.decodeStream(
                bytes: bytes,
                start: s1End,
                end: s2End,
                expectedCount: perStream,
                into: &literals,
                context: "\(context).huffman"
            )
            try activeTable.decodeStream(
                bytes: bytes,
                start: s2End,
                end: s3End,
                expectedCount: perStream,
                into: &literals,
                context: "\(context).huffman"
            )
            try activeTable.decodeStream(
                bytes: bytes,
                start: s3End,
                end: payloadEnd,
                expectedCount: lastStreamCount,
                into: &literals,
                context: "\(context).huffman"
            )
        }
    }

    private static func readHuffmanTable(
        bytes: [UInt8],
        pos: inout Int,
        end: Int,
        context: String
    ) throws(AssetError) -> ZstdHuffmanTable {
        let headerByte = try readU8(bytes, pos: &pos, end: end, context: context)
        var weights: [Int] = []

        if headerByte >= 128 {
            let numSymbols = Int(headerByte) - 127
            let byteCount = (numSymbols + 1) / 2
            guard pos + byteCount <= end else {
                throw .truncated(context: context)
            }
            weights.reserveCapacity(numSymbols + 1)
            for i in 0..<numSymbols {
                let b = bytes[pos + (i >> 1)]
                let w = (i & 1) == 0 ? Int(b >> 4) : Int(b & 0x0F)
                guard w <= maxHuffmanBits else {
                    throw .invalid(context: context, reason: "peso Huffman > 11")
                }
                weights.append(w)
            }
            pos += byteCount
        } else {
            let compressedSize = Int(headerByte)
            guard compressedSize >= 2, pos + compressedSize <= end else {
                throw .truncated(context: context)
            }
            let fseEnd = pos + compressedSize
            let fseTable = try ZstdFSETable.parse(
                bytes: bytes,
                pos: &pos,
                end: fseEnd,
                maxSymbol: 12,
                maxAccuracyLog: maxFSEWeightAccuracyLog,
                context: "\(context).fseWeights"
            )
            var bits = try ZstdReverseBitReader(
                bytes: bytes,
                start: pos,
                end: fseEnd,
                context: "\(context).fseWeights"
            )
            var state1 = try bits.readBits(fseTable.accuracyLog, context: "\(context).fseWeights")
            var state2 = try bits.readBits(fseTable.accuracyLog, context: "\(context).fseWeights")

            while true {
                guard weights.count < 255 else {
                    throw .invalid(context: context, reason: "tabela de pesos Huffman excede 255 símbolos")
                }
                let w1 = Int(fseTable.symbol(at: state1))
                guard w1 <= maxHuffmanBits else {
                    throw .invalid(context: context, reason: "peso Huffman > 11")
                }
                weights.append(w1)

                let next1 = fseTable.tryNextState(state1, bits: &bits)
                if let next1 {
                    state1 = next1
                } else {
                    guard weights.count < 255 else {
                        throw .invalid(
                            context: context, reason: "tabela de pesos Huffman excede 255 símbolos")
                    }
                    let w2 = Int(fseTable.symbol(at: state2))
                    guard w2 <= maxHuffmanBits else {
                        throw .invalid(context: context, reason: "peso Huffman > 11")
                    }
                    weights.append(w2)
                    break
                }

                guard weights.count < 255 else {
                    throw .invalid(context: context, reason: "tabela de pesos Huffman excede 255 símbolos")
                }
                let w2 = Int(fseTable.symbol(at: state2))
                guard w2 <= maxHuffmanBits else {
                    throw .invalid(context: context, reason: "peso Huffman > 11")
                }
                weights.append(w2)

                let next2 = fseTable.tryNextState(state2, bits: &bits)
                if let next2 {
                    state2 = next2
                } else {
                    guard weights.count < 255 else {
                        throw .invalid(
                            context: context, reason: "tabela de pesos Huffman excede 255 símbolos")
                    }
                    let wLast = Int(fseTable.symbol(at: state1))
                    guard wLast <= maxHuffmanBits else {
                        throw .invalid(context: context, reason: "peso Huffman > 11")
                    }
                    weights.append(wLast)
                    break
                }
            }
            pos = fseEnd
        }

        return try ZstdHuffmanTable(partialWeights: weights, context: context)
    }

    // MARK: - Tabelas FSE de Sequências

    private static func resolveSequenceFSETable(
        mode: Int,
        bytes: [UInt8],
        pos: inout Int,
        end: Int,
        maxSymbol: Int,
        maxAccuracyLog: Int,
        predefined: ZstdFSETable,
        previous: inout ZstdFSETable?,
        context: String
    ) throws(AssetError) -> ZstdFSETable {
        let table: ZstdFSETable
        switch mode {
        case 0:
            table = predefined
        case 1:
            let sym = try readU8(bytes, pos: &pos, end: end, context: context)
            guard Int(sym) <= maxSymbol else {
                throw .invalid(context: context, reason: "símbolo RLE FSE fora da faixa")
            }
            table = ZstdFSETable(rleSymbol: sym)
        case 2:
            table = try ZstdFSETable.parse(
                bytes: bytes,
                pos: &pos,
                end: end,
                maxSymbol: maxSymbol,
                maxAccuracyLog: maxAccuracyLog,
                context: context
            )
        default:  // 3: Repeat_Mode
            guard let prev = previous else {
                throw .invalid(context: context, reason: "modo Repeat FSE sem tabela anterior")
            }
            table = prev
        }
        previous = table
        return table
    }

    // MARK: - Leitura LE e Checksum XXH64

    @inline(__always)
    private static func readU8(
        _ bytes: [UInt8],
        pos: inout Int,
        end: Int,
        context: String
    ) throws(AssetError) -> UInt8 {
        guard pos < end else { throw .truncated(context: context) }
        defer { pos += 1 }
        return bytes[pos]
    }

    @inline(__always)
    private static func readU16LE(
        _ bytes: [UInt8],
        pos: inout Int,
        end: Int,
        context: String
    ) throws(AssetError) -> UInt16 {
        guard pos + 2 <= end else { throw .truncated(context: context) }
        defer { pos += 2 }
        return UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
    }

    @inline(__always)
    private static func readU32LE(
        _ bytes: [UInt8],
        pos: inout Int,
        end: Int,
        context: String
    ) throws(AssetError) -> UInt32 {
        guard pos + 4 <= end else { throw .truncated(context: context) }
        defer { pos += 4 }
        return UInt32(bytes[pos])
            | (UInt32(bytes[pos + 1]) << 8)
            | (UInt32(bytes[pos + 2]) << 16)
            | (UInt32(bytes[pos + 3]) << 24)
    }

    @inline(__always)
    private static func readU64LE(
        _ bytes: [UInt8],
        pos: inout Int,
        end: Int,
        context: String
    ) throws(AssetError) -> UInt64 {
        guard pos + 8 <= end else { throw .truncated(context: context) }
        defer { pos += 8 }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(bytes[pos + i]) << UInt64(8 * i)
        }
        return v
    }

    private static func xxh64(bytes: [UInt8], start: Int, end: Int) -> UInt64 {
        let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
        let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
        let prime3: UInt64 = 0x1656_67B1_9E37_79F9
        let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
        let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

        @inline(__always)
        func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
            (x << r) | (x >> (64 - r))
        }

        @inline(__always)
        func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
            rotl(acc &+ (input &* prime2), 31) &* prime1
        }

        @inline(__always)
        func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
            let v = round(0, val)
            return ((acc ^ v) &* prime1) &+ prime4
        }

        @inline(__always)
        func read64(_ i: Int) -> UInt64 {
            UInt64(bytes[i])
                | (UInt64(bytes[i + 1]) << 8)
                | (UInt64(bytes[i + 2]) << 16)
                | (UInt64(bytes[i + 3]) << 24)
                | (UInt64(bytes[i + 4]) << 32)
                | (UInt64(bytes[i + 5]) << 40)
                | (UInt64(bytes[i + 6]) << 48)
                | (UInt64(bytes[i + 7]) << 56)
        }

        @inline(__always)
        func read32(_ i: Int) -> UInt64 {
            UInt64(bytes[i])
                | (UInt64(bytes[i + 1]) << 8)
                | (UInt64(bytes[i + 2]) << 16)
                | (UInt64(bytes[i + 3]) << 24)
        }

        let len = end - start
        var pos = start
        var h: UInt64

        if len >= 32 {
            var v1 = prime1 &+ prime2
            var v2 = prime2
            var v3: UInt64 = 0
            var v4 = 0 &- prime1
            let limit = end - 32
            while pos <= limit {
                v1 = round(v1, read64(pos))
                v2 = round(v2, read64(pos + 8))
                v3 = round(v3, read64(pos + 16))
                v4 = round(v4, read64(pos + 24))
                pos += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = mergeRound(h, v1)
            h = mergeRound(h, v2)
            h = mergeRound(h, v3)
            h = mergeRound(h, v4)
        } else {
            h = prime5
        }

        h &+= UInt64(len)

        while pos + 8 <= end {
            let k1 = round(0, read64(pos))
            h = rotl(h ^ k1, 27) &* prime1 &+ prime4
            pos += 8
        }

        if pos + 4 <= end {
            h = rotl(h ^ (read32(pos) &* prime1), 23) &* prime2 &+ prime3
            pos += 4
        }

        while pos < end {
            h = rotl(h ^ (UInt64(bytes[pos]) &* prime5), 11) &* prime1
            pos += 1
        }

        h ^= h >> 33
        h &*= prime2
        h ^= h >> 29
        h &*= prime3
        h ^= h >> 32
        return h
    }
}

// MARK: - Leitores de bits (reverso para fluxos FSE/Huffman e direto para cabeçalhos FSE)

private struct ZstdReverseBitReader {
    private let bytes: [UInt8]
    private let start: Int
    private var byteIndex: Int
    private var bitContainer: UInt64
    private var bitCount: Int

    init(bytes: [UInt8], start: Int, end: Int, context: String) throws(AssetError) {
        guard end > start else {
            throw .truncated(context: context)
        }
        let lastByte = bytes[end - 1]
        guard lastByte != 0 else {
            throw .invalid(
                context: context, reason: "byte final de fluxo reverso Zstd é zero (sem sentinela)")
        }
        let validBits = 7 - lastByte.leadingZeroBitCount
        let mask: UInt64 = validBits == 0 ? 0 : ((UInt64(1) << UInt64(validBits)) - 1)

        self.bytes = bytes
        self.start = start
        self.byteIndex = end - 1
        self.bitContainer = UInt64(lastByte) & mask
        self.bitCount = validBits
    }

    var isExhausted: Bool {
        bitCount == 0 && byteIndex == start
    }

    var totalAvailableBits: Int {
        bitCount + (byteIndex - start) * 8
    }

    mutating func readBits(_ count: Int, context: String) throws(AssetError) -> Int {
        if count == 0 { return 0 }
        fill(upTo: count)
        guard bitCount >= count else {
            throw .truncated(context: context)
        }
        let shift = bitCount - count
        let mask = (UInt64(1) << UInt64(count)) - 1
        let value = Int((bitContainer >> UInt64(shift)) & mask)
        bitCount -= count
        bitContainer &= (UInt64(1) << UInt64(bitCount)) - 1
        return value
    }

    /// Tenta ler `count` bits; retorna `nil` se o fluxo acabar (usado em pesos Huffman FSE).
    mutating func tryReadBits(_ count: Int) -> Int? {
        if count == 0 { return 0 }
        fill(upTo: count)
        guard bitCount >= count else {
            return nil
        }
        let shift = bitCount - count
        let mask = (UInt64(1) << UInt64(count)) - 1
        let value = Int((bitContainer >> UInt64(shift)) & mask)
        bitCount -= count
        bitContainer &= (UInt64(1) << UInt64(bitCount)) - 1
        return value
    }

    mutating func peekTopBits(_ maxBits: Int) -> (bits: Int, available: Int) {
        fill(upTo: maxBits)
        if bitCount == 0 { return (0, 0) }
        if bitCount >= maxBits {
            let mask = (UInt64(1) << UInt64(maxBits)) - 1
            let value = Int((bitContainer >> UInt64(bitCount - maxBits)) & mask)
            return (value, maxBits)
        }
        let mask = (UInt64(1) << UInt64(bitCount)) - 1
        let value = Int((bitContainer & mask) << UInt64(maxBits - bitCount))
        return (value, bitCount)
    }

    mutating func consumeBits(_ count: Int) {
        bitCount -= count
        bitContainer &= (UInt64(1) << UInt64(bitCount)) - 1
    }

    private mutating func fill(upTo needed: Int) {
        while bitCount < needed && byteIndex > start {
            byteIndex -= 1
            bitContainer = (bitContainer << 8) | UInt64(bytes[byteIndex])
            bitCount += 8
        }
    }
}

private struct ZstdForwardBitReader {
    private let bytes: [UInt8]
    private let end: Int
    private var byteOffset: Int
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0

    init(bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        self.byteOffset = start
        self.end = end
    }

    var alignedByteEnd: Int {
        byteOffset - (bitCount >> 3)
    }

    mutating func readBits(_ count: Int, context: String) throws(AssetError) -> Int {
        if count == 0 { return 0 }
        fill(upTo: count)
        guard bitCount >= count else {
            throw .truncated(context: context)
        }
        let mask = (UInt64(1) << UInt64(count)) - 1
        let value = Int(bitBuffer & mask)
        bitBuffer >>= UInt64(count)
        bitCount -= count
        return value
    }

    mutating func peekBits(_ count: Int, context: String) throws(AssetError) -> Int {
        if count == 0 { return 0 }
        fill(upTo: count)
        guard bitCount >= count else {
            throw .truncated(context: context)
        }
        let mask = (UInt64(1) << UInt64(count)) - 1
        return Int(bitBuffer & mask)
    }

    private mutating func fill(upTo needed: Int) {
        while bitCount < needed && byteOffset < end {
            bitBuffer |= UInt64(bytes[byteOffset]) << UInt64(bitCount)
            byteOffset += 1
            bitCount += 8
        }
    }
}

// MARK: - Tabelas FSE e Huffman Zstd

private struct ZstdFSETable: Sendable {
    let accuracyLog: Int
    private let symbols: [UInt8]
    private let nbBits: [UInt8]
    private let newStateBases: [UInt16]

    init(rleSymbol: UInt8) {
        self.accuracyLog = 0
        self.symbols = [rleSymbol]
        self.nbBits = [0]
        self.newStateBases = [0]
    }

    init(normalizedCounts: [Int], accuracyLog: Int, context: String) throws(AssetError) {
        let (symbols, nbBits, newStateBases, position) = Self.buildTables(
            normalizedCounts: normalizedCounts,
            accuracyLog: accuracyLog
        )
        guard position == 0 else {
            throw .invalid(context: context, reason: "soma de probabilidades FSE inválida")
        }
        self.accuracyLog = accuracyLog
        self.symbols = symbols
        self.nbBits = nbBits
        self.newStateBases = newStateBases
    }

    init(uncheckedNormalizedCounts normalizedCounts: [Int], accuracyLog: Int) {
        let (symbols, nbBits, newStateBases, _) = Self.buildTables(
            normalizedCounts: normalizedCounts,
            accuracyLog: accuracyLog
        )
        self.accuracyLog = accuracyLog
        self.symbols = symbols
        self.nbBits = nbBits
        self.newStateBases = newStateBases
    }

    private static func buildTables(
        normalizedCounts: [Int],
        accuracyLog: Int
    ) -> ([UInt8], [UInt8], [UInt16], Int) {
        let tableSize = 1 << accuracyLog
        var symbols = [UInt8](repeating: 0, count: tableSize)
        var nbBits = [UInt8](repeating: 0, count: tableSize)
        var newStateBases = [UInt16](repeating: 0, count: tableSize)
        var symbolNext = [Int](repeating: 0, count: normalizedCounts.count)

        var highThreshold = tableSize
        for s in 0..<normalizedCounts.count {
            let c = normalizedCounts[s]
            if c == -1 {
                highThreshold -= 1
                symbols[highThreshold] = UInt8(s)
                symbolNext[s] = 1
            } else {
                symbolNext[s] = c
            }
        }

        var position = 0
        let step = (tableSize >> 1) + (tableSize >> 3) + 3
        let mask = tableSize - 1
        for s in 0..<normalizedCounts.count {
            let c = normalizedCounts[s]
            if c > 0 {
                for _ in 0..<c {
                    symbols[position] = UInt8(s)
                    repeat {
                        position = (position + step) & mask
                    } while position >= highThreshold
                }
            }
        }

        for i in 0..<tableSize {
            let s = Int(symbols[i])
            let nextState = symbolNext[s]
            symbolNext[s] += 1
            let highBit = Int.bitWidth - 1 - nextState.leadingZeroBitCount
            let bits = accuracyLog - highBit
            nbBits[i] = UInt8(bits)
            newStateBases[i] = UInt16((nextState << bits) - tableSize)
        }

        return (symbols, nbBits, newStateBases, position)
    }

    static func parse(
        bytes: [UInt8],
        pos: inout Int,
        end: Int,
        maxSymbol: Int,
        maxAccuracyLog: Int,
        context: String
    ) throws(AssetError) -> ZstdFSETable {
        var bits = ZstdForwardBitReader(bytes: bytes, start: pos, end: end)
        let accuracyLog = try bits.readBits(4, context: context) + 5
        guard accuracyLog <= maxAccuracyLog else {
            throw .invalid(
                context: context, reason: "accuracyLog FSE (\(accuracyLog)) excede máximo (\(maxAccuracyLog))"
            )
        }

        let tableSize = 1 << accuracyLog
        var remaining = tableSize + 1
        var threshold = tableSize
        var nbBits = accuracyLog + 1
        var counts = [Int](repeating: 0, count: maxSymbol + 1)
        var symIndex = 0
        var previousZero = false

        while remaining > 1 && symIndex <= maxSymbol {
            if previousZero {
                var zeroEnd = symIndex
                while true {
                    let r = try bits.readBits(2, context: context)
                    zeroEnd += r
                    if r < 3 { break }
                }
                guard zeroEnd <= maxSymbol + 1 else {
                    throw .invalid(context: context, reason: "execução de zeros FSE excede símbolo máximo")
                }
                symIndex = zeroEnd
                if symIndex > maxSymbol { break }
            }

            let maxVal = 2 * threshold - 1 - remaining
            let low = try bits.peekBits(nbBits - 1, context: context)
            var count: Int
            if low < maxVal {
                count = try bits.readBits(nbBits - 1, context: context)
            } else {
                count = try bits.readBits(nbBits, context: context)
                if count >= threshold {
                    count -= maxVal
                }
            }

            let prob = count - 1
            if prob >= 0 {
                remaining -= prob
            } else {
                remaining -= 1
            }
            guard remaining >= 1 else {
                throw .invalid(context: context, reason: "probabilidades FSE excedem tamanho da tabela")
            }

            counts[symIndex] = prob
            symIndex += 1
            previousZero = (prob == 0)

            while remaining < threshold {
                nbBits -= 1
                threshold >>= 1
            }
        }

        guard remaining == 1 else {
            throw .invalid(context: context, reason: "distribuição FSE incompleta")
        }

        let consumedEnd = bits.alignedByteEnd
        guard consumedEnd <= end else {
            throw .truncated(context: context)
        }
        pos = consumedEnd

        return try ZstdFSETable(normalizedCounts: counts, accuracyLog: accuracyLog, context: context)
    }

    @inline(__always)
    func symbol(at state: Int) -> UInt8 {
        symbols[state]
    }

    @inline(__always)
    func nextState(
        _ state: Int,
        bits: inout ZstdReverseBitReader,
        context: String
    ) throws(AssetError) -> Int {
        let n = Int(nbBits[state])
        let low = try bits.readBits(n, context: context)
        return Int(newStateBases[state]) + low
    }

    @inline(__always)
    func tryNextState(_ state: Int, bits: inout ZstdReverseBitReader) -> Int? {
        let n = Int(nbBits[state])
        guard let low = bits.tryReadBits(n) else {
            return nil
        }
        return Int(newStateBases[state]) + low
    }
}

private struct ZstdHuffmanTable: Sendable {
    private let maxBits: Int
    private let entries: [UInt16]  // (nbBits << 8) | symbol

    init(partialWeights: [Int], context: String) throws(AssetError) {
        guard !partialWeights.isEmpty, partialWeights.count <= 255 else {
            throw .invalid(context: context, reason: "contagem de pesos Huffman inválida")
        }

        var weightSum = 0
        for w in partialWeights where w > 0 {
            weightSum += 1 << (w - 1)
        }
        guard weightSum > 0 else {
            throw .invalid(context: context, reason: "árvore Huffman sem símbolos ativos")
        }

        let maxBits = Int.bitWidth - weightSum.leadingZeroBitCount
        guard maxBits >= 1, maxBits <= 11 else {
            throw .invalid(context: context, reason: "profundidade Huffman fora de 1...11")
        }

        let total = 1 << maxBits
        let rem = total - weightSum
        guard rem > 0, (rem & (rem - 1)) == 0 else {
            throw .invalid(context: context, reason: "soma de pesos Huffman inválida")
        }
        let lastWeight = rem.trailingZeroBitCount + 1
        guard lastWeight <= maxBits else {
            throw .invalid(context: context, reason: "último peso Huffman inválido")
        }

        var weights = partialWeights
        weights.append(lastWeight)

        var rankCounts = [Int](repeating: 0, count: maxBits + 1)
        for w in weights where w > 0 {
            rankCounts[w] += 1
        }

        var rankStart = [Int](repeating: 0, count: maxBits + 1)
        var nextStart = 0
        for w in 1...maxBits {
            rankStart[w] = nextStart
            nextStart += rankCounts[w] << (w - 1)
        }
        guard nextStart == total else {
            throw .invalid(context: context, reason: "árvore Huffman incompleta")
        }

        var table = [UInt16](repeating: 0, count: total)
        for (sym, w) in weights.enumerated() where w > 0 {
            let len = maxBits + 1 - w
            let span = 1 << (w - 1)
            let startIdx = rankStart[w]
            rankStart[w] = startIdx + span
            let packed = UInt16((len << 8) | sym)
            for i in 0..<span {
                table[startIdx + i] = packed
            }
        }

        self.maxBits = maxBits
        self.entries = table
    }

    func decodeStream(
        bytes: [UInt8],
        start: Int,
        end: Int,
        expectedCount: Int,
        into output: inout [UInt8],
        context: String
    ) throws(AssetError) {
        var bits = try ZstdReverseBitReader(bytes: bytes, start: start, end: end, context: context)
        for _ in 0..<expectedCount {
            let (peek, available) = bits.peekTopBits(maxBits)
            guard available > 0 else {
                throw .truncated(context: context)
            }
            let entry = entries[peek]
            let len = Int(entry >> 8)
            guard available >= len else {
                throw .truncated(context: context)
            }
            bits.consumeBits(len)
            output.append(UInt8(entry & 0xFF))
        }
        guard bits.isExhausted else {
            throw .invalid(context: context, reason: "bits sobrando no fluxo Huffman de literais")
        }
    }
}

// MARK: - Tabelas Estáticas RFC 8878

private enum ZstdTables {
    static let literalLengthBases: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16_384, 32_768, 65_536,
    ]

    static let literalLengthExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16,
    ]

    static let matchLengthBases: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16_387, 32_771, 65_539,
    ]

    static let matchLengthExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16,
    ]

    static let predefinedLLTable = ZstdFSETable(
        uncheckedNormalizedCounts: [
            4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
            2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
            -1, -1, -1, -1,
        ],
        accuracyLog: 6
    )

    static let predefinedMLTable = ZstdFSETable(
        uncheckedNormalizedCounts: [
            1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
            -1, -1, -1, -1, -1,
        ],
        accuracyLog: 6
    )

    static let predefinedOFTable = ZstdFSETable(
        uncheckedNormalizedCounts: [
            1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
        ],
        accuracyLog: 5
    )
}
