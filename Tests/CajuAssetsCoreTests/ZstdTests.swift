import CajuAssetsCore
import CajuTesting
import Testing

@Suite("Zstd & KTX2 Supercompression")
struct ZstdTests {
    // MARK: - Casos válidos Zstd (RFC 8878)

    @Test func decompressesEmptyAndRawBlocks() throws {
        // Quadro vazio (FCS = 0, bloco raw tamanho 0, com checksum XXH64("") = 0x51D8E999)
        let emptyWithChecksum: [UInt8] = [
            0x28, 0xB5, 0x2F, 0xFD,  // magic
            0x24,  // FHD: singleSegment=1, checksum=1, fcsFlag=0 (1 byte FCS)
            0x00,  // FCS = 0
            0x01, 0x00, 0x00,  // lastBlock=1, type=0 (raw), size=0
            0x99, 0xE9, 0xD8, 0x51,  // XXH64("") low 32 bits LE
        ]
        #expect(try ZstdDecoder.decompress(emptyWithChecksum, expectedSize: 0) == [])

        // Blocos raw múltiplos + FCS de 2 bytes (256 + raw16)
        let payload = Array((0..<300).map { UInt8(($0 * 7 + 3) & 0xFF) })
        let rawMulti = SyntheticZstdEncoder.encodeRawFrame(
            payload,
            maxBlockSize: 100,
            singleSegment: false,
            includeFCS: true,
            includeChecksum: true
        )
        #expect(try ZstdDecoder.decompress(rawMulti, expectedSize: payload.count) == payload)
        #expect(try ZstdDecoder.decompress(rawMulti) == payload)
    }

    @Test func decompressesRLEAndMixedRawRLEBlocks() throws {
        let part1 = [UInt8](repeating: 0x5A, count: 512)
        let part2 = Array("CajuEngine-Zstd-RLE-Test".utf8)
        let combined = part1 + part2

        let frame = SyntheticZstdEncoder.encodeMixedRawAndRLE(
            blocks: [
                .rle(byte: 0x5A, count: 512),
                .raw(part2),
            ],
            totalSize: combined.count,
            includeChecksum: true
        )
        #expect(try ZstdDecoder.decompress(frame, expectedSize: combined.count) == combined)
    }

    @Test func decompressesCompressedBlockWithPredefinedFSEAndRepeatOffsets() throws {
        // Testa sequências com:
        // 1) offset > 3, literalLength > 15 (extra bits), matchLength > 34 (extra bits)
        // 2) repeat offset 1, 2, 3 com literalLength > 0
        // 3) repeat offset 1, 2, 3 com literalLength == 0 (incluindo rep[0] - 1!)
        // 4) sobreposição (offset < matchLength)
        // 5) literais finais (trailing literals)
        var literals: [UInt8] = []
        var sequences: [SyntheticZstdEncoder.Sequence] = []
        var expected: [UInt8] = []

        // Seq 0: 20 literais ('A'..'T'), match offset=4 (codificado como offsetValue=7), len=40
        // Esperado após 20 literais: rep=[4, 1, 4], copia 40 bytes com passo 4 (sobreposição!).
        let lit0: [UInt8] = (0..<20).map { UInt8(65 + $0) }
        literals.append(contentsOf: lit0)
        expected.append(contentsOf: lit0)
        for _ in 0..<40 {
            expected.append(expected[expected.count - 4])
        }
        sequences.append(.init(literalLength: 20, matchLength: 40, offsetValue: 7))

        // Seq 1: 2 literais ("XY"), offsetValue=2 (rep[1] = 1 -> vira rep[0]=1, rep[1]=4, rep[2]=4), matchLen=5
        let lit1: [UInt8] = [88, 89]
        literals.append(contentsOf: lit1)
        expected.append(contentsOf: lit1)
        for _ in 0..<5 { expected.append(expected[expected.count - 1]) }
        sequences.append(.init(literalLength: 2, matchLength: 5, offsetValue: 2))

        // Seq 2: literalLength=0, offsetValue=1 (como ll==0, usa rep[1] = 4 -> rep=[4, 1, 4]), matchLen=6
        for _ in 0..<6 { expected.append(expected[expected.count - 4]) }
        sequences.append(.init(literalLength: 0, matchLength: 6, offsetValue: 1))

        // Seq 3: literalLength=0, offsetValue=3 (como ll==0, usa rep[0]-1 = 3 -> rep=[3, 4, 1]), matchLen=4
        for _ in 0..<4 { expected.append(expected[expected.count - 3]) }
        sequences.append(.init(literalLength: 0, matchLength: 4, offsetValue: 3))

        // Trailing literals
        let tail = Array("END".utf8)
        literals.append(contentsOf: tail)
        expected.append(contentsOf: tail)

        let compressed = SyntheticZstdEncoder.encodeCompressedFrame(
            blocks: [
                .init(
                    literalsMode: .raw(literals),
                    llMode: .predefined,
                    ofMode: .predefined,
                    mlMode: .predefined,
                    sequences: sequences
                )
            ],
            totalSize: expected.count,
            includeChecksum: true
        )

        let decoded = try ZstdDecoder.decompress(compressed, expectedSize: expected.count)
        #expect(decoded == expected)
    }

    @Test func decompressesHuffmanLiteralsSingleAndFourStreamsAndFSEWeights() throws {
        // 1 fluxo Huffman com pesos diretos (>= 128) + tabelas FSE customizadas (FSE_Compressed_Mode)
        let litsValid = Array("0123456789ABCDEFGHIJKLMN".utf8)  // 24 bytes
        let frameDirect = SyntheticZstdEncoder.encodeCompressedFrame(
            blocks: [
                .init(
                    literalsMode: .huffmanDirect(litsValid, fourStreams: false),
                    // syms 4 e 16 (base 16+1bit)
                    llMode: .custom(
                        counts: [0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16],
                        accuracyLog: 5
                    ),
                    ofMode: .rle(symbol: 4),  // ofCode = 4 (offsetValues 16..31)
                    mlMode: .rle(symbol: 2),  // matchLength = 5
                    sequences: [
                        .init(literalLength: 16, matchLength: 5, offsetValue: 19),  // actual = 16
                        .init(literalLength: 4, matchLength: 5, offsetValue: 19),  // actual = 16
                    ]
                )
            ],
            totalSize: nil,
            includeChecksum: true
        )
        var expectedDirect = Array(litsValid[0..<16])
        for _ in 0..<5 { expectedDirect.append(expectedDirect[expectedDirect.count - 16]) }
        expectedDirect.append(contentsOf: litsValid[16..<20])
        for _ in 0..<5 { expectedDirect.append(expectedDirect[expectedDirect.count - 16]) }
        expectedDirect.append(contentsOf: litsValid[20..<24])

        #expect(
            try ZstdDecoder.decompress(frameDirect, expectedSize: expectedDirect.count) == expectedDirect
        )

        // 4 fluxos Huffman com pesos comprimidos por FSE + Bloco 2 usando Treeless_Literals e Repeat_Mode!
        let block1Lits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        let block2Lits = Array("CAJU_TREELESS_REPEAT_BLOCK_2_DATA".utf8)
        let multiBlockFrame = SyntheticZstdEncoder.encodeCompressedFrame(
            blocks: [
                .init(
                    literalsMode: .huffmanFSEWeights(block1Lits, fourStreams: true),
                    llMode: .predefined,
                    ofMode: .predefined,
                    mlMode: .predefined,
                    sequences: [
                        .init(literalLength: 20, matchLength: 6, offsetValue: 13)  // actual offset 10
                    ]
                ),
                .init(
                    literalsMode: .treeless(block2Lits),
                    llMode: .repeatPrevious,
                    ofMode: .repeatPrevious,
                    mlMode: .repeatPrevious,
                    sequences: [
                        .init(literalLength: 12, matchLength: 8, offsetValue: 18)  // actual offset 15
                    ]
                ),
            ],
            totalSize: nil,
            includeChecksum: true
        )

        var expectedMulti = Array(block1Lits[0..<20])
        for _ in 0..<6 { expectedMulti.append(expectedMulti[expectedMulti.count - 10]) }
        expectedMulti.append(contentsOf: block1Lits[20..<block1Lits.count])
        expectedMulti.append(contentsOf: block2Lits[0..<12])
        for _ in 0..<8 { expectedMulti.append(expectedMulti[expectedMulti.count - 15]) }
        expectedMulti.append(contentsOf: block2Lits[12..<block2Lits.count])

        #expect(
            try ZstdDecoder.decompress(multiBlockFrame, expectedSize: expectedMulti.count) == expectedMulti
        )
    }

    @Test func decompressesConcatenatedMultiFrameStream() throws {
        let a = Array("Primeiro quadro ".utf8)
        let b = Array("Segundo quadro!".utf8)
        let stream =
            SyntheticZstdEncoder.encodeRawFrame(
                a, maxBlockSize: 64, singleSegment: true, includeFCS: true, includeChecksum: true)
            + SyntheticZstdEncoder.encodeRawFrame(
                b, maxBlockSize: 64, singleSegment: true, includeFCS: true, includeChecksum: true)

        #expect(try ZstdDecoder.decompress(stream, expectedSize: a.count + b.count) == (a + b))
    }

    // MARK: - Rejeições e Limites

    @Test func rejectsDictionariesSkippableLegacyAndInvalidFrames() {
        // Dicionário (dictIDFlag = 1, 2, 3) -> unsupported
        for flag: UInt8 in 1...3 {
            let bytes: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20 | flag, 0x00, 0x01, 0x00, 0x00]
            #expect {
                _ = try ZstdDecoder.decompress(bytes)
            } throws: { error in
                if case .unsupported = error as? AssetError { return true }
                return false
            }
        }

        // Skippable frame (0x184D2A50) -> unsupported
        let skippable: [UInt8] = [0x50, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00]
        #expect {
            _ = try ZstdDecoder.decompress(skippable)
        } throws: { error in
            if case .unsupported = error as? AssetError { return true }
            return false
        }

        // Legacy frame (0xFD2FB524) -> unsupported
        let legacy: [UInt8] = [0x24, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x00, 0x00]
        #expect {
            _ = try ZstdDecoder.decompress(legacy)
        } throws: { error in
            if case .unsupported = error as? AssetError { return true }
            return false
        }

        // Magic inválido -> invalid
        let badMagic: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x00]
        #expect {
            _ = try ZstdDecoder.decompress(badMagic)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Tipo de bloco reservado (3) -> invalid
        let reservedBlock: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00, 0x07, 0x00, 0x00]
        #expect {
            _ = try ZstdDecoder.decompress(reservedBlock)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Corrupted checksum -> invalid (also check Treeless/Repeat on first block & out-of-bounds offset)
        let treelessFirst: [UInt8] = [
            0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00,
            0x0D, 0x00, 0x00,  // last=1, type=2 (compressed), size=1 (wait need size >= 3)
        ]
        _ = treelessFirst
        let badTreeless: [UInt8] = [
            0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x02,
            0x25, 0x00, 0x00,  // last=1, type=2 (compressed), size=4
            0x03, 0x20, 0x00, 0x00,  // treeless litType=3, sizeFormat=0, regen=2, comp=0 -> no prev table
        ]
        #expect {
            _ = try ZstdDecoder.decompress(badTreeless)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Checksum XXH64 corrompido -> invalid
        var badChecksum = SyntheticZstdEncoder.encodeRawFrame(
            [1, 2, 3, 4],
            maxBlockSize: 16,
            singleSegment: true,
            includeFCS: true,
            includeChecksum: true
        )
        badChecksum[badChecksum.count - 1] ^= 0x01
        #expect {
            _ = try ZstdDecoder.decompress(badChecksum, expectedSize: 4)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }
    }

    @Test func enforcesExpectedSizeAndLimitsBeforeAllocatingAndRejectsTruncation() {
        // Cabeçalho mínimo de 12 bytes alegando FCS = 500_000_000 (bomba Zstd)
        let fcsBomb: [UInt8] = [
            0x28, 0xB5, 0x2F, 0xFD,
            0xA0,  // fcsFlag=2 (4 bytes), singleSegment=1
            0x00, 0x65, 0xCD, 0x1D,  // 500_000_000 LE
            0x01, 0x00, 0x00,
        ]
        #expect {
            _ = try ZstdDecoder.decompress(
                fcsBomb,
                expectedSize: nil,
                limits: AssetLimits(maxOutputBytes: 4096)
            )
        } throws: { error in
            if case .limitExceeded = error as? AssetError { return true }
            return false
        }

        // expectedSize menor que saída real
        let raw = SyntheticZstdEncoder.encodeRawFrame(
            [10, 20, 30, 40],
            maxBlockSize: 16,
            singleSegment: true,
            includeFCS: true,
            includeChecksum: false
        )
        #expect {
            _ = try ZstdDecoder.decompress(raw, expectedSize: 2)
        } throws: { error in
            if case .limitExceeded = error as? AssetError { return true }
            return false
        }

        // expectedSize maior que saída real
        #expect {
            _ = try ZstdDecoder.decompress(raw, expectedSize: 8)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Truncamentos em todos os prefixos
        for cut in 0..<raw.count {
            #expect(throws: AssetError.self) {
                _ = try ZstdDecoder.decompress(Array(raw[0..<cut]))
            }
        }
    }

    // MARK: - Integração KTX2 (decompressLevel)

    @Test func ktx2DecompressesZstdZlibAndNoneLevels() throws {
        let level0Raw = Array((0..<64).map { UInt8(($0 * 13) & 0xFF) })
        let level1Raw = Array("KTX2-MIP-1-ZSTD!".utf8)
        let level0Zstd = SyntheticZstdEncoder.encodeCompressedFrame(
            blocks: [
                .init(
                    literalsMode: .huffmanFSEWeights(level0Raw, fourStreams: false),
                    llMode: .predefined,
                    ofMode: .predefined,
                    mlMode: .predefined,
                    sequences: []
                )
            ],
            totalSize: level0Raw.count,
            includeChecksum: true
        )
        let level1Zstd = SyntheticZstdEncoder.encodeRawFrame(
            level1Raw,
            maxBlockSize: 64,
            singleSegment: true,
            includeFCS: true,
            includeChecksum: true
        )

        let ktx2Zstd = buildKTX2(
            scheme: 2,
            levels: [
                (level0Zstd, UInt64(level0Raw.count)),
                (level1Zstd, UInt64(level1Raw.count)),
            ]
        )
        let container = try KTX2Container.parse(ktx2Zstd)
        #expect(container.supercompressionScheme == .zstd)
        #expect(try container.decompressLevel(0, from: ktx2Zstd) == level0Raw)
        #expect(try container.decompressLevel(1, from: ktx2Zstd) == level1Raw)

        // Limite menor que uncompressedByteLength rejeita antes de alocar
        #expect {
            _ = try container.decompressLevel(0, from: ktx2Zstd, limits: AssetLimits(maxOutputBytes: 32))
        } throws: { error in
            if case .limitExceeded = error as? AssetError { return true }
            return false
        }

        // Scheme .none (0)
        let ktx2None = buildKTX2(scheme: 0, levels: [(level1Raw, UInt64(level1Raw.count))])
        let cNone = try KTX2Container.parse(ktx2None)
        #expect(try cNone.decompressLevel(0, from: ktx2None) == level1Raw)

        // Scheme .zlib (3)
        let zlibPayload = SyntheticZstdEncoder.zlibStored(level1Raw)
        let ktx2Zlib = buildKTX2(scheme: 3, levels: [(zlibPayload, UInt64(level1Raw.count))])
        let cZlib = try KTX2Container.parse(ktx2Zlib)
        #expect(try cZlib.decompressLevel(0, from: ktx2Zlib) == level1Raw)

        // Scheme .basisLZ (1) -> unsupported
        let ktx2Basis = buildKTX2(scheme: 1, levels: [([1, 2, 3], 0)], vkFormat: 0, colorModel: 163)
        let cBasis = try KTX2Container.parse(ktx2Basis)
        #expect {
            _ = try cBasis.decompressLevel(0, from: ktx2Basis)
        } throws: { error in
            if case .unsupported = error as? AssetError { return true }
            return false
        }
    }

    // MARK: - Fuzz Determinístico

    @Test func fuzzZstd2000() {
        let seed1 = SyntheticZstdEncoder.encodeCompressedFrame(
            blocks: [
                .init(
                    literalsMode: .huffmanDirect(
                        Array("CAJU_FUZZ_SEED_DATA_0123456789".utf8), fourStreams: false),
                    llMode: .predefined,
                    ofMode: .predefined,
                    mlMode: .predefined,
                    sequences: [.init(literalLength: 12, matchLength: 5, offsetValue: 11)]
                )
            ],
            totalSize: nil,
            includeChecksum: true
        )
        let seed2 = SyntheticZstdEncoder.encodeRawFrame(
            [1, 2, 3, 4, 5, 6, 7, 8],
            maxBlockSize: 4,
            singleSegment: true,
            includeFCS: true,
            includeChecksum: true
        )
        let seeds = [seed1, seed2]
        let limits = AssetLimits(maxInputBytes: 2048, maxOutputBytes: 2048)

        CajuFuzz.run(seed: 0x5A53_5444, iterations: 2_000) { rng, i in
            let input: [UInt8]
            if i % 3 == 0 {
                let len = Int(rng.nextUInt32() % 256)
                var buf = [UInt8](repeating: 0, count: len)
                for idx in 0..<len {
                    buf[idx] = UInt8(rng.nextUInt32() & 0xFF)
                }
                if len >= 4 && i % 6 == 0 {
                    buf[0] = 0x28
                    buf[1] = 0xB5
                    buf[2] = 0x2F
                    buf[3] = 0xFD
                }
                input = buf
            } else {
                var mutated = seeds[i % seeds.count]
                let op = rng.nextUInt32() % 4
                if op == 0 && mutated.count > 1 {
                    let cut = Int(rng.nextUInt32()) % mutated.count
                    mutated = Array(mutated[0..<cut])
                } else {
                    let flips = 1 + Int(rng.nextUInt32() % 4)
                    for _ in 0..<flips {
                        let idx = Int(rng.nextUInt32()) % mutated.count
                        mutated[idx] ^= UInt8((rng.nextUInt32() & 0xFF) | 1)
                    }
                }
                input = mutated
            }

            do {
                let out = try ZstdDecoder.decompress(input, expectedSize: nil, limits: limits)
                #expect(out.count <= limits.maxOutputBytes)
            } catch {
                // Typed throws(AssetError) garante apenas AssetError.
            }
        }
    }

    // MARK: - Helper KTX2 mínimo para testes

    private func buildKTX2(
        scheme: UInt32,
        levels: [([UInt8], UInt64)],
        vkFormat: UInt32 = 37,
        colorModel: UInt8 = 1
    ) -> [UInt8] {
        var bytes: [UInt8] = [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]
        func appendU32(_ v: UInt32) {
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 24) & 0xFF))
        }
        func writeU32(_ v: UInt32, at off: Int) {
            bytes[off] = UInt8(v & 0xFF)
            bytes[off + 1] = UInt8((v >> 8) & 0xFF)
            bytes[off + 2] = UInt8((v >> 16) & 0xFF)
            bytes[off + 3] = UInt8((v >> 24) & 0xFF)
        }
        func writeU64(_ v: UInt64, at off: Int) {
            for i in 0..<8 { bytes[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }

        appendU32(vkFormat)
        appendU32(1)
        appendU32(4)
        appendU32(4)
        appendU32(0)
        appendU32(0)
        appendU32(1)
        appendU32(UInt32(levels.count))
        appendU32(scheme)
        for _ in 0..<32 { bytes.append(0) }
        for _ in 0..<(levels.count * 24) { bytes.append(0) }

        while bytes.count % 4 != 0 { bytes.append(0) }
        let dfdOff = UInt32(bytes.count)
        appendU32(44)
        appendU32(0)
        appendU32(2 | (40 << 16))
        bytes.append(contentsOf: [colorModel, 1, 2, 0])
        for _ in 0..<28 { bytes.append(0) }
        writeU32(dfdOff, at: 48)
        writeU32(44, at: 52)

        for i in stride(from: levels.count - 1, through: 0, by: -1) {
            if scheme == 0 {
                while bytes.count % 4 != 0 { bytes.append(0) }
            }
            let off = UInt64(bytes.count)
            let (data, ulen) = levels[i]
            bytes.append(contentsOf: data)
            let base = 80 + i * 24
            writeU64(off, at: base)
            writeU64(UInt64(data.count), at: base + 8)
            writeU64(ulen, at: base + 16)
        }
        return bytes
    }
}

// MARK: - Codificador Zstd Sintético (RFC 8878) para Vetores de Teste

private enum SyntheticZstdEncoder {
    enum RawOrRLEBlock {
        case raw([UInt8])
        case rle(byte: UInt8, count: Int)
    }

    enum LiteralsSpec {
        case raw([UInt8])
        case rle(byte: UInt8, count: Int)
        case huffmanDirect([UInt8], fourStreams: Bool)
        case huffmanFSEWeights([UInt8], fourStreams: Bool)
        case treeless([UInt8])
    }

    enum FSEModeSpec {
        case predefined
        case rle(symbol: UInt8)
        case custom(counts: [Int], accuracyLog: Int)
        case repeatPrevious
    }

    struct Sequence {
        let literalLength: Int
        let matchLength: Int
        let offsetValue: Int
    }

    struct CompressedBlockSpec {
        let literalsMode: LiteralsSpec
        let llMode: FSEModeSpec
        let ofMode: FSEModeSpec
        let mlMode: FSEModeSpec
        let sequences: [Sequence]
    }

    static func encodeRawFrame(
        _ payload: [UInt8],
        maxBlockSize: Int,
        singleSegment: Bool,
        includeFCS: Bool,
        includeChecksum: Bool
    ) -> [UInt8] {
        var out: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        appendFrameHeader(
            size: includeFCS ? payload.count : nil,
            singleSegment: singleSegment,
            includeChecksum: includeChecksum,
            to: &out
        )

        if payload.isEmpty {
            appendBlockHeader(last: true, type: 0, size: 0, to: &out)
        } else {
            var pos = 0
            while pos < payload.count {
                let chunk = min(maxBlockSize, payload.count - pos)
                let last = (pos + chunk == payload.count)
                appendBlockHeader(last: last, type: 0, size: chunk, to: &out)
                out.append(contentsOf: payload[pos..<(pos + chunk)])
                pos += chunk
            }
        }

        if includeChecksum {
            appendU32LE(UInt32(truncatingIfNeeded: xxh64(payload)), to: &out)
        }
        return out
    }

    static func encodeMixedRawAndRLE(
        blocks: [RawOrRLEBlock],
        totalSize: Int,
        includeChecksum: Bool
    ) -> [UInt8] {
        var out: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        appendFrameHeader(
            size: totalSize,
            singleSegment: true,
            includeChecksum: includeChecksum,
            to: &out
        )
        var full: [UInt8] = []
        for (idx, blk) in blocks.enumerated() {
            let last = idx == blocks.count - 1
            switch blk {
            case .raw(let bytes):
                appendBlockHeader(last: last, type: 0, size: bytes.count, to: &out)
                out.append(contentsOf: bytes)
                full.append(contentsOf: bytes)
            case .rle(let b, let count):
                appendBlockHeader(last: last, type: 1, size: count, to: &out)
                out.append(b)
                full.append(contentsOf: repeatElement(b, count: count))
            }
        }
        if includeChecksum {
            appendU32LE(UInt32(truncatingIfNeeded: xxh64(full)), to: &out)
        }
        return out
    }

    static func encodeCompressedFrame(
        blocks: [CompressedBlockSpec],
        totalSize: Int?,
        includeChecksum: Bool
    ) -> [UInt8] {
        var out: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        appendFrameHeader(
            size: totalSize,
            singleSegment: false,
            includeChecksum: includeChecksum,
            to: &out
        )

        var prevHuff: TestHuffmanModel?
        var prevLL: TestFSEModel?
        var prevOF: TestFSEModel?
        var prevML: TestFSEModel?

        var simulatedOutput: [UInt8] = []
        var rep = (1, 4, 8)

        for (idx, spec) in blocks.enumerated() {
            var blockBytes: [UInt8] = []
            let lits: [UInt8]
            switch spec.literalsMode {
            case .raw(let d):
                lits = d
                appendRawOrRLELiterals(type: 0, size: d.count, payload: d, to: &blockBytes)
            case .rle(let b, let count):
                lits = [UInt8](repeating: b, count: count)
                appendRawOrRLELiterals(type: 1, size: count, payload: [b], to: &blockBytes)
            case .huffmanDirect(let d, let fourStreams):
                lits = d
                let model = TestHuffmanModel(data: d)
                prevHuff = model
                appendCompressedLiterals(
                    data: d,
                    type: 2,
                    fourStreams: fourStreams,
                    model: model,
                    fseWeights: false,
                    to: &blockBytes
                )
            case .huffmanFSEWeights(let d, let fourStreams):
                lits = d
                let model = TestHuffmanModel(data: d)
                prevHuff = model
                appendCompressedLiterals(
                    data: d,
                    type: 2,
                    fourStreams: fourStreams,
                    model: model,
                    fseWeights: true,
                    to: &blockBytes
                )
            case .treeless(let d):
                lits = d
                guard let model = prevHuff else {
                    fatalError("treeless exige tabela anterior no teste")
                }
                appendCompressedLiterals(
                    data: d,
                    type: 3,
                    fourStreams: d.count >= 6,
                    model: model,
                    fseWeights: false,
                    to: &blockBytes
                )
            }

            // Atualiza saída simulada para checksum XXH64
            var litPos = 0
            for seq in spec.sequences {
                simulatedOutput.append(contentsOf: lits[litPos..<(litPos + seq.literalLength)])
                litPos += seq.literalLength
                let actualOffset: Int
                if seq.offsetValue > 3 {
                    actualOffset = seq.offsetValue - 3
                    rep = (actualOffset, rep.0, rep.1)
                } else if seq.literalLength > 0 {
                    switch seq.offsetValue {
                    case 1: actualOffset = rep.0
                    case 2:
                        actualOffset = rep.1
                        rep = (actualOffset, rep.0, rep.2)
                    default:
                        actualOffset = rep.2
                        rep = (actualOffset, rep.0, rep.1)
                    }
                } else {
                    switch seq.offsetValue {
                    case 1:
                        actualOffset = rep.1
                        rep = (actualOffset, rep.0, rep.2)
                    case 2:
                        actualOffset = rep.2
                        rep = (actualOffset, rep.0, rep.1)
                    default:
                        actualOffset = rep.0 - 1
                        rep = (actualOffset, rep.0, rep.1)
                    }
                }
                var mSrc = simulatedOutput.count - actualOffset
                for _ in 0..<seq.matchLength {
                    simulatedOutput.append(simulatedOutput[mSrc])
                    mSrc += 1
                }
            }
            simulatedOutput.append(contentsOf: lits[litPos..<lits.count])

            // Codifica seção de sequências
            let nSeq = spec.sequences.count
            if nSeq == 0 {
                blockBytes.append(0)
            } else {
                if nSeq < 128 {
                    blockBytes.append(UInt8(nSeq))
                } else if nSeq < 0x7F00 {
                    blockBytes.append(UInt8(128 + (nSeq >> 8)))
                    blockBytes.append(UInt8(nSeq & 0xFF))
                } else {
                    blockBytes.append(255)
                    let adj = nSeq - 0x7F00
                    blockBytes.append(UInt8(adj & 0xFF))
                    blockBytes.append(UInt8(adj >> 8))
                }

                let llModeID = modeBits(spec.llMode)
                let ofModeID = modeBits(spec.ofMode)
                let mlModeID = modeBits(spec.mlMode)
                blockBytes.append((llModeID << 6) | (ofModeID << 4) | (mlModeID << 2))

                let llModel = resolveFSEModel(
                    spec.llMode,
                    predefinedCounts: predefinedLLCounts,
                    predefinedLog: 6,
                    prev: &prevLL,
                    to: &blockBytes
                )
                let ofModel = resolveFSEModel(
                    spec.ofMode,
                    predefinedCounts: predefinedOFCounts,
                    predefinedLog: 5,
                    prev: &prevOF,
                    to: &blockBytes
                )
                let mlModel = resolveFSEModel(
                    spec.mlMode,
                    predefinedCounts: predefinedMLCounts,
                    predefinedLog: 6,
                    prev: &prevML,
                    to: &blockBytes
                )

                let seqStream = encodeSequencesBitstream(
                    spec.sequences,
                    llModel: llModel,
                    ofModel: ofModel,
                    mlModel: mlModel
                )
                blockBytes.append(contentsOf: seqStream)
            }

            let isLast = idx == blocks.count - 1
            appendBlockHeader(last: isLast, type: 2, size: blockBytes.count, to: &out)
            out.append(contentsOf: blockBytes)
        }

        if includeChecksum {
            appendU32LE(UInt32(truncatingIfNeeded: xxh64(simulatedOutput)), to: &out)
        }
        return out
    }

    // MARK: - Helpers de Cabeçalho e Literais

    private static func appendFrameHeader(
        size: Int?,
        singleSegment: Bool,
        includeChecksum: Bool,
        to out: inout [UInt8]
    ) {
        let chkBit: UInt8 = includeChecksum ? 0x04 : 0x00
        let ssBit: UInt8 = singleSegment ? 0x20 : 0x00
        if let size {
            if singleSegment && size < 256 {
                out.append(chkBit | ssBit)
                out.append(UInt8(size))
            } else if size >= 256 && size <= 65_791 {
                out.append(0x40 | chkBit | ssBit)
                if !singleSegment { out.append(0x00) }  // Window = 1 KB
                let adj = size - 256
                out.append(UInt8(adj & 0xFF))
                out.append(UInt8(adj >> 8))
            } else {
                out.append(0x80 | chkBit | ssBit)
                if !singleSegment { out.append(0x00) }
                appendU32LE(UInt32(size), to: &out)
            }
        } else {
            out.append(chkBit)  // singleSegment=0, fcsFlag=0
            out.append(0x20)  // Window = 16 KB
        }
    }

    private static func appendBlockHeader(last: Bool, type: Int, size: Int, to out: inout [UInt8]) {
        let header = (last ? 1 : 0) | (type << 1) | (size << 3)
        out.append(UInt8(header & 0xFF))
        out.append(UInt8((header >> 8) & 0xFF))
        out.append(UInt8((header >> 16) & 0xFF))
    }

    private static func appendRawOrRLELiterals(type: Int, size: Int, payload: [UInt8], to out: inout [UInt8])
    {
        if size < 32 {
            out.append(UInt8(type | (0 << 2) | (size << 3)))
        } else {
            out.append(UInt8(type | (1 << 2) | ((size & 0x0F) << 4)))
            out.append(UInt8(size >> 4))
        }
        out.append(contentsOf: payload)
    }

    private static func appendCompressedLiterals(
        data: [UInt8],
        type: Int,
        fourStreams: Bool,
        model: TestHuffmanModel,
        fseWeights: Bool,
        to out: inout [UInt8]
    ) {
        var payload: [UInt8] = []
        if type == 2 {
            if fseWeights {
                payload.append(contentsOf: model.encodeHeaderFSEWeights())
            } else {
                payload.append(contentsOf: model.encodeHeaderDirectWeights())
            }
        }

        if fourStreams {
            let per = (data.count + 3) / 4
            let s1 = model.encodeStream(Array(data[0..<per]))
            let s2 = model.encodeStream(Array(data[per..<(2 * per)]))
            let s3 = model.encodeStream(Array(data[(2 * per)..<(3 * per)]))
            let s4 = model.encodeStream(Array(data[(3 * per)..<data.count]))
            appendU16LE(UInt16(s1.count), to: &payload)
            appendU16LE(UInt16(s2.count), to: &payload)
            appendU16LE(UInt16(s3.count), to: &payload)
            payload.append(contentsOf: s1)
            payload.append(contentsOf: s2)
            payload.append(contentsOf: s3)
            payload.append(contentsOf: s4)
        } else {
            payload.append(contentsOf: model.encodeStream(data))
        }

        let sizeFormat = fourStreams ? 1 : 0
        let packed = type | (sizeFormat << 2) | (data.count << 4) | (payload.count << 14)
        out.append(UInt8(packed & 0xFF))
        out.append(UInt8((packed >> 8) & 0xFF))
        out.append(UInt8((packed >> 16) & 0xFF))
        out.append(contentsOf: payload)
    }

    // MARK: - Modelo Huffman para Testes

    private struct TestHuffmanModel {
        let weights: [Int]  // tamanho 256 (0..maxSym)
        let maxSym: Int
        let maxBits: Int
        let codes: [Int]
        let lengths: [Int]

        init(data: [UInt8]) {
            var present = [Bool](repeating: false, count: 256)
            var maxS = 0
            for b in data {
                present[Int(b)] = true
                maxS = max(maxS, Int(b))
            }
            // Garante pelo menos 2 símbolos ativos
            if present.filter({ $0 }).count < 2 {
                let alt = maxS == 0 ? 1 : 0
                present[alt] = true
                maxS = max(maxS, alt)
            }
            let active = (0...maxS).filter { present[$0] }
            // Atribui pesos iguais / potências de 2 para soma exata de potência de 2
            var bitsNeeded = 0
            while (1 << bitsNeeded) < active.count { bitsNeeded += 1 }
            let target = 1 << bitsNeeded
            var w = [Int](repeating: 0, count: maxS + 1)
            for sym in active { w[sym] = 1 }  // cada um contribui 2^(1-1) = 1
            var sum = active.count
            while sum < target {
                var bumped = false
                for s in active {
                    let contrib = 1 << (w[s] - 1)
                    if sum + contrib <= target {
                        w[s] += 1
                        sum += contrib
                        bumped = true
                        break
                    }
                }
                if !bumped { break }
            }

            let mb = max(1, bitsNeeded)
            var rankCounts = [Int](repeating: 0, count: mb + 1)
            for weight in w where weight > 0 { rankCounts[weight] += 1 }

            var rankCode = [Int](repeating: 0, count: mb + 1)
            var nextStart = 0
            for weight in 1...mb {
                rankCode[weight] = nextStart >> (weight - 1)
                nextStart += rankCounts[weight] << (weight - 1)
            }

            var c = [Int](repeating: 0, count: 256)
            var l = [Int](repeating: 0, count: 256)
            for sym in 0...maxS where w[sym] > 0 {
                let weight = w[sym]
                l[sym] = mb + 1 - weight
                c[sym] = rankCode[weight]
                rankCode[weight] += 1
            }

            self.weights = w
            self.maxSym = maxS
            self.maxBits = mb
            self.codes = c
            self.lengths = l
        }

        func encodeHeaderDirectWeights() -> [UInt8] {
            let n = maxSym  // exclui último símbolo (deduzido)
            var out: [UInt8] = [UInt8(127 + n)]
            var i = 0
            while i < n {
                let hi = UInt8(weights[i])
                let lo = i + 1 < n ? UInt8(weights[i + 1]) : 0
                out.append((hi << 4) | lo)
                i += 2
            }
            return out
        }

        func encodeHeaderFSEWeights() -> [UInt8] {
            let partial = Array(weights[0..<maxSym])
            // Monta tabela FSE simples de log 5 sobre pesos 0..12
            var activeWeights = Set(partial)
            activeWeights.insert(0)
            activeWeights.insert(1)
            let syms = Array(activeWeights).sorted()
            var counts = [Int](repeating: 0, count: 13)
            let tableSize = 32
            let base = tableSize / syms.count
            var rem = tableSize - base * syms.count
            for s in syms {
                counts[s] = base + (rem > 0 ? 1 : 0)
                if rem > 0 { rem -= 1 }
            }
            let fseModel = TestFSEModel(counts: counts, accuracyLog: 5)
            var header = fseModel.encodeHeader()

            // Codifica `partial` com 2 estados FSE intercalados
            let bits = encodeTwoStateFSE(partial, model: fseModel)
            header.append(contentsOf: bits)
            return [UInt8(header.count)] + header
        }

        func encodeStream(_ data: [UInt8]) -> [UInt8] {
            var writer = ReverseBitWriter()
            for b in data {
                let sym = Int(b)
                writer.appendMSB(codes[sym], count: lengths[sym])
            }
            return writer.finish()
        }
    }

    // MARK: - Modelo FSE para Testes

    private static let predefinedLLCounts = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ]
    private static let predefinedMLCounts = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1,
    ]
    private static let predefinedOFCounts = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ]

    private static func modeBits(_ mode: FSEModeSpec) -> UInt8 {
        switch mode {
        case .predefined: 0
        case .rle: 1
        case .custom: 2
        case .repeatPrevious: 3
        }
    }

    private static func resolveFSEModel(
        _ spec: FSEModeSpec,
        predefinedCounts: [Int],
        predefinedLog: Int,
        prev: inout TestFSEModel?,
        to out: inout [UInt8]
    ) -> TestFSEModel {
        let model: TestFSEModel
        switch spec {
        case .predefined:
            model = TestFSEModel(counts: predefinedCounts, accuracyLog: predefinedLog)
        case .rle(let sym):
            out.append(sym)
            model = TestFSEModel(rleSymbol: sym)
        case .custom(let counts, let log):
            model = TestFSEModel(counts: counts, accuracyLog: log)
            out.append(contentsOf: model.encodeHeader())
        case .repeatPrevious:
            model = prev!
        }
        prev = model
        return model
    }

    private struct TestFSEModel {
        let accuracyLog: Int
        let counts: [Int]
        let isRLE: Bool
        let rleSym: UInt8
        let symbols: [UInt8]
        let nbBits: [Int]
        let newStateBases: [Int]

        init(rleSymbol: UInt8) {
            self.accuracyLog = 0
            self.counts = []
            self.isRLE = true
            self.rleSym = rleSymbol
            self.symbols = [rleSymbol]
            self.nbBits = [0]
            self.newStateBases = [0]
        }

        init(counts: [Int], accuracyLog: Int) {
            self.accuracyLog = accuracyLog
            self.counts = counts
            self.isRLE = false
            self.rleSym = 0

            let tableSize = 1 << accuracyLog
            var syms = [UInt8](repeating: 0, count: tableSize)
            var next = [Int](repeating: 0, count: counts.count)
            var high = tableSize
            for (s, c) in counts.enumerated() {
                if c == -1 {
                    high -= 1
                    syms[high] = UInt8(s)
                    next[s] = 1
                } else {
                    next[s] = c
                }
            }
            var pos = 0
            let step = (tableSize >> 1) + (tableSize >> 3) + 3
            let mask = tableSize - 1
            for (s, c) in counts.enumerated() where c > 0 {
                for _ in 0..<c {
                    syms[pos] = UInt8(s)
                    repeat { pos = (pos + step) & mask } while pos >= high
                }
            }

            var bits = [Int](repeating: 0, count: tableSize)
            var bases = [Int](repeating: 0, count: tableSize)
            for i in 0..<tableSize {
                let s = Int(syms[i])
                let ns = next[s]
                next[s] += 1
                let hb = Int.bitWidth - 1 - ns.leadingZeroBitCount
                let b = accuracyLog - hb
                bits[i] = b
                bases[i] = (ns << b) - tableSize
            }
            self.symbols = syms
            self.nbBits = bits
            self.newStateBases = bases
        }

        func firstState(for symbol: UInt8) -> Int {
            symbols.firstIndex(of: symbol)!
        }

        func transition(emitting symbol: UInt8, toTargetState target: Int) -> (
            prevState: Int, bits: Int, bitCount: Int
        ) {
            if isRLE { return (0, 0, 0) }
            for state in 0..<symbols.count where symbols[state] == symbol {
                let base = newStateBases[state]
                let n = nbBits[state]
                let span = 1 << n
                if target >= base && target < base + span {
                    return (state, target - base, n)
                }
            }
            fatalError("transição FSE impossível para símbolo \(symbol) -> \(target)")
        }

        func encodeHeader() -> [UInt8] {
            var fw = ForwardBitWriter()
            fw.write(accuracyLog - 5, count: 4)
            let tableSize = 1 << accuracyLog
            var remaining = tableSize + 1
            var threshold = tableSize
            var nb = accuracyLog + 1
            var i = 0
            var prevZero = false

            while remaining > 1 && i < counts.count {
                if prevZero {
                    var zeros = 0
                    while i < counts.count && counts[i] == 0 {
                        zeros += 1
                        i += 1
                    }
                    var remZ = zeros
                    while remZ >= 3 {
                        fw.write(3, count: 2)
                        remZ -= 3
                    }
                    fw.write(remZ, count: 2)
                    if i >= counts.count { break }
                }
                let prob = counts[i]
                let countVal = prob + 1
                let maxVal = 2 * threshold - 1 - remaining
                if countVal < maxVal {
                    fw.write(countVal, count: nb - 1)
                } else if countVal < threshold {
                    fw.write(countVal, count: nb)
                } else {
                    fw.write(countVal + maxVal, count: nb)
                }
                remaining -= prob >= 0 ? prob : 1
                i += 1
                prevZero = (prob == 0)
                while remaining < threshold {
                    nb -= 1
                    threshold >>= 1
                }
            }
            return fw.finish()
        }
    }

    private static func encodeTwoStateFSE(_ weights: [Int], model: TestFSEModel) -> [UInt8] {
        // Codifica `weights` de trás para frente alternando state1 (pares) e state2 (ímpares).
        let n = weights.count
        var s1 = model.firstState(for: UInt8(weights[n - 1]))
        var s2: Int
        var startIdx: Int
        var nextIsS1: Bool
        var steps: [(bits: Int, count: Int)] = []

        if n % 2 == 1 {
            s2 = model.firstState(for: UInt8(weights[n - 2]))
            let tr = model.transition(emitting: UInt8(weights[n - 3]), toTargetState: s1)
            s1 = tr.prevState
            steps.append((tr.bits, tr.bitCount))
            startIdx = n - 4
            nextIsS1 = false
        } else {
            s2 = model.firstState(for: UInt8(weights[n - 1]))
            s1 = model.firstState(for: UInt8(weights[n - 2]))
            startIdx = n - 3
            nextIsS1 = false
        }

        if startIdx >= 0 {
            for i in stride(from: startIdx, through: 0, by: -1) {
                let w = UInt8(weights[i])
                if nextIsS1 {
                    let tr = model.transition(emitting: w, toTargetState: s1)
                    s1 = tr.prevState
                    steps.append((tr.bits, tr.bitCount))
                } else {
                    let tr = model.transition(emitting: w, toTargetState: s2)
                    s2 = tr.prevState
                    steps.append((tr.bits, tr.bitCount))
                }
                nextIsS1.toggle()
            }
        }

        var rw = ReverseBitWriter()
        rw.appendMSB(s1, count: model.accuracyLog)
        rw.appendMSB(s2, count: model.accuracyLog)
        for step in steps.reversed() {
            rw.appendMSB(step.bits, count: step.count)
        }
        return rw.finish()
    }

    private static func encodeSequencesBitstream(
        _ sequences: [Sequence],
        llModel: TestFSEModel,
        ofModel: TestFSEModel,
        mlModel: TestFSEModel
    ) -> [UInt8] {
        let llBases = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
            16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
            8192, 16_384, 32_768, 65_536,
        ]
        let llBits = [
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
            13, 14, 15, 16,
        ]
        let mlBases = [
            3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
            19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
            35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
            4099, 8195, 16_387, 32_771, 65_539,
        ]
        let mlBits = [
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
            12, 13, 14, 15, 16,
        ]

        func findCode(_ val: Int, bases: [Int]) -> Int {
            for i in stride(from: bases.count - 1, through: 0, by: -1) where val >= bases[i] {
                return i
            }
            return 0
        }

        struct EncodedSeq {
            let llCode: Int
            let llExtra: Int
            let llExtraBits: Int
            let mlCode: Int
            let mlExtra: Int
            let mlExtraBits: Int
            let ofCode: Int
            let ofExtra: Int
        }

        let encoded: [EncodedSeq] = sequences.map { s in
            let llC = findCode(s.literalLength, bases: llBases)
            let mlC = findCode(s.matchLength, bases: mlBases)
            let ofC = Int.bitWidth - 1 - s.offsetValue.leadingZeroBitCount
            return EncodedSeq(
                llCode: llC,
                llExtra: s.literalLength - llBases[llC],
                llExtraBits: llBits[llC],
                mlCode: mlC,
                mlExtra: s.matchLength - mlBases[mlC],
                mlExtraBits: mlBits[mlC],
                ofCode: ofC,
                ofExtra: s.offsetValue - (1 << ofC)
            )
        }

        let last = encoded.last!
        var llState = llModel.firstState(for: UInt8(last.llCode))
        var ofState = ofModel.firstState(for: UInt8(last.ofCode))
        var mlState = mlModel.firstState(for: UInt8(last.mlCode))

        var transitions: [(llBits: Int, llCount: Int, mlBits: Int, mlCount: Int, ofBits: Int, ofCount: Int)] =
            []
        if encoded.count > 1 {
            for i in stride(from: encoded.count - 2, through: 0, by: -1) {
                let s = encoded[i]
                let trLL = llModel.transition(emitting: UInt8(s.llCode), toTargetState: llState)
                let trML = mlModel.transition(emitting: UInt8(s.mlCode), toTargetState: mlState)
                let trOF = ofModel.transition(emitting: UInt8(s.ofCode), toTargetState: ofState)
                llState = trLL.prevState
                mlState = trML.prevState
                ofState = trOF.prevState
                transitions.append(
                    (trLL.bits, trLL.bitCount, trML.bits, trML.bitCount, trOF.bits, trOF.bitCount))
            }
        }
        transitions.reverse()

        var rw = ReverseBitWriter()
        rw.appendMSB(llState, count: llModel.accuracyLog)
        rw.appendMSB(ofState, count: ofModel.accuracyLog)
        rw.appendMSB(mlState, count: mlModel.accuracyLog)

        for i in 0..<encoded.count {
            let s = encoded[i]
            rw.appendMSB(s.ofExtra, count: s.ofCode)
            rw.appendMSB(s.mlExtra, count: s.mlExtraBits)
            rw.appendMSB(s.llExtra, count: s.llExtraBits)
            if i < transitions.count {
                let tr = transitions[i]
                rw.appendMSB(tr.llBits, count: tr.llCount)
                rw.appendMSB(tr.mlBits, count: tr.mlCount)
                rw.appendMSB(tr.ofBits, count: tr.ofCount)
            }
        }
        return rw.finish()
    }

    // MARK: - BitWriters & XXH64

    private struct ForwardBitWriter {
        private var bytes: [UInt8] = []
        private var buf: UInt64 = 0
        private var count = 0

        mutating func write(_ value: Int, count bits: Int) {
            buf |= UInt64(value) << UInt64(count)
            count += bits
            while count >= 8 {
                bytes.append(UInt8(buf & 0xFF))
                buf >>= 8
                count -= 8
            }
        }

        mutating func finish() -> [UInt8] {
            if count > 0 { bytes.append(UInt8(buf & 0xFF)) }
            return bytes
        }
    }

    private struct ReverseBitWriter {
        private var bits: [UInt8] = []  // em ordem de leitura pelo decodificador (MSB->LSB)

        mutating func appendMSB(_ value: Int, count: Int) {
            if count == 0 { return }
            for i in stride(from: count - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> i) & 1))
            }
        }

        func finish() -> [UInt8] {
            let totalBits = bits.count + 1
            let byteCount = (totalBits + 7) / 8
            var bytes = [UInt8](repeating: 0, count: byteCount)
            // Bit `k` (k = bits.count é a sentinela) vai para posição LE `k`.
            let sentPos = bits.count
            bytes[sentPos >> 3] |= UInt8(1 << (sentPos & 7))
            for (idx, bit) in bits.enumerated() where bit != 0 {
                let pos = bits.count - 1 - idx
                bytes[pos >> 3] |= UInt8(1 << (pos & 7))
            }
            return bytes
        }
    }

    private static func appendU16LE(_ v: UInt16, to out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8(v >> 8))
    }

    private static func appendU32LE(_ v: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    }

    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C, 0x01]
        let len = UInt16(data.count)
        let nlen = ~len
        appendU16LE(len, to: &out)
        appendU16LE(nlen, to: &out)
        out.append(contentsOf: data)
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        for b in data {
            s1 = (s1 + UInt32(b)) % 65_521
            s2 = (s2 + s1) % 65_521
        }
        let adler = (s2 << 16) | s1
        out.append(UInt8((adler >> 24) & 0xFF))
        out.append(UInt8((adler >> 16) & 0xFF))
        out.append(UInt8((adler >> 8) & 0xFF))
        out.append(UInt8(adler & 0xFF))
        return out
    }

    private static func xxh64(_ bytes: [UInt8]) -> UInt64 {
        let p1: UInt64 = 0x9E37_79B1_85EB_CA87
        let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
        let p3: UInt64 = 0x1656_67B1_9E37_79F9
        let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
        let p5: UInt64 = 0x27D4_EB2F_1656_67C5
        func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
        func round(_ a: UInt64, _ i: UInt64) -> UInt64 { rotl(a &+ (i &* p2), 31) &* p1 }
        func read64(_ i: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(bytes[i + k]) << UInt64(8 * k) }
            return v
        }
        func read32(_ i: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<4 { v |= UInt64(bytes[i + k]) << UInt64(8 * k) }
            return v
        }

        var pos = 0
        var h: UInt64
        if bytes.count >= 32 {
            var v1 = p1 &+ p2
            var v2 = p2
            var v3: UInt64 = 0
            var v4 = 0 &- p1
            while pos <= bytes.count - 32 {
                v1 = round(v1, read64(pos))
                v2 = round(v2, read64(pos + 8))
                v3 = round(v3, read64(pos + 16))
                v4 = round(v4, read64(pos + 24))
                pos += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            for v in [v1, v2, v3, v4] {
                h = ((h ^ round(0, v)) &* p1) &+ p4
            }
        } else {
            h = p5
        }
        h &+= UInt64(bytes.count)
        while pos + 8 <= bytes.count {
            h = rotl(h ^ round(0, read64(pos)), 27) &* p1 &+ p4
            pos += 8
        }
        if pos + 4 <= bytes.count {
            h = rotl(h ^ (read32(pos) &* p1), 23) &* p2 &+ p3
            pos += 4
        }
        while pos < bytes.count {
            h = rotl(h ^ (UInt64(bytes[pos]) &* p5), 11) &* p1
            pos += 1
        }
        h ^= h >> 33
        h &*= p2
        h ^= h >> 29
        h &*= p3
        h ^= h >> 32
        return h
    }
}
