import CajuTesting
import Testing

@testable import CajuAssetsCore

@Suite("PNG/JPEG")
struct ImageTests {
    // MARK: - Inflate

    @Test func inflateStoredSingleAndMultiBlock() throws {
        let payload: [UInt8] = Array("CajuEngine-DEFLATE-Stored-Test".utf8)
        let compressed = TestCodecHelpers.zlibStored(payload, maxBlockSize: 10)
        let out = try Inflate.zlibDecompress(compressed, from: 0, maxOutput: 1024, context: "test")
        #expect(out == payload)
    }

    @Test func inflateEmptyWithZeroMaxOutput() throws {
        let compressed = TestCodecHelpers.zlibStored([], maxBlockSize: 65_535)
        let out = try Inflate.zlibDecompress(compressed, from: 0, maxOutput: 0, context: "test")
        #expect(out.isEmpty)
    }

    @Test func inflateFromNonZeroStartOffset() throws {
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        let compressed = [0xAA, 0xBB, 0xCC] + TestCodecHelpers.zlibStored(payload)
        let out = try Inflate.zlibDecompress(compressed, from: 3, maxOutput: 64, context: "test")
        #expect(out == payload)
    }

    @Test func inflateFixedHuffmanWithRLEOverlap() throws {
        // BFINAL=1, BTYPE=1 (fixed):
        // Literal 'A' (65, 8-bit code 00110000 + 65 = 01110001 -> MSB-first: 0,1,1,1,0,0,0,1)
        // Match length 5 (sym 259, 7-bit code 0000011 -> MSB-first: 0,0,0,0,0,1,1),
        // Distance 1 (5-bit code 00000)
        // EOB (sym 256, 7-bit code 0000000)
        var bw = TestBitWriter()
        bw.writeBits(1, count: 1)  // BFINAL = 1
        bw.writeBits(1, count: 2)  // BTYPE = 1 (fixed)
        bw.writeHuffmanCode(0x30 + 65, length: 8)  // 'A'
        bw.writeHuffmanCode(259 - 256, length: 7)  // length 5
        bw.writeHuffmanCode(0, length: 5)  // dist 1
        bw.writeHuffmanCode(0, length: 7)  // EOB (256)
        let deflateStream = bw.finish()
        let expected: [UInt8] = [65, 65, 65, 65, 65, 65]
        let zlib = TestCodecHelpers.wrapZlib(deflateStream, uncompressed: expected)

        let out = try Inflate.zlibDecompress(zlib, from: 0, maxOutput: 16, context: "fixed")
        #expect(out == expected)
    }

    @Test func inflateDynamicHuffmanWithEmptyDistanceTree() throws {
        // Dynamic block emitting "AB" with only literals and empty distance tree (HDIST=1, dist len=0).
        // Lit/len lengths: 0..64 -> 0, 65('A')->2, 66('B')->2, 256(EOB)->1
        // Wait: 1*2^-1 + 2*2^-2 = 0.5 + 0.5 = 1.0 (complete tree!)
        // HLIT = 257 (0 extra), HDIST = 1 (0 extra)
        // Code length symbols used: 0, 1, 2, 18 (repeat zero 11..138 times)
        // Let's give code length symbols: 0->2, 1->2, 2->2, 18->2 (4 codes of length 2 -> complete!)
        // Code length order: [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        // Up to index 17 (sym 1) => HCLEN = 18 (18 - 4 = 14)
        var bw = TestBitWriter()
        bw.writeBits(1, count: 1)  // BFINAL
        bw.writeBits(2, count: 2)  // BTYPE = 2 (dynamic)
        bw.writeBits(0, count: 5)  // HLIT = 257
        bw.writeBits(0, count: 5)  // HDIST = 1
        bw.writeBits(14, count: 4)  // HCLEN = 18

        // Code lengths in codeLengthOrder:
        // 16:0, 17:0, 18:2, 0:2, 8:0, 7:0, 9:0, 6:0, 10:0, 5:0, 11:0, 4:0, 12:0, 3:0, 13:0, 2:2, 14:0, 1:2
        let clOrderLengths = [0, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2]
        for l in clOrderLengths {
            bw.writeBits(l, count: 3)
        }
        // Canonical codes for {0:2, 1:2, 2:2, 18:2}:
        // sym 0 -> 00 (0), sym 1 -> 01 (1), sym 2 -> 10 (2), sym 18 -> 11 (3)
        // Encode 65 zeros (11 + 54 = 65 -> sym 18 with extra 54)
        bw.writeHuffmanCode(3, length: 2)
        bw.writeBits(54, count: 7)
        // sym 65 -> len 2
        bw.writeHuffmanCode(2, length: 2)
        // sym 66 -> len 2
        bw.writeHuffmanCode(2, length: 2)
        // 189 zeros (sym 67..255): 138 + 51 -> two sym 18: (11+127=138) + (11+40=51)
        bw.writeHuffmanCode(3, length: 2)
        bw.writeBits(127, count: 7)
        bw.writeHuffmanCode(3, length: 2)
        bw.writeBits(40, count: 7)
        // sym 256 -> len 1
        bw.writeHuffmanCode(1, length: 2)
        // dist 0 -> len 0
        bw.writeHuffmanCode(0, length: 2)

        // Canonical lit/len codes: len 1: {256 -> 0}, len 2: {65 -> 10 (2), 66 -> 11 (3)}
        bw.writeHuffmanCode(2, length: 2)  // 'A'
        bw.writeHuffmanCode(3, length: 2)  // 'B'
        bw.writeHuffmanCode(0, length: 1)  // EOB

        let expected: [UInt8] = [65, 66]
        let zlib = TestCodecHelpers.wrapZlib(bw.finish(), uncompressed: expected)
        let out = try Inflate.zlibDecompress(zlib, from: 0, maxOutput: 16, context: "dynamic")
        #expect(out == expected)
    }

    @Test func inflateErrorsAndLimits() {
        // FDICT -> unsupported
        let fdictBytes: [UInt8] = [0x78, 0xBB, 0x00, 0x00, 0x00, 0x01]
        #expect(
            throws: AssetError.unsupported(
                context: "test",
                reason: "dicionário zlib predefinido (FDICT)"
            )
        ) {
            _ = try Inflate.zlibDecompress(fdictBytes, from: 0, maxOutput: 64, context: "test")
        }

        // Bad fcheck
        let badFcheck: [UInt8] = [0x78, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xFF]
        #expect {
            _ = try Inflate.zlibDecompress(badFcheck, from: 0, maxOutput: 64, context: "test")
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Zip bomb: stored block larger than maxOutput
        let big = [UInt8](repeating: 0x42, count: 100)
        let zlibBig = TestCodecHelpers.zlibStored(big)
        #expect(throws: AssetError.limitExceeded(context: "bomb", limit: 32, requested: 100)) {
            _ = try Inflate.zlibDecompress(zlibBig, from: 0, maxOutput: 32, context: "bomb")
        }

        // Compressed RLE exceeding maxOutput
        var bw = TestBitWriter()
        bw.writeBits(1, count: 1)
        bw.writeBits(1, count: 2)
        bw.writeHuffmanCode(0x30 + 65, length: 8)
        bw.writeHuffmanCode(259 - 256, length: 7)  // +5 bytes (total 6)
        bw.writeHuffmanCode(0, length: 5)
        bw.writeHuffmanCode(0, length: 7)
        let rleZlib = TestCodecHelpers.wrapZlib(bw.finish(), uncompressed: [UInt8](repeating: 65, count: 6))
        #expect(throws: AssetError.limitExceeded(context: "rle", limit: 4, requested: 6)) {
            _ = try Inflate.zlibDecompress(rleZlib, from: 0, maxOutput: 4, context: "rle")
        }

        // Distance > output.count
        var badDist = TestBitWriter()
        badDist.writeBits(1, count: 1)
        badDist.writeBits(1, count: 2)
        badDist.writeHuffmanCode(0x30 + 65, length: 8)  // 1 byte out
        badDist.writeHuffmanCode(257 - 256, length: 7)  // length 3
        badDist.writeHuffmanCode(1, length: 5)  // dist 2 (> 1!)
        badDist.writeHuffmanCode(0, length: 7)
        let badDistZlib = TestCodecHelpers.wrapZlib(badDist.finish(), uncompressed: [65])
        #expect {
            _ = try Inflate.zlibDecompress(badDistZlib, from: 0, maxOutput: 64, context: "dist")
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Bad Adler-32
        var badAdler = TestCodecHelpers.zlibStored([1, 2, 3])
        badAdler[badAdler.count - 1] ^= 0x01
        #expect {
            _ = try Inflate.zlibDecompress(badAdler, from: 0, maxOutput: 64, context: "adler")
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Under-subscribed dynamic code-length tree (all zeros except 1 symbol of length 1)
        var underBW = TestBitWriter()
        underBW.writeBits(1, count: 1)
        underBW.writeBits(2, count: 2)
        underBW.writeBits(0, count: 5)
        underBW.writeBits(0, count: 5)
        underBW.writeBits(0, count: 4)  // HCLEN = 4
        underBW.writeBits(1, count: 3)  // only 1 code length = 1 -> under-subscribed
        underBW.writeBits(0, count: 3)
        underBW.writeBits(0, count: 3)
        underBW.writeBits(0, count: 3)
        let underZlib = TestCodecHelpers.wrapZlib(underBW.finish(), uncompressed: [])
        #expect {
            _ = try Inflate.zlibDecompress(underZlib, from: 0, maxOutput: 64, context: "under")
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Over-subscribed dynamic code-length tree (3 symbols of length 1)
        var overBW = TestBitWriter()
        overBW.writeBits(1, count: 1)
        overBW.writeBits(2, count: 2)
        overBW.writeBits(0, count: 5)
        overBW.writeBits(0, count: 5)
        overBW.writeBits(0, count: 4)  // HCLEN = 4
        overBW.writeBits(1, count: 3)
        overBW.writeBits(1, count: 3)
        overBW.writeBits(1, count: 3)
        overBW.writeBits(0, count: 3)
        let overZlib = TestCodecHelpers.wrapZlib(overBW.finish(), uncompressed: [])
        #expect {
            _ = try Inflate.zlibDecompress(overZlib, from: 0, maxOutput: 64, context: "over")
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }
    }

    // MARK: - PNG Valid Cases

    @Test func pngReadInfoWithoutInflatingIDAT() throws {
        // IHDR only (no IDAT/IEND): readInfo should succeed without inflate.
        let ihdr = TestCodecHelpers.makeIHDRData(
            width: 32,
            height: 16,
            bitDepth: 8,
            colorType: 6,
            interlace: 1
        )
        let png = TestCodecHelpers.pngSignature + TestCodecHelpers.makePNGChunk("IHDR", data: ihdr)
        let info = try PNGDecoder.readInfo(png)
        #expect(info == PNGInfo(width: 32, height: 16, bitDepth: 8, colorType: .rgba, isInterlaced: true))
    }

    @Test func pngGrayscaleAllBitDepthsAndTRNS() throws {
        // 1-bit grayscale 4x1: pixels [0, 1, 0, 1] -> byte 0b0101_0000 = 0x50
        let raw1: [UInt8] = [0, 0x50]
        let png1 = TestCodecHelpers.buildPNG(width: 4, height: 1, bitDepth: 1, colorType: 0, raw: raw1)
        let img1 = try PNGDecoder.decode(png1)
        #expect(
            img1.pixels == [
                0, 0, 0, 255,
                255, 255, 255, 255,
                0, 0, 0, 255,
                255, 255, 255, 255,
            ])

        // 2-bit grayscale 4x1: samples [0, 1, 2, 3] -> byte 0b00_01_10_11 = 0x1B
        let raw2: [UInt8] = [0, 0x1B]
        let png2 = TestCodecHelpers.buildPNG(width: 4, height: 1, bitDepth: 2, colorType: 0, raw: raw2)
        let img2 = try PNGDecoder.decode(png2)
        #expect(
            img2.pixels == [
                0, 0, 0, 255,
                85, 85, 85, 255,
                170, 170, 170, 255,
                255, 255, 255, 255,
            ])

        // 4-bit grayscale 2x1 with tRNS=15: samples [1, 15] -> 0x1F
        let raw4: [UInt8] = [0, 0x1F]
        let png4 = TestCodecHelpers.buildPNG(
            width: 2,
            height: 1,
            bitDepth: 4,
            colorType: 0,
            raw: raw4,
            trns: [0x00, 0x0F]
        )
        let img4 = try PNGDecoder.decode(png4)
        #expect(
            img4.pixels == [
                17, 17, 17, 255,
                255, 255, 255, 0,
            ])

        // 16-bit grayscale 2x1 with tRNS = 0x1234 (distinguished from 0x1235 which shares high byte 0x12)
        let raw16: [UInt8] = [0, 0x12, 0x34, 0x12, 0x35]
        let png16 = TestCodecHelpers.buildPNG(
            width: 2,
            height: 1,
            bitDepth: 16,
            colorType: 0,
            raw: raw16,
            trns: [0x12, 0x34]
        )
        let img16 = try PNGDecoder.decode(png16)
        #expect(
            img16.pixels == [
                0x12, 0x12, 0x12, 0,
                0x12, 0x12, 0x12, 255,
            ])
    }

    @Test func pngRGB8And16WithTRNS() throws {
        // 8-bit RGB 2x1 with tRNS=(10,20,30)
        let raw8: [UInt8] = [0, 10, 20, 30, 40, 50, 60]
        let png8 = TestCodecHelpers.buildPNG(
            width: 2,
            height: 1,
            bitDepth: 8,
            colorType: 2,
            raw: raw8,
            trns: [0, 10, 0, 20, 0, 30]
        )
        let img8 = try PNGDecoder.decode(png8)
        #expect(
            img8.pixels == [
                10, 20, 30, 0,
                40, 50, 60, 255,
            ])

        // 16-bit RGB 1x1 -> high bytes taken
        let raw16: [UInt8] = [0, 0xAB, 0x01, 0xCD, 0x02, 0xEF, 0x03]
        let png16 = TestCodecHelpers.buildPNG(width: 1, height: 1, bitDepth: 16, colorType: 2, raw: raw16)
        let img16 = try PNGDecoder.decode(png16)
        #expect(img16.pixels == [0xAB, 0xCD, 0xEF, 255])
    }

    @Test func pngIndexedWithPLTEAndTRNS() throws {
        let plte: [UInt8] = [
            255, 0, 0,
            0, 255, 0,
            0, 0, 255,
            255, 255, 0,
        ]
        let trns: [UInt8] = [0, 128]  // idx 0->0, idx 1->128, idx 2/3->255
        // 2-bit indexed 4x1: indices [0, 1, 2, 3] -> 0b00_01_10_11 = 0x1B
        let raw2: [UInt8] = [0, 0x1B]
        let png2 = TestCodecHelpers.buildPNG(
            width: 4,
            height: 1,
            bitDepth: 2,
            colorType: 3,
            raw: raw2,
            plte: plte,
            trns: trns
        )
        let img2 = try PNGDecoder.decode(png2)
        #expect(
            img2.pixels == [
                255, 0, 0, 0,
                0, 255, 0, 128,
                0, 0, 255, 255,
                255, 255, 0, 255,
            ])

        // 8-bit indexed 2x1
        let raw8: [UInt8] = [0, 2, 3]
        let png8 = TestCodecHelpers.buildPNG(
            width: 2,
            height: 1,
            bitDepth: 8,
            colorType: 3,
            raw: raw8,
            plte: plte,
            trns: trns
        )
        let img8 = try PNGDecoder.decode(png8)
        #expect(
            img8.pixels == [
                0, 0, 255, 255,
                255, 255, 0, 255,
            ])
    }

    @Test func pngGrayscaleAlphaAndRGBA16() throws {
        // ColorType 4, 8-bit 2x1
        let rawGA8: [UInt8] = [0, 100, 200, 50, 255]
        let pngGA8 = TestCodecHelpers.buildPNG(width: 2, height: 1, bitDepth: 8, colorType: 4, raw: rawGA8)
        let imgGA8 = try PNGDecoder.decode(pngGA8)
        #expect(
            imgGA8.pixels == [
                100, 100, 100, 200,
                50, 50, 50, 255,
            ])

        // ColorType 4, 16-bit 1x1
        let rawGA16: [UInt8] = [0, 0x77, 0x99, 0x88, 0xAA]
        let pngGA16 = TestCodecHelpers.buildPNG(width: 1, height: 1, bitDepth: 16, colorType: 4, raw: rawGA16)
        let imgGA16 = try PNGDecoder.decode(pngGA16)
        #expect(imgGA16.pixels == [0x77, 0x77, 0x77, 0x88])

        // ColorType 6, 16-bit 1x1
        let rawRGBA16: [UInt8] = [0, 0x11, 0x01, 0x22, 0x02, 0x33, 0x03, 0x44, 0x04]
        let pngRGBA16 = TestCodecHelpers.buildPNG(
            width: 1,
            height: 1,
            bitDepth: 16,
            colorType: 6,
            raw: rawRGBA16
        )
        let imgRGBA16 = try PNGDecoder.decode(pngRGBA16)
        #expect(imgRGBA16.pixels == [0x11, 0x22, 0x33, 0x44])
    }

    @Test func pngAllFiveFiltersWithBorders() throws {
        // 5x5 RGBA image filtered with types [0, 1, 2, 3, 4] on rows 0..4
        let width = 5
        let height = 5
        var expected = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<expected.count {
            expected[i] = UInt8((i * 37 + 13) & 0xFF)
        }

        let filtered = TestCodecHelpers.applyPNGFilters(
            rawPixels: expected,
            width: width,
            height: height,
            bpp: 4,
            // Row 0 uses Sub(1), row 1 Up(2), row 2 Avg(3), row 3 Paeth(4), row 4 None(0)
            filterPerRow: [1, 2, 3, 4, 0]
        )
        // Also test Paeth on row 0 in a separate 3x2 image
        let png = TestCodecHelpers.buildPNG(
            width: width,
            height: height,
            bitDepth: 8,
            colorType: 6,
            raw: filtered,
            splitIDAT: true,
            extraAncillaryBeforeIDAT: [("gAMA", [0, 0, 0xB1, 0x8F]), ("sRGB", [0])]
        )
        let decoded = try PNGDecoder.decode(png)
        #expect(decoded.pixels == expected)

        // Row 0 with Paeth (4) and Average (3) border check
        let borderExpected: [UInt8] = [
            10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255,
            15, 25, 35, 200, 45, 55, 65, 210, 75, 85, 95, 220,
        ]
        let borderFiltered = TestCodecHelpers.applyPNGFilters(
            rawPixels: borderExpected,
            width: 3,
            height: 2,
            bpp: 4,
            filterPerRow: [4, 3]
        )
        let borderPNG = TestCodecHelpers.buildPNG(
            width: 3,
            height: 2,
            bitDepth: 8,
            colorType: 6,
            raw: borderFiltered
        )
        let borderDecoded = try PNGDecoder.decode(borderPNG)
        #expect(borderDecoded.pixels == borderExpected)
    }

    @Test func pngAdam7InterlacedVariousDimensions() throws {
        for (w, h) in [(1, 1), (3, 5), (8, 8), (9, 7)] {
            var expected = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let idx = (y * w + x) * 4
                    expected[idx] = UInt8((x * 31 + y * 17) & 0xFF)
                    expected[idx + 1] = UInt8((x * 13 + y * 43) & 0xFF)
                    expected[idx + 2] = UInt8((x * 7 + y * 59) & 0xFF)
                    expected[idx + 3] = UInt8(128 + ((x + y) & 0x7F))
                }
            }
            let rawAdam7 = TestCodecHelpers.encodeAdam7RGBA8(pixels: expected, width: w, height: h)
            let png = TestCodecHelpers.buildPNG(
                width: w,
                height: h,
                bitDepth: 8,
                colorType: 6,
                interlace: 1,
                raw: rawAdam7
            )
            let decoded = try PNGDecoder.decode(png)
            #expect(decoded.width == w)
            #expect(decoded.height == h)
            #expect(decoded.pixels == expected)
        }
    }

    // MARK: - PNG Error Cases

    @Test func pngMalformedAndLimits() {
        // Bad signature
        #expect {
            _ = try PNGDecoder.readInfo([0, 1, 2, 3, 4, 5, 6, 7])
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Bad CRC
        var badCRC = TestCodecHelpers.buildPNG(
            width: 1, height: 1, bitDepth: 8, colorType: 6, raw: [0, 1, 2, 3, 4])
        badCRC[badCRC.count - 1] ^= 0xFF
        #expect {
            _ = try PNGDecoder.decode(badCRC)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Unknown critical chunk -> unsupported
        let unknownCrit =
            TestCodecHelpers.pngSignature
            + TestCodecHelpers.makePNGChunk(
                "IHDR",
                data: TestCodecHelpers.makeIHDRData(width: 1, height: 1, bitDepth: 8, colorType: 6)
            )
            + TestCodecHelpers.makePNGChunk("CRIT", data: [1, 2, 3])
            + TestCodecHelpers.makePNGChunk("IDAT", data: TestCodecHelpers.zlibStored([0, 1, 2, 3, 4]))
            + TestCodecHelpers.makePNGChunk("IEND", data: [])
        #expect {
            _ = try PNGDecoder.decode(unknownCrit)
        } throws: { error in
            if case .unsupported = error as? AssetError { return true }
            return false
        }

        // Non-contiguous IDAT
        let nonContiguous =
            TestCodecHelpers.pngSignature
            + TestCodecHelpers.makePNGChunk(
                "IHDR",
                data: TestCodecHelpers.makeIHDRData(width: 1, height: 1, bitDepth: 8, colorType: 6)
            )
            + TestCodecHelpers.makePNGChunk("IDAT", data: [0x78, 0x9C])
            + TestCodecHelpers.makePNGChunk("tEXt", data: [65, 0, 66])
            + TestCodecHelpers.makePNGChunk("IDAT", data: [0x01])
            + TestCodecHelpers.makePNGChunk("IEND", data: [])
        #expect {
            _ = try PNGDecoder.decode(nonContiguous)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Missing IEND
        let noIEND =
            TestCodecHelpers.pngSignature
            + TestCodecHelpers.makePNGChunk(
                "IHDR",
                data: TestCodecHelpers.makeIHDRData(width: 1, height: 1, bitDepth: 8, colorType: 6)
            )
            + TestCodecHelpers.makePNGChunk("IDAT", data: TestCodecHelpers.zlibStored([0, 1, 2, 3, 4]))
        #expect {
            _ = try PNGDecoder.decode(noIEND)
        } throws: { error in
            if case .truncated = error as? AssetError { return true }
            return false
        }

        // Output limit exceeded BEFORE inflate (even with huge dims and empty IDAT)
        let hugeDims =
            TestCodecHelpers.pngSignature
            + TestCodecHelpers.makePNGChunk(
                "IHDR",
                data: TestCodecHelpers.makeIHDRData(width: 100, height: 100, bitDepth: 8, colorType: 6)
            )
            + TestCodecHelpers.makePNGChunk("IDAT", data: TestCodecHelpers.zlibStored([]))
            + TestCodecHelpers.makePNGChunk("IEND", data: [])
        let tightLimits = AssetLimits(maxOutputBytes: 1024, maxImageDimension: 200)
        #expect {
            _ = try PNGDecoder.decode(hugeDims, limits: tightLimits)
        } throws: { error in
            if case .limitExceeded = error as? AssetError { return true }
            return false
        }

        // Decompressed size != expected (too short)
        let wrongLen = TestCodecHelpers.buildPNG(
            width: 2, height: 1, bitDepth: 8, colorType: 6, raw: [0, 1, 2, 3, 4])
        #expect {
            _ = try PNGDecoder.decode(wrongLen)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // PLTE after IDAT
        let plteAfterIDAT =
            TestCodecHelpers.pngSignature
            + TestCodecHelpers.makePNGChunk(
                "IHDR",
                data: TestCodecHelpers.makeIHDRData(width: 1, height: 1, bitDepth: 8, colorType: 2)
            )
            + TestCodecHelpers.makePNGChunk("IDAT", data: TestCodecHelpers.zlibStored([0, 1, 2, 3]))
            + TestCodecHelpers.makePNGChunk("PLTE", data: [1, 2, 3])
            + TestCodecHelpers.makePNGChunk("IEND", data: [])
        #expect {
            _ = try PNGDecoder.decode(plteAfterIDAT)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }
    }

    // MARK: - JPEG Valid & Error Cases

    @Test func jpegSOF0SOF1SOF2AndMarkers() throws {
        // SOF0 with 0xFF padding, TEM, RST3, APP0, DHT (0xC4), DAC (0xCC), then SOF0
        let jpeg0 = TestCodecHelpers.buildJPEG(
            sofMarker: 0xC0,
            precision: 8,
            width: 640,
            height: 480,
            components: [(1, 2, 2), (2, 1, 1), (3, 1, 1)],
            extraMarkersBeforeSOF: [
                [0xFF, 0xFF, 0x01],  // fill FF + TEM
                [0xFF, 0xD3],  // RST3
                TestCodecHelpers.makeJPEGSegment(0xE0, payload: [0x4A, 0x46, 0x49, 0x46, 0x00]),
                TestCodecHelpers.makeJPEGSegment(0xC4, payload: [0x00]),  // DHT
                TestCodecHelpers.makeJPEGSegment(0xCC, payload: [0x00]),  // DAC
            ]
        )
        let info0 = try JPEGDecoder.readInfo(jpeg0)
        #expect(info0.width == 640)
        #expect(info0.height == 480)
        #expect(info0.componentCount == 3)
        #expect(info0.precision == 8)
        #expect(!info0.isProgressive)
        #expect(
            info0.components == [
                JPEGComponentSampling(id: 1, horizontalFactor: 2, verticalFactor: 2),
                JPEGComponentSampling(id: 2, horizontalFactor: 1, verticalFactor: 1),
                JPEGComponentSampling(id: 3, horizontalFactor: 1, verticalFactor: 1),
            ])
        #expect(info0.exifOrientation == nil)

        // SOF1, 12-bit, 1 component
        let jpeg1 = TestCodecHelpers.buildJPEG(
            sofMarker: 0xC1,
            precision: 12,
            width: 128,
            height: 64,
            components: [(1, 1, 1)]
        )
        let info1 = try JPEGDecoder.readInfo(jpeg1)
        #expect(info1.precision == 12)
        #expect(info1.componentCount == 1)
        #expect(!info1.isProgressive)

        // SOF2 progressive, 4 components
        let jpeg2 = TestCodecHelpers.buildJPEG(
            sofMarker: 0xC2,
            precision: 8,
            width: 320,
            height: 240,
            components: [(1, 1, 1), (2, 1, 1), (3, 1, 1), (4, 1, 1)]
        )
        let info2 = try JPEGDecoder.readInfo(jpeg2)
        #expect(info2.isProgressive)
        #expect(info2.componentCount == 4)
    }

    @Test func jpegEXIFOrientationLittleAndBigEndian() throws {
        for orientation: UInt8 in 1...8 {
            let app1LE = TestCodecHelpers.makeEXIFAPP1(orientation: orientation, littleEndian: true)
            let jpegLE = TestCodecHelpers.buildJPEG(
                sofMarker: 0xC0,
                precision: 8,
                width: 16,
                height: 16,
                components: [(1, 1, 1)],
                extraMarkersBeforeSOF: [app1LE]
            )
            let infoLE = try JPEGDecoder.readInfo(jpegLE)
            #expect(infoLE.exifOrientation == orientation)

            let app1BE = TestCodecHelpers.makeEXIFAPP1(orientation: orientation, littleEndian: false)
            let jpegBE = TestCodecHelpers.buildJPEG(
                sofMarker: 0xC0,
                precision: 8,
                width: 16,
                height: 16,
                components: [(1, 1, 1)],
                extraMarkersBeforeSOF: [app1BE]
            )
            let infoBE = try JPEGDecoder.readInfo(jpegBE)
            #expect(infoBE.exifOrientation == orientation)
        }

        // Non-Exif APP1 (XMP) should be ignored
        let xmpAPP1 = TestCodecHelpers.makeJPEGSegment(
            0xE1, payload: Array("http://ns.adobe.com/xap/1.0/\0".utf8))
        let jpegXMP = TestCodecHelpers.buildJPEG(
            sofMarker: 0xC0,
            precision: 8,
            width: 8,
            height: 8,
            components: [(1, 1, 1)],
            extraMarkersBeforeSOF: [xmpAPP1]
        )
        let infoXMP = try JPEGDecoder.readInfo(jpegXMP)
        #expect(infoXMP.exifOrientation == nil)
    }

    @Test func jpegUnsupportedAndInvalidCases() {
        // SOF3, SOF5, SOF9, SOF15 -> unsupported
        for marker: UInt8 in [0xC3, 0xC5, 0xC9, 0xCF] {
            let jpeg = TestCodecHelpers.buildJPEG(
                sofMarker: marker,
                precision: 8,
                width: 16,
                height: 16,
                components: [(1, 1, 1)]
            )
            #expect {
                _ = try JPEGDecoder.readInfo(jpeg)
            } throws: { error in
                if case .unsupported = error as? AssetError { return true }
                return false
            }
        }

        // Height 0 (DNL) -> unsupported
        let dnlJPEG = TestCodecHelpers.buildJPEG(
            sofMarker: 0xC0,
            precision: 8,
            width: 16,
            height: 0,
            components: [(1, 1, 1)]
        )
        #expect {
            _ = try JPEGDecoder.readInfo(dnlJPEG)
        } throws: { error in
            if case .unsupported = error as? AssetError { return true }
            return false
        }

        // Segment length < 2
        let badSegLen: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01]
        #expect {
            _ = try JPEGDecoder.readInfo(badSegLen)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Segment length past EOF
        let pastEOF: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x00]
        #expect {
            _ = try JPEGDecoder.readInfo(pastEOF)
        } throws: { error in
            if case .truncated = error as? AssetError { return true }
            return false
        }

        // Limits: maxOutputBytes exceeded
        let bigJPEG = TestCodecHelpers.buildJPEG(
            sofMarker: 0xC0,
            precision: 8,
            width: 100,
            height: 100,
            components: [(1, 1, 1), (2, 1, 1), (3, 1, 1)]
        )
        #expect {
            _ = try JPEGDecoder.readInfo(bigJPEG, limits: AssetLimits(maxOutputBytes: 10_000))
        } throws: { error in
            if case .limitExceeded = error as? AssetError { return true }
            return false
        }

        // Invalid EXIF orientation value 9
        let badOrientation = TestCodecHelpers.buildJPEG(
            sofMarker: 0xC0,
            precision: 8,
            width: 8,
            height: 8,
            components: [(1, 1, 1)],
            extraMarkersBeforeSOF: [TestCodecHelpers.makeEXIFAPP1(orientation: 9, littleEndian: true)]
        )
        #expect {
            _ = try JPEGDecoder.readInfo(badOrientation)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }
    }

    // MARK: - Deterministic Fuzzing (>= 2000 iterations per target)

    @Test func fuzzInflate2000() {
        let validZlib = TestCodecHelpers.zlibStored([10, 20, 30, 40, 50, 60, 70, 80], maxBlockSize: 4)
        let maxOut = 256

        CajuFuzz.run(seed: 0x1F1A_7E01, iterations: 2_000) { rng, i in
            let input: [UInt8]
            if i % 2 == 0 {
                let len = Int(rng.nextUInt32() % 128)
                input = TestCodecHelpers.randomBytes(count: len, rng: &rng)
            } else {
                input = TestCodecHelpers.mutateBytes(validZlib, rng: &rng)
            }

            do {
                let out = try Inflate.zlibDecompress(input, from: 0, maxOutput: maxOut, context: "fuzz")
                #expect(out.count <= maxOut)
            } catch {
                // Typed throws(AssetError) garante que só AssetError é lançado.
            }
        }
    }

    @Test func fuzzPNG2000() {
        let validSimple = TestCodecHelpers.buildPNG(
            width: 4,
            height: 3,
            bitDepth: 8,
            colorType: 6,
            raw: TestCodecHelpers.applyPNGFilters(
                rawPixels: [UInt8](repeating: 0x5A, count: 4 * 3 * 4),
                width: 4,
                height: 3,
                bpp: 4,
                filterPerRow: [0, 1, 4]
            )
        )
        let validIndexedAdam7 = TestCodecHelpers.buildPNG(
            width: 3,
            height: 3,
            bitDepth: 2,
            colorType: 3,
            interlace: 1,
            raw: [0, 0x00, 0, 0x00, 0, 0x00, 0, 0x00, 0, 0x00, 0, 0x00, 0, 0x00, 0, 0x00, 0, 0x00],
            plte: [10, 20, 30, 40, 50, 60],
            trns: [0, 255]
        )
        let seeds = [validSimple, validIndexedAdam7]
        let limits = AssetLimits(maxInputBytes: 4096, maxOutputBytes: 4096, maxImageDimension: 64)

        CajuFuzz.run(seed: 0x9E37_79B9, iterations: 2_000) { rng, i in
            let input: [UInt8]
            if i % 3 == 0 {
                let len = Int(rng.nextUInt32() % 256)
                input = TestCodecHelpers.randomBytes(count: len, rng: &rng)
            } else {
                let base = seeds[i % seeds.count]
                input = TestCodecHelpers.mutateBytes(base, rng: &rng)
            }

            do {
                let info = try PNGDecoder.readInfo(input, limits: limits)
                #expect(info.width > 0 && info.width <= limits.maxImageDimension)
                #expect(info.height > 0 && info.height <= limits.maxImageDimension)
            } catch {}

            do {
                let image = try PNGDecoder.decode(input, limits: limits)
                #expect(image.width <= limits.maxImageDimension)
                #expect(image.height <= limits.maxImageDimension)
                #expect(image.pixels.count == image.width * image.height * 4)
                #expect(image.pixels.count <= limits.maxOutputBytes)
            } catch {}
        }
    }

    @Test func fuzzJPEG2000() {
        let validJPEG = TestCodecHelpers.buildJPEG(
            sofMarker: 0xC0,
            precision: 8,
            width: 16,
            height: 12,
            components: [(1, 2, 2), (2, 1, 1), (3, 1, 1)],
            extraMarkersBeforeSOF: [TestCodecHelpers.makeEXIFAPP1(orientation: 6, littleEndian: true)]
        )
        let limits = AssetLimits(
            maxInputBytes: 4096,
            maxOutputBytes: 4096,
            maxImageDimension: 64,
            maxElements: 32
        )

        CajuFuzz.run(seed: 0xCAFE_BABE, iterations: 2_000) { rng, i in
            let input: [UInt8]
            if i % 2 == 0 {
                let len = Int(rng.nextUInt32() % 256)
                input = TestCodecHelpers.randomBytes(count: len, rng: &rng)
            } else {
                input = TestCodecHelpers.mutateBytes(validJPEG, rng: &rng)
            }

            do {
                let info = try JPEGDecoder.readInfo(input, limits: limits)
                #expect(info.width > 0 && info.width <= limits.maxImageDimension)
                #expect(info.height > 0 && info.height <= limits.maxImageDimension)
                #expect(info.width * info.height * info.componentCount <= limits.maxOutputBytes)
            } catch {}
        }
    }
}

// MARK: - Synthetic Test Helpers

private struct TestBitWriter {
    private var bytes: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var bitPos = 0

    mutating func writeBits(_ value: Int, count: Int) {
        for i in 0..<count {
            let bit = UInt8((value >> i) & 1)
            currentByte |= bit << UInt8(bitPos)
            bitPos += 1
            if bitPos == 8 {
                bytes.append(currentByte)
                currentByte = 0
                bitPos = 0
            }
        }
    }

    mutating func writeHuffmanCode(_ code: Int, length: Int) {
        for i in stride(from: length - 1, through: 0, by: -1) {
            let bit = UInt8((code >> i) & 1)
            currentByte |= bit << UInt8(bitPos)
            bitPos += 1
            if bitPos == 8 {
                bytes.append(currentByte)
                currentByte = 0
                bitPos = 0
            }
        }
    }

    mutating func finish() -> [UInt8] {
        if bitPos > 0 {
            bytes.append(currentByte)
            currentByte = 0
            bitPos = 0
        }
        return bytes
    }
}

private enum TestCodecHelpers {
    static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        for b in data {
            s1 = (s1 + UInt32(b)) % 65_521
            s2 = (s2 + s1) % 65_521
        }
        return (s2 << 16) | s1
    }

    static func wrapZlib(_ deflate: [UInt8], uncompressed: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        out.append(contentsOf: deflate)
        let adler = adler32(uncompressed)
        out.append(UInt8((adler >> 24) & 0xFF))
        out.append(UInt8((adler >> 16) & 0xFF))
        out.append(UInt8((adler >> 8) & 0xFF))
        out.append(UInt8(adler & 0xFF))
        return out
    }

    static func zlibStored(_ data: [UInt8], maxBlockSize: Int = 65_535) -> [UInt8] {
        var deflate: [UInt8] = []
        if data.isEmpty {
            deflate.append(0x01)
            deflate.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])
        } else {
            var offset = 0
            while offset < data.count {
                let chunkLen = min(maxBlockSize, data.count - offset)
                let isFinal: UInt8 = (offset + chunkLen == data.count) ? 1 : 0
                deflate.append(isFinal)
                let len16 = UInt16(chunkLen)
                let nlen16 = ~len16
                deflate.append(UInt8(len16 & 0xFF))
                deflate.append(UInt8(len16 >> 8))
                deflate.append(UInt8(nlen16 & 0xFF))
                deflate.append(UInt8(nlen16 >> 8))
                deflate.append(contentsOf: data[offset..<(offset + chunkLen)])
                offset += chunkLen
            }
        }
        return wrapZlib(deflate, uncompressed: data)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = 0xEDB8_8320 ^ (crc >> 1)
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func appendU32BE(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    static func makeIHDRData(
        width: UInt32,
        height: UInt32,
        bitDepth: UInt8,
        colorType: UInt8,
        compression: UInt8 = 0,
        filter: UInt8 = 0,
        interlace: UInt8 = 0
    ) -> [UInt8] {
        var data: [UInt8] = []
        appendU32BE(width, to: &data)
        appendU32BE(height, to: &data)
        data.append(bitDepth)
        data.append(colorType)
        data.append(compression)
        data.append(filter)
        data.append(interlace)
        return data
    }

    static func makePNGChunk(_ type: String, data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        var chunk: [UInt8] = []
        appendU32BE(UInt32(data.count), to: &chunk)
        chunk.append(contentsOf: typeBytes)
        chunk.append(contentsOf: data)
        let crc = crc32(typeBytes + data)
        appendU32BE(crc, to: &chunk)
        return chunk
    }

    static func buildPNG(
        width: Int,
        height: Int,
        bitDepth: UInt8,
        colorType: UInt8,
        interlace: UInt8 = 0,
        raw: [UInt8],
        plte: [UInt8]? = nil,
        trns: [UInt8]? = nil,
        splitIDAT: Bool = false,
        extraAncillaryBeforeIDAT: [(String, [UInt8])] = []
    ) -> [UInt8] {
        var out = pngSignature
        out.append(
            contentsOf: makePNGChunk(
                "IHDR",
                data: makeIHDRData(
                    width: UInt32(width),
                    height: UInt32(height),
                    bitDepth: bitDepth,
                    colorType: colorType,
                    interlace: interlace
                )
            )
        )
        for (name, data) in extraAncillaryBeforeIDAT {
            out.append(contentsOf: makePNGChunk(name, data: data))
        }
        if let plte {
            out.append(contentsOf: makePNGChunk("PLTE", data: plte))
        }
        if let trns {
            out.append(contentsOf: makePNGChunk("tRNS", data: trns))
        }
        let idatPayload = zlibStored(raw)
        if splitIDAT && idatPayload.count > 4 {
            let mid = idatPayload.count / 2
            out.append(contentsOf: makePNGChunk("IDAT", data: Array(idatPayload[0..<mid])))
            out.append(contentsOf: makePNGChunk("IDAT", data: Array(idatPayload[mid..<idatPayload.count])))
        } else {
            out.append(contentsOf: makePNGChunk("IDAT", data: idatPayload))
        }
        out.append(contentsOf: makePNGChunk("IEND", data: []))
        return out
    }

    static func applyPNGFilters(
        rawPixels: [UInt8],
        width: Int,
        height: Int,
        bpp: Int,
        filterPerRow: [UInt8]
    ) -> [UInt8] {
        let rowBytes = width * bpp
        var out: [UInt8] = []
        var prev = [UInt8](repeating: 0, count: rowBytes)
        for y in 0..<height {
            let filterType = filterPerRow[y % filterPerRow.count]
            out.append(filterType)
            let rowStart = y * rowBytes
            let curr = Array(rawPixels[rowStart..<(rowStart + rowBytes)])
            for i in 0..<rowBytes {
                let a = i >= bpp ? Int(curr[i - bpp]) : 0
                let b = Int(prev[i])
                let c = i >= bpp ? Int(prev[i - bpp]) : 0
                let pred: Int
                switch filterType {
                case 0: pred = 0
                case 1: pred = a
                case 2: pred = b
                case 3: pred = (a + b) >> 1
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a)
                    let pb = abs(p - b)
                    let pc = abs(p - c)
                    if pa <= pb && pa <= pc { pred = a } else if pb <= pc { pred = b } else { pred = c }
                default: pred = 0
                }
                out.append(curr[i] &- UInt8(pred & 0xFF))
            }
            prev = curr
        }
        return out
    }

    static func encodeAdam7RGBA8(pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let xStart = [0, 4, 0, 2, 0, 1, 0]
        let yStart = [0, 0, 4, 0, 2, 0, 1]
        let xStep = [8, 8, 4, 4, 2, 2, 1]
        let yStep = [8, 8, 8, 4, 4, 2, 2]
        var out: [UInt8] = []
        for pass in 0..<7 {
            guard width > xStart[pass], height > yStart[pass] else { continue }
            let passW = (width - xStart[pass] + xStep[pass] - 1) / xStep[pass]
            let passH = (height - yStart[pass] + yStep[pass] - 1) / yStep[pass]
            var passPixels: [UInt8] = []
            for py in 0..<passH {
                let y = yStart[pass] + py * yStep[pass]
                for px in 0..<passW {
                    let x = xStart[pass] + px * xStep[pass]
                    let idx = (y * width + x) * 4
                    passPixels.append(contentsOf: pixels[idx..<(idx + 4)])
                }
            }
            out.append(
                contentsOf: applyPNGFilters(
                    rawPixels: passPixels,
                    width: passW,
                    height: passH,
                    bpp: 4,
                    filterPerRow: [UInt8(pass % 5)]
                ))
        }
        return out
    }

    static func makeJPEGSegment(_ marker: UInt8, payload: [UInt8]) -> [UInt8] {
        let len = UInt16(payload.count + 2)
        return [0xFF, marker, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
    }

    static func buildJPEG(
        sofMarker: UInt8,
        precision: UInt8,
        width: UInt16,
        height: UInt16,
        components: [(UInt8, UInt8, UInt8)],
        extraMarkersBeforeSOF: [[UInt8]] = []
    ) -> [UInt8] {
        var out: [UInt8] = [0xFF, 0xD8]  // SOI
        for seg in extraMarkersBeforeSOF {
            out.append(contentsOf: seg)
        }
        var sofPayload: [UInt8] = [
            precision,
            UInt8(height >> 8), UInt8(height & 0xFF),
            UInt8(width >> 8), UInt8(width & 0xFF),
            UInt8(components.count),
        ]
        for (id, h, v) in components {
            sofPayload.append(id)
            sofPayload.append((h << 4) | v)
            sofPayload.append(0)
        }
        out.append(contentsOf: makeJPEGSegment(sofMarker, payload: sofPayload))
        out.append(contentsOf: [0xFF, 0xD9])  // EOI
        return out
    }

    static func makeEXIFAPP1(orientation: UInt8, littleEndian: Bool) -> [UInt8] {
        var tiff: [UInt8] = []
        if littleEndian {
            tiff.append(contentsOf: [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])  // II, 42, off 8
            tiff.append(contentsOf: [0x01, 0x00])  // 1 entry
            tiff.append(contentsOf: [0x12, 0x01])  // tag 0x0112
            tiff.append(contentsOf: [0x03, 0x00])  // type SHORT
            tiff.append(contentsOf: [0x01, 0x00, 0x00, 0x00])  // count 1
            tiff.append(contentsOf: [orientation, 0x00, 0x00, 0x00])  // value
        } else {
            tiff.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])  // MM, 42, off 8
            tiff.append(contentsOf: [0x00, 0x01])  // 1 entry
            tiff.append(contentsOf: [0x01, 0x12])  // tag 0x0112
            tiff.append(contentsOf: [0x00, 0x03])  // type SHORT
            tiff.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // count 1
            tiff.append(contentsOf: [0x00, orientation, 0x00, 0x00])  // value
        }
        let header: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        return makeJPEGSegment(0xE1, payload: header + tiff)
    }

    static func randomBytes(count: Int, rng: inout CajuPCG32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = UInt8(rng.nextUInt32() & 0xFF)
        }
        return out
    }

    static func mutateBytes(_ base: [UInt8], rng: inout CajuPCG32) -> [UInt8] {
        var copy = base
        guard !copy.isEmpty else { return copy }
        let mode = rng.nextUInt32() % 4
        if mode == 0 && copy.count > 1 {
            // Truncation
            let newLen = Int(rng.nextUInt32() % UInt32(copy.count))
            return Array(copy[0..<newLen])
        } else {
            // Byte flips
            let flips = 1 + Int(rng.nextUInt32() % 4)
            for _ in 0..<flips {
                let idx = Int(rng.nextUInt32() % UInt32(copy.count))
                copy[idx] ^= UInt8((rng.nextUInt32() & 0xFF) | 1)
            }
            return copy
        }
    }
}
