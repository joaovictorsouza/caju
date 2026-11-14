import CajuAssetsCore
import CajuTesting
import Testing

private let ktx2Magic: [UInt8] = [
    0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A,
]

private struct LevelSpec {
    var data: [UInt8]
    var uncompressedByteLength: UInt64?
}

private struct SyntheticOptions {
    var vkFormat: UInt32 = 37  // VK_FORMAT_R8G8B8A8_UNORM
    var typeSize: UInt32 = 1
    var pixelWidth: UInt32 = 4
    var pixelHeight: UInt32 = 4
    var pixelDepth: UInt32 = 0
    var layerCount: UInt32 = 0
    var faceCount: UInt32 = 1
    var levelCount: UInt32 = 3
    var scheme: UInt32 = 0
    var colorModel: UInt8 = 1  // RGBSDA
    var transferFunction: UInt8 = 2  // sRGB
    var dfdFlags: UInt8 = 0
    var kvdPairs: [(String, [UInt8])] = []
    var sgdBytes: [UInt8] = []
    var levels: [LevelSpec] = [
        LevelSpec(data: [UInt8](repeating: 0xAA, count: 64)),
        LevelSpec(data: [UInt8](repeating: 0xBB, count: 16)),
        LevelSpec(data: [UInt8](repeating: 0xCC, count: 4)),
    ]
    var levelAlignTo4WhenCompressed: Bool = true
}

private func appendU32LE(_ value: UInt32, to buffer: inout [UInt8]) {
    buffer.append(UInt8(truncatingIfNeeded: value))
    buffer.append(UInt8(truncatingIfNeeded: value >> 8))
    buffer.append(UInt8(truncatingIfNeeded: value >> 16))
    buffer.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func writeU32LE(_ value: UInt32, at offset: Int, in buffer: inout [UInt8]) {
    buffer[offset] = UInt8(truncatingIfNeeded: value)
    buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

private func writeU64LE(_ value: UInt64, at offset: Int, in buffer: inout [UInt8]) {
    for i in 0..<8 {
        buffer[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i))
    }
}

private func readU32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    var result: UInt32 = 0
    for i in 0..<4 {
        result |= UInt32(bytes[offset + i]) << UInt32(8 * i)
    }
    return result
}

private func buildDFD(
    colorModel: UInt8,
    transferFunction: UInt8,
    flags: UInt8,
    sampleCount: Int = 1
) -> [UInt8] {
    let blockSize = UInt32(24 + 16 * sampleCount)
    let totalSize = 4 + blockSize
    var dfd: [UInt8] = []
    dfd.reserveCapacity(Int(totalSize))
    appendU32LE(totalSize, to: &dfd)
    appendU32LE(0, to: &dfd)
    appendU32LE(2 | (blockSize << 16), to: &dfd)
    dfd.append(colorModel)
    dfd.append(1)
    dfd.append(transferFunction)
    dfd.append(flags)
    for _ in 0..<12 { dfd.append(0) }
    for _ in 0..<(16 * sampleCount) { dfd.append(0) }
    return dfd
}

private func buildKVD(_ pairs: [(String, [UInt8])]) -> [UInt8] {
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

private func padTo(_ alignment: Int, buffer: inout [UInt8]) {
    let rem = buffer.count % alignment
    if rem != 0 {
        for _ in 0..<(alignment - rem) { buffer.append(0) }
    }
}

private func buildKTX2(_ options: SyntheticOptions = SyntheticOptions()) -> [UInt8] {
    let actualLevels = options.levelCount == 0 ? 1 : Int(options.levelCount)
    precondition(options.levels.count == actualLevels)

    var bytes: [UInt8] = []
    bytes.append(contentsOf: ktx2Magic)
    appendU32LE(options.vkFormat, to: &bytes)
    appendU32LE(options.typeSize, to: &bytes)
    appendU32LE(options.pixelWidth, to: &bytes)
    appendU32LE(options.pixelHeight, to: &bytes)
    appendU32LE(options.pixelDepth, to: &bytes)
    appendU32LE(options.layerCount, to: &bytes)
    appendU32LE(options.faceCount, to: &bytes)
    appendU32LE(options.levelCount, to: &bytes)
    appendU32LE(options.scheme, to: &bytes)

    for _ in 0..<32 { bytes.append(0) }
    for _ in 0..<(actualLevels * 24) { bytes.append(0) }

    padTo(4, buffer: &bytes)
    let dfdOffset = UInt32(bytes.count)
    let dfd = buildDFD(
        colorModel: options.colorModel,
        transferFunction: options.transferFunction,
        flags: options.dfdFlags
    )
    bytes.append(contentsOf: dfd)
    writeU32LE(dfdOffset, at: 48, in: &bytes)
    writeU32LE(UInt32(dfd.count), at: 52, in: &bytes)

    if !options.kvdPairs.isEmpty {
        padTo(4, buffer: &bytes)
        let kvdOffset = UInt32(bytes.count)
        let kvd = buildKVD(options.kvdPairs)
        bytes.append(contentsOf: kvd)
        writeU32LE(kvdOffset, at: 56, in: &bytes)
        writeU32LE(UInt32(kvd.count), at: 60, in: &bytes)
    }

    if !options.sgdBytes.isEmpty {
        padTo(8, buffer: &bytes)
        let sgdOffset = UInt64(bytes.count)
        bytes.append(contentsOf: options.sgdBytes)
        writeU64LE(sgdOffset, at: 64, in: &bytes)
        writeU64LE(UInt64(options.sgdBytes.count), at: 72, in: &bytes)
    }

    // Níveis no arquivo do menor para o maior (nível 0 por último)
    for i in stride(from: actualLevels - 1, through: 0, by: -1) {
        if options.scheme == 0 || options.levelAlignTo4WhenCompressed {
            padTo(4, buffer: &bytes)
        }
        let levelOffset = UInt64(bytes.count)
        let spec = options.levels[i]
        bytes.append(contentsOf: spec.data)
        let entryBase = 80 + i * 24
        let len = UInt64(spec.data.count)
        let uLen = spec.uncompressedByteLength ?? len
        writeU64LE(levelOffset, at: entryBase, in: &bytes)
        writeU64LE(len, at: entryBase + 8, in: &bytes)
        writeU64LE(uLen, at: entryBase + 16, in: &bytes)
    }

    return bytes
}

@Suite("KTX2")
struct KTX2Tests {
    // MARK: - Casos válidos

    @Test func validUncompressed2DWithMipmapsAndKVD() throws {
        var opts = SyntheticOptions()
        opts.kvdPairs = [
            ("KTXwriter", Array("CajuTest 1.0".utf8)),
            ("unicode.chave_ção", [0x00, 0x01, 0x02, 0xFF]),
            ("empty.val", []),
        ]
        let bytes = buildKTX2(opts)
        let container = try KTX2Container.parse(bytes)

        #expect(container.vkFormat == 37)
        #expect(container.typeSize == 1)
        #expect(container.pixelWidth == 4)
        #expect(container.pixelHeight == 4)
        #expect(container.pixelDepth == 0)
        #expect(container.layerCount == 0)
        #expect(container.faceCount == 1)
        #expect(container.levelCount == 3)
        #expect(container.supercompressionScheme == .none)
        #expect(container.colorModel == 1)
        #expect(container.transferFunction == 2)
        #expect(container.dfdFlags == 0)
        #expect(container.levels.count == 3)
        #expect(container.levels[0].byteOffset > container.levels[1].byteOffset)
        #expect(container.levels[1].byteOffset > container.levels[2].byteOffset)

        let r0 = try container.levelRange(0)
        #expect(Array(bytes[r0]) == [UInt8](repeating: 0xAA, count: 64))
        let r2 = try container.levelRange(2)
        #expect(Array(bytes[r2]) == [UInt8](repeating: 0xCC, count: 4))

        #expect(container.keyValueData.count == 3)
        #expect(container.keyValueData[0].key == "KTXwriter")
        #expect(container.keyValueData[0].value == Array("CajuTest 1.0".utf8))
        #expect(container.keyValueData[1].key == "unicode.chave_ção")
        #expect(container.keyValueData[1].value == [0x00, 0x01, 0x02, 0xFF])
        #expect(container.keyValueData[2].key == "empty.val")
        #expect(container.keyValueData[2].value.isEmpty)
    }

    @Test func validLevelCountZeroGeneratesMips() throws {
        var opts = SyntheticOptions()
        opts.pixelWidth = 8
        opts.pixelHeight = 8
        opts.levelCount = 0
        opts.levels = [LevelSpec(data: [UInt8](repeating: 0x11, count: 256))]
        let bytes = buildKTX2(opts)

        let container = try KTX2Container.parse(bytes)
        #expect(container.levelCount == 0)
        #expect(container.levels.count == 1)
        #expect(try container.levelRange(0).count == 256)
    }

    @Test func validCubemapAnd3DAnd1D() throws {
        var cube = SyntheticOptions()
        cube.pixelWidth = 4
        cube.pixelHeight = 4
        cube.pixelDepth = 0
        cube.faceCount = 6
        cube.levelCount = 1
        cube.levels = [LevelSpec(data: [UInt8](repeating: 0x55, count: 384))]
        let cubeContainer = try KTX2Container.parse(buildKTX2(cube))
        #expect(cubeContainer.faceCount == 6)

        var tex1D = SyntheticOptions()
        tex1D.pixelWidth = 8
        tex1D.pixelHeight = 0
        tex1D.pixelDepth = 0
        tex1D.levelCount = 4
        tex1D.levels = [
            LevelSpec(data: [UInt8](repeating: 1, count: 32)),
            LevelSpec(data: [UInt8](repeating: 2, count: 16)),
            LevelSpec(data: [UInt8](repeating: 3, count: 8)),
            LevelSpec(data: [UInt8](repeating: 4, count: 4)),
        ]
        let c1D = try KTX2Container.parse(buildKTX2(tex1D))
        #expect(c1D.pixelHeight == 0)
        #expect(c1D.levels.count == 4)

        var tex3D = SyntheticOptions()
        tex3D.pixelWidth = 2
        tex3D.pixelHeight = 4
        tex3D.pixelDepth = 8
        tex3D.levelCount = 4
        tex3D.levels = [
            LevelSpec(data: [UInt8](repeating: 1, count: 64)),
            LevelSpec(data: [UInt8](repeating: 2, count: 16)),
            LevelSpec(data: [UInt8](repeating: 3, count: 8)),
            LevelSpec(data: [UInt8](repeating: 4, count: 4)),
        ]
        let c3D = try KTX2Container.parse(buildKTX2(tex3D))
        #expect(c3D.pixelDepth == 8)
    }

    @Test func validBasisLZAndUASTCAndZstdAndZlib() throws {
        var basis = SyntheticOptions()
        basis.vkFormat = 0
        basis.scheme = 1
        basis.colorModel = 163
        basis.dfdFlags = 1
        basis.levelCount = 1
        basis.sgdBytes = [1, 2, 3, 4, 5]
        basis.levelAlignTo4WhenCompressed = false
        basis.levels = [LevelSpec(data: [0x10, 0x20, 0x30], uncompressedByteLength: 0)]
        let basisContainer = try KTX2Container.parse(buildKTX2(basis))
        #expect(basisContainer.supercompressionScheme == .basisLZ)
        #expect(basisContainer.colorModel == 163)
        #expect(basisContainer.dfdFlags == 1)

        var uastc = SyntheticOptions()
        uastc.vkFormat = 0
        uastc.scheme = 2
        uastc.colorModel = 166
        uastc.levelCount = 1
        uastc.levelAlignTo4WhenCompressed = false
        uastc.levels = [LevelSpec(data: [0x01, 0x02, 0x03], uncompressedByteLength: 64)]
        let uastcContainer = try KTX2Container.parse(buildKTX2(uastc))
        #expect(uastcContainer.supercompressionScheme == .zstd)
        #expect(uastcContainer.colorModel == 166)

        var zlib = SyntheticOptions()
        zlib.scheme = 3
        zlib.levelCount = 1
        zlib.levels = [LevelSpec(data: [0x78, 0x9C, 0x01], uncompressedByteLength: 32)]
        let zlibContainer = try KTX2Container.parse(buildKTX2(zlib))
        #expect(zlibContainer.supercompressionScheme == .zlib)
    }

    // MARK: - Casos malformados e limites

    @Test func rejectsTruncatedInputs() {
        let valid = buildKTX2()
        for cut in [0, 5, 12, 40, 79, 80, 120, valid.count - 1] {
            #expect(throws: AssetError.self) {
                _ = try KTX2Container.parse(Array(valid[0..<cut]))
            }
        }
    }

    @Test func rejectsBadMagicAndInvalidDimensions() {
        var badMagic = buildKTX2()
        badMagic[0] = 0x00
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(badMagic)
        }

        var zeroWidth = buildKTX2()
        writeU32LE(0, at: 20, in: &zeroWidth)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(zeroWidth)
        }

        var bad3D = buildKTX2()
        writeU32LE(0, at: 24, in: &bad3D)
        writeU32LE(2, at: 28, in: &bad3D)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(bad3D)
        }
    }

    @Test func rejectsInvalidFaceCountAndCubemapGeometry() {
        for badFaces: UInt32 in [0, 2, 5, 7] {
            var bytes = buildKTX2()
            writeU32LE(badFaces, at: 36, in: &bytes)
            #expect(throws: AssetError.self) {
                _ = try KTX2Container.parse(bytes)
            }
        }

        var nonSquare = buildKTX2()
        writeU32LE(8, at: 20, in: &nonSquare)
        writeU32LE(4, at: 24, in: &nonSquare)
        writeU32LE(6, at: 36, in: &nonSquare)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(nonSquare)
        }

        var cube3D = buildKTX2()
        writeU32LE(4, at: 20, in: &cube3D)
        writeU32LE(4, at: 24, in: &cube3D)
        writeU32LE(2, at: 28, in: &cube3D)
        writeU32LE(6, at: 36, in: &cube3D)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(cube3D)
        }
    }

    @Test func rejectsLimitsAndTooManyMipLevels() {
        let valid = buildKTX2()

        let smallInput = AssetLimits(maxInputBytes: valid.count - 1)
        let expectedInputErr = AssetError.limitExceeded(
            context: "ktx2.input",
            limit: valid.count - 1,
            requested: valid.count
        )
        #expect(throws: expectedInputErr) {
            _ = try KTX2Container.parse(valid, limits: smallInput)
        }

        let smallDim = AssetLimits(maxImageDimension: 2)
        #expect(throws: AssetError.limitExceeded(context: "ktx2.pixelWidth", limit: 2, requested: 4)) {
            _ = try KTX2Container.parse(valid, limits: smallDim)
        }

        let smallMips = AssetLimits(maxMipLevels: 2)
        #expect(throws: AssetError.limitExceeded(context: "ktx2.levelCount", limit: 2, requested: 3)) {
            _ = try KTX2Container.parse(valid, limits: smallMips)
        }

        let smallOut = AssetLimits(maxOutputBytes: 64)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(valid, limits: smallOut)
        }

        var hugeMips = valid
        writeU32LE(UInt32.max, at: 40, in: &hugeMips)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(hugeMips)
        }

        var tooManyMips = valid
        writeU32LE(4, at: 40, in: &tooManyMips)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(tooManyMips)
        }

        var opts = SyntheticOptions()
        opts.kvdPairs = [("a", [1]), ("b", [2])]
        let withKVD = buildKTX2(opts)
        let smallElems = AssetLimits(maxElements: 1)
        #expect(throws: AssetError.limitExceeded(context: "ktx2.kvd", limit: 1, requested: 2)) {
            _ = try KTX2Container.parse(withKVD, limits: smallElems)
        }
    }

    @Test func rejectsInvalidSchemeVkFormatAndDFD() {
        var badScheme = buildKTX2()
        writeU32LE(4, at: 44, in: &badScheme)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(badScheme)
        }

        var undefinedNoBasis = SyntheticOptions()
        undefinedNoBasis.vkFormat = 0
        undefinedNoBasis.scheme = 0
        undefinedNoBasis.colorModel = 1
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(buildKTX2(undefinedNoBasis))
        }

        var badColorModel = SyntheticOptions()
        badColorModel.colorModel = 99
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(buildKTX2(badColorModel))
        }

        var badTransfer = SyntheticOptions()
        badTransfer.transferFunction = 42
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(buildKTX2(badTransfer))
        }

        var badFlags = SyntheticOptions()
        badFlags.dfdFlags = 2
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(buildKTX2(badFlags))
        }

        var mismatchLen = SyntheticOptions()
        mismatchLen.levelCount = 1
        mismatchLen.levels = [LevelSpec(data: [UInt8](repeating: 1, count: 16), uncompressedByteLength: 32)]
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(buildKTX2(mismatchLen))
        }

        var sgdWithNone = SyntheticOptions()
        sgdWithNone.levelCount = 1
        sgdWithNone.levels = [LevelSpec(data: [UInt8](repeating: 1, count: 16))]
        sgdWithNone.sgdBytes = [1, 2, 3, 4]
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(buildKTX2(sgdWithNone))
        }
    }

    @Test func rejectsOverlapsBadLevelOrderAlignmentAndOverflow() throws {
        var dfdOverlapHeader = buildKTX2()
        writeU32LE(40, at: 48, in: &dfdOverlapHeader)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(dfdOverlapHeader)
        }

        var swappedOrder = buildKTX2()
        let entry0 = Array(swappedOrder[80..<104])
        let entry1 = Array(swappedOrder[104..<128])
        swappedOrder.replaceSubrange(80..<104, with: entry1)
        swappedOrder.replaceSubrange(104..<128, with: entry0)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(swappedOrder)
        }

        var unalignedLevel = buildKTX2()
        writeU64LE(UInt64(unalignedLevel.count - 63), at: 80, in: &unalignedLevel)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(unalignedLevel)
        }

        var overflowLevel = buildKTX2()
        writeU64LE(UInt64.max - 4, at: 80, in: &overflowLevel)
        writeU64LE(16, at: 88, in: &overflowLevel)
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(overflowLevel)
        }

        let validContainer = try KTX2Container.parse(buildKTX2())
        #expect(throws: AssetError.self) {
            _ = try validContainer.levelRange(-1)
        }
        #expect(throws: AssetError.self) {
            _ = try validContainer.levelRange(3)
        }
    }

    @Test func rejectsMalformedKVD() {
        var opts = SyntheticOptions()
        opts.kvdPairs = [("key", [1, 2, 3])]
        var bytes = buildKTX2(opts)
        let kvdStart = Int(readU32LE(bytes, at: 56))
        bytes[kvdStart + 4 + 3] = UInt8(ascii: "x")
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(bytes)
        }

        var badUTF8 = buildKTX2(opts)
        badUTF8[kvdStart + 4] = 0xFF
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(badUTF8)
        }

        var bomOpts = SyntheticOptions()
        bomOpts.kvdPairs = [("\u{FEFF}key", [1])]
        #expect(throws: AssetError.self) {
            _ = try KTX2Container.parse(buildKTX2(bomOpts))
        }
    }

    // MARK: - Fuzz determinístico

    @Test func fuzzRandomAndMutatedInputsNeverCrash() {
        let fuzzLimits = AssetLimits(
            maxInputBytes: 4096,
            maxOutputBytes: 4096,
            maxImageDimension: 64,
            maxJSONDepth: 16,
            maxElements: 32,
            maxMipLevels: 8
        )

        var basisSeed = SyntheticOptions()
        basisSeed.vkFormat = 0
        basisSeed.scheme = 1
        basisSeed.colorModel = 163
        basisSeed.levelCount = 1
        basisSeed.sgdBytes = [1, 2, 3, 4]
        basisSeed.kvdPairs = [("KTXwriter", Array("fuzz".utf8))]
        basisSeed.levels = [LevelSpec(data: [0x11, 0x22, 0x33], uncompressedByteLength: 0)]

        let seeds: [[UInt8]] = [
            buildKTX2(),
            buildKTX2(basisSeed),
        ]

        // 2000 iterações de entradas aleatórias (com e sem assinatura KTX2)
        CajuFuzz.run(seed: 0x4B54_5832, iterations: 2000) { rng, i in
            let len = Int(rng.nextUInt32() % 512)
            var input = [UInt8](repeating: 0, count: len)
            for idx in 0..<len {
                input[idx] = UInt8(truncatingIfNeeded: rng.nextUInt32())
            }
            if i % 2 == 0, len >= ktx2Magic.count {
                for m in 0..<ktx2Magic.count { input[m] = ktx2Magic[m] }
            }
            do {
                _ = try KTX2Container.parse(input, limits: fuzzLimits)
            } catch {
                _ = error
            }
        }

        // 2000 iterações de mutação (flips de bytes e truncamentos) em entradas válidas
        CajuFuzz.run(seed: 0xBEEF_CAFE, iterations: 2000) { rng, i in
            var mutated = seeds[i % seeds.count]
            let op = rng.nextUInt32() % 3
            if op == 0, !mutated.isEmpty {
                let cut = Int(rng.nextUInt32()) % mutated.count
                mutated = Array(mutated[0..<cut])
            } else if !mutated.isEmpty {
                let flips = 1 + Int(rng.nextUInt32() % 4)
                for _ in 0..<flips {
                    let pos = Int(rng.nextUInt32()) % mutated.count
                    mutated[pos] ^= UInt8(truncatingIfNeeded: (rng.nextUInt32() & 0xFF) | 1)
                }
            }
            do {
                _ = try KTX2Container.parse(mutated, limits: fuzzLimits)
            } catch {
                _ = error
            }
        }
    }
}
