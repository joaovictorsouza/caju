/// Descompressor DEFLATE/zlib puro em Swift (RFC 1950 e RFC 1951) para entrada PNG de `CajuTools`.
enum ToolsInflate {
    private static let lengthBases: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10,
        11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115,
        131, 163, 195, 227,
    ]

    private static let lengthExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5,
    ]

    private static let distanceBases: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13,
        17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073,
        4097, 6145, 8193, 12289, 16385, 24577,
    ]

    private static let distanceExtraBits: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2,
        3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10,
        11, 11, 12, 12, 13, 13,
    ]

    private static let codeLengthOrder: [Int] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    private static let fixedLitLenTable: HuffmanTable = makeFixedLitLenTable()
    private static let fixedDistTable: HuffmanTable = makeFixedDistTable()

    /// Descomprime um fluxo zlib (RFC 1950 + DEFLATE) respeitando o teto `maxOutput`.
    static func zlibDecompress(
        _ bytes: [UInt8],
        from start: Int,
        maxOutput: Int,
        context: String
    ) throws(CajuToolsError) -> [UInt8] {
        guard start >= 0, start <= bytes.count else {
            throw .truncated(context: context)
        }
        guard maxOutput >= 0 else {
            throw .limitExceeded(context: context, limit: maxOutput, requested: 0)
        }

        var bits = BitReader(bytes: bytes, offset: start)
        let cmf = try bits.readAlignedU8(context)
        let flg = try bits.readAlignedU8(context)

        guard (cmf & 0x0F) == 8 else {
            throw .invalid(context: context, reason: "método de compressão zlib inválido")
        }
        guard (cmf >> 4) <= 7 else {
            throw .invalid(context: context, reason: "janela zlib inválida (CINFO > 7)")
        }
        let headerCheck = (UInt16(cmf) << 8) | UInt16(flg)
        guard headerCheck % 31 == 0 else {
            throw .invalid(context: context, reason: "checksum de cabeçalho zlib inválido")
        }
        if (flg & 0x20) != 0 {
            throw .unsupported(context: context, reason: "dicionário zlib predefinido (FDICT)")
        }

        var output: [UInt8] = []
        let remaining = bytes.count - start
        let estimated = remaining <= (Int.max / 2) ? remaining * 2 : maxOutput
        output.reserveCapacity(min(maxOutput, min(estimated, 65_536)))

        var isFinal = false
        while !isFinal {
            isFinal = try bits.readBits(1, context: context) == 1
            let blockType = try bits.readBits(2, context: context)

            switch blockType {
            case 0:
                try decodeStoredBlock(&bits, into: &output, maxOutput: maxOutput, context: context)
            case 1:
                try decodeCompressedBlock(
                    &bits,
                    litLen: fixedLitLenTable,
                    dist: fixedDistTable,
                    into: &output,
                    maxOutput: maxOutput,
                    context: context
                )
            case 2:
                let (litLen, dist) = try readDynamicTables(&bits, context: context)
                try decodeCompressedBlock(
                    &bits,
                    litLen: litLen,
                    dist: dist,
                    into: &output,
                    maxOutput: maxOutput,
                    context: context
                )
            default:
                throw .invalid(context: context, reason: "tipo de bloco DEFLATE inválido")
            }
        }

        bits.alignToByte()
        let expectedAdler = try bits.readAlignedU32BE(context)
        guard adler32(output) == expectedAdler else {
            throw .invalid(context: context, reason: "checksum Adler-32 inválido")
        }
        return output
    }

    private static func decodeStoredBlock(
        _ bits: inout BitReader,
        into output: inout [UInt8],
        maxOutput: Int,
        context: String
    ) throws(CajuToolsError) {
        bits.alignToByte()
        let len = Int(try bits.readAlignedU16LE(context))
        let nlen = Int(try bits.readAlignedU16LE(context))
        guard (len ^ nlen) == 0xFFFF else {
            throw .invalid(context: context, reason: "comprimento de bloco não comprimido inválido")
        }
        guard len <= maxOutput - output.count else {
            let requested = try checkedAdd(output.count, len, context)
            throw .limitExceeded(context: context, limit: maxOutput, requested: requested)
        }
        try bits.appendAlignedBytes(len, into: &output, context: context)
    }

    private static func readDynamicTables(
        _ bits: inout BitReader,
        context: String
    ) throws(CajuToolsError) -> (HuffmanTable, HuffmanTable) {
        let hlit = try bits.readBits(5, context: context) + 257
        let hdist = try bits.readBits(5, context: context) + 1
        let hclen = try bits.readBits(4, context: context) + 4

        guard hlit <= 286 else {
            throw .invalid(context: context, reason: "HLIT excede 286")
        }
        guard hdist <= 32 else {
            throw .invalid(context: context, reason: "HDIST excede 32")
        }

        var codeLenLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            codeLenLengths[codeLengthOrder[i]] = try bits.readBits(3, context: context)
        }
        let codeLenTable = try HuffmanTable(
            lengths: codeLenLengths,
            allowEmpty: false,
            allowSingleCode: false,
            context: context
        )

        let totalCodes = hlit + hdist
        var lengths: [Int] = []
        lengths.reserveCapacity(totalCodes)

        while lengths.count < totalCodes {
            let sym = try codeLenTable.decode(&bits, context: context)
            if sym < 16 {
                lengths.append(sym)
            } else if sym == 16 {
                guard let prev = lengths.last else {
                    throw .invalid(context: context, reason: "código 16 sem comprimento anterior")
                }
                let repeatCount = 3 + (try bits.readBits(2, context: context))
                guard lengths.count + repeatCount <= totalCodes else {
                    throw .invalid(context: context, reason: "repetição excede HLIT+HDIST")
                }
                for _ in 0..<repeatCount { lengths.append(prev) }
            } else if sym == 17 || sym == 18 {
                let extraBits = sym == 17 ? 3 : 7
                let baseRepeat = sym == 17 ? 3 : 11
                let repeatCount = baseRepeat + (try bits.readBits(extraBits, context: context))
                guard lengths.count + repeatCount <= totalCodes else {
                    throw .invalid(context: context, reason: "zeros excedem HLIT+HDIST")
                }
                for _ in 0..<repeatCount { lengths.append(0) }
            } else {
                throw .invalid(context: context, reason: "símbolo de comprimento inválido")
            }
        }

        guard lengths[256] > 0 else {
            throw .invalid(context: context, reason: "símbolo de fim de bloco (256) ausente")
        }

        let litLenTable = try HuffmanTable(
            lengths: Array(lengths[0..<hlit]),
            allowEmpty: false,
            allowSingleCode: false,
            context: context
        )
        let distTable = try HuffmanTable(
            lengths: Array(lengths[hlit..<totalCodes]),
            allowEmpty: true,
            allowSingleCode: true,
            context: context
        )
        return (litLenTable, distTable)
    }

    private static func decodeCompressedBlock(
        _ bits: inout BitReader,
        litLen: HuffmanTable,
        dist: HuffmanTable,
        into output: inout [UInt8],
        maxOutput: Int,
        context: String
    ) throws(CajuToolsError) {
        while true {
            let sym = try litLen.decode(&bits, context: context)
            if sym < 256 {
                guard output.count < maxOutput else {
                    let requested = try checkedAdd(output.count, 1, context)
                    throw .limitExceeded(context: context, limit: maxOutput, requested: requested)
                }
                output.append(UInt8(sym))
            } else if sym == 256 {
                break
            } else {
                guard sym <= 285 else {
                    throw .invalid(context: context, reason: "símbolo literal/comprimento inválido")
                }
                let length: Int
                if sym == 285 {
                    length = 258
                } else {
                    let lenIndex = sym - 257
                    let extra = lengthExtraBits[lenIndex]
                    let extraVal = extra > 0 ? try bits.readBits(extra, context: context) : 0
                    length = lengthBases[lenIndex] + extraVal
                }

                let distSym = try dist.decode(&bits, context: context)
                guard distSym < 30 else {
                    throw .invalid(context: context, reason: "símbolo de distância DEFLATE inválido")
                }
                let distExtra = distanceExtraBits[distSym]
                let distExtraVal = distExtra > 0 ? try bits.readBits(distExtra, context: context) : 0
                let distance = distanceBases[distSym] + distExtraVal

                guard distance >= 1, distance <= output.count else {
                    throw .invalid(context: context, reason: "distância DEFLATE excede saída atual")
                }
                guard length <= maxOutput - output.count else {
                    let requested = try checkedAdd(output.count, length, context)
                    throw .limitExceeded(context: context, limit: maxOutput, requested: requested)
                }

                var srcIndex = output.count - distance
                for _ in 0..<length {
                    output.append(output[srcIndex])
                    srcIndex += 1
                }
            }
        }
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        let modBase: UInt32 = 65_521
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        var index = 0
        while index < data.count {
            let blockEnd = min(data.count, index + 5552)
            while index < blockEnd {
                s1 &+= UInt32(data[index])
                s2 &+= s1
                index += 1
            }
            s1 %= modBase
            s2 %= modBase
        }
        return (s2 << 16) | s1
    }

    private static func makeFixedLitLenTable() -> HuffmanTable {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0...143 { lengths[i] = 8 }
        for i in 144...255 { lengths[i] = 9 }
        for i in 256...279 { lengths[i] = 7 }
        for i in 280...287 { lengths[i] = 8 }
        return HuffmanTable(uncheckedLengths: lengths)
    }

    private static func makeFixedDistTable() -> HuffmanTable {
        HuffmanTable(uncheckedLengths: [Int](repeating: 5, count: 32))
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var byteOffset: Int
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0

    init(bytes: [UInt8], offset: Int) {
        self.bytes = bytes
        self.byteOffset = offset
    }

    mutating func readBits(_ count: Int, context: String) throws(CajuToolsError) -> Int {
        if count == 0 { return 0 }
        fillBuffer(upTo: count)
        guard bitCount >= count else {
            throw .truncated(context: context)
        }
        let mask = (UInt64(1) << UInt64(count)) - 1
        let value = Int(bitBuffer & mask)
        bitBuffer >>= UInt64(count)
        bitCount -= count
        return value
    }

    mutating func peekUpTo9Bits() -> (bits: Int, available: Int) {
        fillBuffer(upTo: 9)
        return (Int(bitBuffer & 0x1FF), min(bitCount, 9))
    }

    mutating func consumeBits(_ count: Int) {
        bitBuffer >>= UInt64(count)
        bitCount -= count
    }

    mutating func alignToByte() {
        let discard = bitCount & 7
        bitBuffer >>= UInt64(discard)
        bitCount -= discard
        byteOffset -= bitCount >> 3
        bitBuffer = 0
        bitCount = 0
    }

    mutating func readAlignedU8(_ context: String) throws(CajuToolsError) -> UInt8 {
        guard byteOffset < bytes.count else {
            throw .truncated(context: context)
        }
        defer { byteOffset += 1 }
        return bytes[byteOffset]
    }

    mutating func readAlignedU16LE(_ context: String) throws(CajuToolsError) -> UInt16 {
        guard bytes.count - byteOffset >= 2 else {
            throw .truncated(context: context)
        }
        defer { byteOffset += 2 }
        return UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
    }

    mutating func readAlignedU32BE(_ context: String) throws(CajuToolsError) -> UInt32 {
        guard bytes.count - byteOffset >= 4 else {
            throw .truncated(context: context)
        }
        defer { byteOffset += 4 }
        return (UInt32(bytes[byteOffset]) << 24)
            | (UInt32(bytes[byteOffset + 1]) << 16)
            | (UInt32(bytes[byteOffset + 2]) << 8)
            | UInt32(bytes[byteOffset + 3])
    }

    mutating func appendAlignedBytes(
        _ count: Int,
        into output: inout [UInt8],
        context: String
    ) throws(CajuToolsError) {
        guard count >= 0, bytes.count - byteOffset >= count else {
            throw .truncated(context: context)
        }
        output.append(contentsOf: bytes[byteOffset..<(byteOffset + count)])
        byteOffset += count
    }

    private mutating func fillBuffer(upTo needed: Int) {
        while bitCount < needed, byteOffset < bytes.count {
            bitBuffer |= UInt64(bytes[byteOffset]) << UInt64(bitCount)
            byteOffset += 1
            bitCount += 8
        }
    }
}

private struct HuffmanTable: Sendable {
    private static let maxBits = 15
    private static let fastBits = 9
    private static let fastSize = 1 << fastBits

    private let isEmpty: Bool
    private let counts: [Int]
    private let symbols: [UInt16]
    private let fastTable: [UInt32]

    init(
        lengths: [Int],
        allowEmpty: Bool,
        allowSingleCode: Bool,
        context: String
    ) throws(CajuToolsError) {
        var counts = [Int](repeating: 0, count: Self.maxBits + 1)
        for len in lengths {
            guard len >= 0, len <= Self.maxBits else {
                throw .invalid(context: context, reason: "comprimento Huffman fora da faixa")
            }
            counts[len] += 1
        }

        if counts[0] == lengths.count {
            guard allowEmpty else {
                throw .invalid(context: context, reason: "árvore Huffman vazia")
            }
            self.isEmpty = true
            self.counts = counts
            self.symbols = []
            self.fastTable = []
            return
        }

        var left = 1
        for len in 1...Self.maxBits {
            left <<= 1
            left -= counts[len]
            if left < 0 {
                throw .invalid(context: context, reason: "árvore Huffman sobre-subscrita")
            }
        }
        if left > 0 {
            let isSingleDistCode = allowSingleCode && counts[1] == 1 && left == (1 << (Self.maxBits - 1))
            guard isSingleDistCode else {
                throw .invalid(context: context, reason: "árvore Huffman sub-subscrita")
            }
        }

        self.isEmpty = false
        self.counts = counts
        let (builtSymbols, builtFast) = Self.buildTables(lengths: lengths, counts: counts)
        self.symbols = builtSymbols
        self.fastTable = builtFast
    }

    init(uncheckedLengths lengths: [Int]) {
        var counts = [Int](repeating: 0, count: Self.maxBits + 1)
        for len in lengths { counts[len] += 1 }
        self.isEmpty = false
        self.counts = counts
        let (builtSymbols, builtFast) = Self.buildTables(lengths: lengths, counts: counts)
        self.symbols = builtSymbols
        self.fastTable = builtFast
    }

    private static func buildTables(lengths: [Int], counts: [Int]) -> ([UInt16], [UInt32]) {
        var offsets = [Int](repeating: 0, count: maxBits + 1)
        for len in 1..<maxBits {
            offsets[len + 1] = offsets[len] + counts[len]
        }
        var symbols = [UInt16](repeating: 0, count: lengths.count)
        var nextOffset = offsets
        for (sym, len) in lengths.enumerated() where len != 0 {
            symbols[nextOffset[len]] = UInt16(sym)
            nextOffset[len] += 1
        }

        var fast = [UInt32](repeating: 0, count: fastSize)
        var code = 0
        var symIndex = 0
        for len in 1...fastBits {
            let count = counts[len]
            let step = 1 << len
            let packedLen = UInt32(len) << 16
            for i in 0..<count {
                let sym = symbols[symIndex + i]
                let entry = packedLen | UInt32(sym)
                var idx = reverseBits(code, length: len)
                while idx < fastSize {
                    fast[idx] = entry
                    idx += step
                }
                code += 1
            }
            symIndex += count
            code <<= 1
        }
        return (symbols, fast)
    }

    private static func reverseBits(_ value: Int, length: Int) -> Int {
        var v = value
        var r = 0
        for _ in 0..<length {
            r = (r << 1) | (v & 1)
            v >>= 1
        }
        return r
    }

    func decode(_ bits: inout BitReader, context: String) throws(CajuToolsError) -> Int {
        guard !isEmpty else {
            throw .invalid(context: context, reason: "árvore Huffman vazia")
        }
        let (peek, available) = bits.peekUpTo9Bits()
        let fastEntry = fastTable[peek]
        if fastEntry != 0 {
            let len = Int(fastEntry >> 16)
            guard available >= len else {
                throw .truncated(context: context)
            }
            bits.consumeBits(len)
            return Int(fastEntry & 0xFFFF)
        }

        var code = 0
        var first = 0
        var index = 0
        for len in 1...Self.maxBits {
            code |= try bits.readBits(1, context: context)
            let count = counts[len]
            if code - count < first {
                return Int(symbols[index + (code - first)])
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw .invalid(context: context, reason: "código Huffman inválido")
    }
}
