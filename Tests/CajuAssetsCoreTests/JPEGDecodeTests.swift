import CajuTesting
import Testing

@testable import CajuAssetsCore

@Suite("JPEG Pixel Decode")
struct JPEGDecodeTests {
    // MARK: - Casos válidos: Baseline, Progressivo, Subamostragem, Restart e EXIF

    @Test func decodesEmbeddedRealJFIF16x16() throws {
        // JPEG JFIF real 16x16 (4:2:0) gerado a partir de gradiente RGB (r=x*16, g=y*16, b=(x+y)*8).
        let jpeg: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
            0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00,
            0x10, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xC4, 0x00,
            0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
            0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04,
            0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D, 0x01, 0x02, 0x03, 0x00, 0x04,
            0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14,
            0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24,
            0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27,
            0x28, 0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46,
            0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64,
            0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A,
            0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
            0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3,
            0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8,
            0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2, 0xE3,
            0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7,
            0xF8, 0xF9, 0xFA, 0xFF, 0xC4, 0x00, 0x1F, 0x01, 0x00, 0x03, 0x01, 0x01, 0x01, 0x01,
            0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x11, 0x00,
            0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02,
            0x77, 0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51,
            0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1,
            0x09, 0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1,
            0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37,
            0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55,
            0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73,
            0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88,
            0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4,
            0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9,
            0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5,
            0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
            0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDB, 0x00, 0x43, 0x00,
            0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x01, 0x01, 0x02, 0x03, 0x02, 0x02, 0x02,
            0x03, 0x04, 0x03, 0x03, 0x03, 0x03, 0x04, 0x05, 0x04, 0x04, 0x04, 0x04, 0x04, 0x05,
            0x06, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
            0x06, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x08, 0x08, 0x08, 0x08, 0x08, 0x09, 0x09,
            0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0xFF, 0xDB, 0x00, 0x43, 0x01, 0x01,
            0x01, 0x01, 0x02, 0x02, 0x02, 0x04, 0x02, 0x02, 0x04, 0x09, 0x06, 0x05, 0x06, 0x09,
            0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
            0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
            0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
            0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0xFF, 0xDD, 0x00, 0x04, 0x00, 0x01, 0xFF,
            0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00, 0xFE,
            0x6F, 0xFE, 0x0C, 0x7E, 0xC8, 0x7F, 0xEA, 0xBF, 0xD1, 0x7D, 0x3B, 0x57, 0xEB, 0x6F,
            0xC1, 0x7F, 0xD9, 0x0F, 0xFD, 0x57, 0xFA, 0x2F, 0xA7, 0xF0, 0xD7, 0xE9, 0x3F, 0xC1,
            0x7F, 0xD9, 0x0F, 0xFD, 0x57, 0xFA, 0x2F, 0xA7, 0xF0, 0xD7, 0xEB, 0x67, 0xC1, 0x8F,
            0xD9, 0x0F, 0xFD, 0x57, 0xFA, 0x2F, 0xA7, 0x6A, 0x38, 0x43, 0x8C, 0x36, 0xD4, 0x3F,
            0x67, 0xA7, 0xED, 0x0B, 0xFE, 0x07, 0xEF, 0xFB, 0x75, 0x3F, 0xFF, 0xD9,
        ]

        let image = try JPEGDecoder.decode(jpeg)
        #expect(image.width == 16)
        #expect(image.height == 16)
        #expect(image.pixels.count == 16 * 16 * 4)
        #expect(image.exifOrientation == nil)

        for y in 0..<16 {
            for x in 0..<16 {
                let idx = (y * 16 + x) * 4
                let expR = x * 16
                let expG = y * 16
                let expB = (x + y) * 8
                #expect(abs(Int(image.pixels[idx]) - expR) <= 24)
                #expect(abs(Int(image.pixels[idx + 1]) - expG) <= 24)
                #expect(abs(Int(image.pixels[idx + 2]) - expB) <= 24)
                #expect(image.pixels[idx + 3] == 255)
            }
        }
    }

    @Test func decodesGrayscaleBaselineWithNonMultipleDimensions() throws {
        let width = 13
        let height = 11
        var expectedGray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                expectedGray[y * width + x] = UInt8((x * 17 + y * 21) & 0xFF)
            }
        }

        let jpeg = SyntheticJPEGEncoder.encodeBaselineGrayscale(
            width: width,
            height: height,
            gray: expectedGray
        )
        let image = try JPEGDecoder.decode(jpeg)
        #expect(image.width == width)
        #expect(image.height == height)
        #expect(image.pixels.count == width * height * 4)

        for i in 0..<(width * height) {
            let p = i * 4
            #expect(image.pixels[p] == image.pixels[p + 1])
            #expect(image.pixels[p + 1] == image.pixels[p + 2])
            #expect(image.pixels[p + 3] == 255)
            #expect(abs(Int(image.pixels[p]) - Int(expectedGray[i])) <= 4)
        }
    }

    @Test func decodesBaselineSubsampling444And422And420() throws {
        let modes: [(String, Int, Int, SyntheticJPEGEncoder.Subsampling)] = [
            ("444", 16, 16, .ycbcr444),
            ("422", 15, 9, .ycbcr422),
            ("420", 17, 13, .ycbcr420),
        ]

        for (_, w, h, sub) in modes {
            // Blocos constantes 8x8/16x16 de cores puras e médias para minimizar perda de subamostragem.
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for y in 0..<h {
                for x in 0..<w {
                    let bx = x / 4
                    let by = y / 4
                    let colorIndex = (bx + by * 3) % 4
                    let r: UInt8
                    let g: UInt8
                    let b: UInt8
                    switch colorIndex {
                    case 0: (r, g, b) = (220, 40, 40)
                    case 1: (r, g, b) = (40, 200, 60)
                    case 2: (r, g, b) = (50, 70, 220)
                    default: (r, g, b) = (210, 210, 210)
                    }
                    let idx = (y * w + x) * 3
                    rgb[idx] = r
                    rgb[idx + 1] = g
                    rgb[idx + 2] = b
                }
            }

            let jpeg = SyntheticJPEGEncoder.encodeBaselineRGB(
                width: w,
                height: h,
                rgb: rgb,
                subsampling: sub
            )
            let image = try JPEGDecoder.decode(jpeg)
            #expect(image.width == w)
            #expect(image.height == h)
            #expect(image.pixels.count == w * h * 4)

            // No centro dos blocos 4x4, a cor deve permanecer próxima do esperado (subamostragem suave).
            for y in 0..<h {
                for x in 0..<w {
                    let p = (y * w + x) * 4
                    let s = (y * w + x) * 3
                    #expect(image.pixels[p + 3] == 255)
                    if sub == .ycbcr444 {
                        #expect(abs(Int(image.pixels[p]) - Int(rgb[s])) <= 8)
                        #expect(abs(Int(image.pixels[p + 1]) - Int(rgb[s + 1])) <= 8)
                        #expect(abs(Int(image.pixels[p + 2]) - Int(rgb[s + 2])) <= 8)
                    } else if (x % 4 == 1 || x % 4 == 2) && (y % 4 == 1 || y % 4 == 2) {
                        #expect(abs(Int(image.pixels[p]) - Int(rgb[s])) <= 32)
                        #expect(abs(Int(image.pixels[p + 1]) - Int(rgb[s + 1])) <= 32)
                        #expect(abs(Int(image.pixels[p + 2]) - Int(rgb[s + 2])) <= 32)
                    }
                }
            }
        }
    }

    @Test func decodesRestartMarkersAndReportsEXIFWithoutRotating() throws {
        // 32x24 -> 4x3 = 12 MCUs (4:4:4), DRI = 1 -> 11 marcadores RST (RST0..RST7, RST0..RST2).
        let w = 32
        let h = 24
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 3
                // Assimétrico: lado esquerdo vermelho, lado direito azul, topo verde mais forte.
                rgb[idx] = x < 16 ? 220 : 30
                rgb[idx + 1] = y < 12 ? 180 : 40
                rgb[idx + 2] = x < 16 ? 30 : 220
            }
        }

        let jpeg = SyntheticJPEGEncoder.encodeBaselineRGB(
            width: w,
            height: h,
            rgb: rgb,
            subsampling: .ycbcr444,
            restartInterval: 1,
            exifOrientation: 6
        )
        let image = try JPEGDecoder.decode(jpeg)
        #expect(image.width == w)
        #expect(image.height == h)
        #expect(image.exifOrientation == 6)

        // Verifica que os pixels NÃO foram rotacionados (canto superior esquerdo continua avermelhado).
        #expect(image.pixels[0] > 180)
        #expect(image.pixels[1] > 140)
        #expect(image.pixels[2] < 70)

        // Canto inferior direito continua azulado.
        let br = ((h - 1) * w + (w - 1)) * 4
        #expect(image.pixels[br] < 70)
        #expect(image.pixels[br + 2] > 180)
    }

    @Test func decodesProgressiveSOF2WithSuccessiveApproximation() throws {
        for (w, h, sub) in [(16, 16, SyntheticJPEGEncoder.Subsampling.ycbcr444), (17, 13, .ycbcr420)] {
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for y in 0..<h {
                for x in 0..<w {
                    let idx = (y * w + x) * 3
                    rgb[idx] = UInt8(30 + (x * 12) % 200)
                    rgb[idx + 1] = UInt8(40 + (y * 14) % 190)
                    rgb[idx + 2] = UInt8(20 + ((x + y) * 9) % 210)
                }
            }

            let progressiveJPEG = SyntheticJPEGEncoder.encodeProgressiveRGB(
                width: w,
                height: h,
                rgb: rgb,
                subsampling: sub
            )
            let baselineJPEG = SyntheticJPEGEncoder.encodeBaselineRGB(
                width: w,
                height: h,
                rgb: rgb,
                subsampling: sub
            )

            let progImage = try JPEGDecoder.decode(progressiveJPEG)
            let baseImage = try JPEGDecoder.decode(baselineJPEG)
            #expect(progImage.width == w)
            #expect(progImage.height == h)
            #expect(progImage.pixels == baseImage.pixels)
        }
    }

    @Test func decodesProgressiveEOBRunInACFirstAndACRefine() throws {
        // 24x8 (3 blocos 8x8 em cinza) exercitando EOBRUN > 1 em AC first e AC refine.
        let jpeg = SyntheticJPEGEncoder.buildProgressiveGrayscaleEOBRunVector()
        let img = try JPEGDecoder.decode(jpeg)
        #expect(img.width == 24)
        #expect(img.height == 8)
        // Bloco 0 tem AC[1] != 0 (variação horizontal); blocos 1 e 2 são cinza uniforme (128).
        #expect(img.pixels[0] != img.pixels[7 * 4])
        for x in 8..<24 {
            let p = x * 4
            #expect(img.pixels[p] == 128)
            #expect(img.pixels[p + 1] == 128)
            #expect(img.pixels[p + 2] == 128)
        }
    }

    @Test func decodesMultiScanNonInterleavedSequential() throws {
        let w = 16
        let h = 16
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 3
                rgb[idx] = UInt8(x * 16)
                rgb[idx + 1] = UInt8(y * 16)
                rgb[idx + 2] = 128
            }
        }
        let jpeg = SyntheticJPEGEncoder.encodeMultiScanSequentialRGB(width: w, height: h, rgb: rgb)
        let image = try JPEGDecoder.decode(jpeg)
        #expect(image.width == w)
        #expect(image.height == h)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                #expect(abs(Int(image.pixels[p]) - x * 16) <= 10)
                #expect(abs(Int(image.pixels[p + 1]) - y * 16) <= 10)
                #expect(abs(Int(image.pixels[p + 2]) - 128) <= 10)
            }
        }
    }

    // MARK: - Rejeições e Limites

    @Test func rejectsUnsupportedModesPrecisionAndCMYK() {
        // Aritmético (SOF9, SOF10, SOF11)
        for marker: UInt8 in [0xC9, 0xCA, 0xCB] {
            let jpeg = SyntheticJPEGEncoder.buildMinimalHeaderJPEG(
                sofMarker: marker,
                precision: 8,
                width: 8,
                height: 8,
                components: [(1, 1, 1)]
            )
            #expect {
                _ = try JPEGDecoder.decode(jpeg)
            } throws: { error in
                if case .unsupported = error as? AssetError { return true }
                return false
            }
        }

        // 12 bits (SOF0 e SOF2)
        for marker: UInt8 in [0xC0, 0xC2] {
            let jpeg = SyntheticJPEGEncoder.buildMinimalHeaderJPEG(
                sofMarker: marker,
                precision: 12,
                width: 8,
                height: 8,
                components: [(1, 1, 1)]
            )
            #expect {
                _ = try JPEGDecoder.decode(jpeg)
            } throws: { error in
                if case .unsupported = error as? AssetError { return true }
                return false
            }
        }

        // CMYK (4 componentes)
        let cmyk = SyntheticJPEGEncoder.buildMinimalHeaderJPEG(
            sofMarker: 0xC0,
            precision: 8,
            width: 8,
            height: 8,
            components: [(1, 1, 1), (2, 1, 1), (3, 1, 1), (4, 1, 1)]
        )
        #expect {
            _ = try JPEGDecoder.decode(cmyk)
        } throws: { error in
            if case .unsupported = error as? AssetError { return true }
            return false
        }
    }

    @Test func rejectsDimensionsAndOutputBytesAboveLimitsBeforeAllocating() {
        let valid = SyntheticJPEGEncoder.encodeBaselineRGB(
            width: 16,
            height: 16,
            rgb: [UInt8](repeating: 128, count: 16 * 16 * 3),
            subsampling: .ycbcr444
        )

        #expect(throws: AssetError.limitExceeded(context: "jpeg.height", limit: 8, requested: 16)) {
            _ = try JPEGDecoder.decode(valid, limits: AssetLimits(maxImageDimension: 8))
        }

        // 16 * 16 * 4 = 1024; 16 * 16 * 3 = 768. Limite 1023 deve falhar em RGBA8 antes de alocar.
        #expect(throws: AssetError.limitExceeded(context: "jpeg.output", limit: 1023, requested: 1024)) {
            _ = try JPEGDecoder.decode(valid, limits: AssetLimits(maxOutputBytes: 1023))
        }
    }

    @Test func rejectsMissingTablesTruncationAndBadRestartMarker() {
        let valid = SyntheticJPEGEncoder.encodeBaselineRGB(
            width: 16,
            height: 8,
            rgb: [UInt8](repeating: 100, count: 16 * 8 * 3),
            subsampling: .ycbcr444,
            restartInterval: 1
        )

        // Truncamentos em todos os prefixos até EOI
        for cut in stride(from: 0, to: valid.count, by: max(1, valid.count / 25)) {
            #expect(throws: AssetError.self) {
                _ = try JPEGDecoder.decode(Array(valid[0..<cut]))
            }
        }

        // Sem DQT
        let noDQT = SyntheticJPEGEncoder.encodeBaselineRGB(
            width: 8,
            height: 8,
            rgb: [UInt8](repeating: 100, count: 8 * 8 * 3),
            subsampling: .ycbcr444,
            omitDQT: true
        )
        #expect {
            _ = try JPEGDecoder.decode(noDQT)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Sem DHT
        let noDHT = SyntheticJPEGEncoder.encodeBaselineRGB(
            width: 8,
            height: 8,
            rgb: [UInt8](repeating: 100, count: 8 * 8 * 3),
            subsampling: .ycbcr444,
            omitDHT: true
        )
        #expect {
            _ = try JPEGDecoder.decode(noDHT)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }

        // Corrompe marcador RST0 para RST5
        var badRST = valid
        for i in 0..<(badRST.count - 1) where badRST[i] == 0xFF && badRST[i + 1] == 0xD0 {
            badRST[i + 1] = 0xD5
            break
        }
        #expect {
            _ = try JPEGDecoder.decode(badRST)
        } throws: { error in
            if case .invalid = error as? AssetError { return true }
            return false
        }
    }

    // MARK: - Fuzz Determinístico

    @Test func fuzzJPEGDecode2000() {
        let baseSeed = SyntheticJPEGEncoder.encodeBaselineRGB(
            width: 16,
            height: 12,
            rgb: [UInt8](repeating: 120, count: 16 * 12 * 3),
            subsampling: .ycbcr420,
            restartInterval: 1,
            exifOrientation: 3
        )
        let progSeed = SyntheticJPEGEncoder.encodeProgressiveRGB(
            width: 8,
            height: 8,
            rgb: [UInt8](repeating: 90, count: 8 * 8 * 3),
            subsampling: .ycbcr444
        )
        let seeds = [baseSeed, progSeed]
        let limits = AssetLimits(
            maxInputBytes: 4096,
            maxOutputBytes: 4096,
            maxImageDimension: 64,
            maxElements: 32
        )

        CajuFuzz.run(seed: 0xDEAD_BEEF, iterations: 2_000) { rng, i in
            let input: [UInt8]
            if i % 3 == 0 {
                let len = Int(rng.nextUInt32() % 512)
                var buf = [UInt8](repeating: 0, count: len)
                for idx in 0..<len {
                    buf[idx] = UInt8(rng.nextUInt32() & 0xFF)
                }
                if len >= 2 {
                    buf[0] = 0xFF
                    buf[1] = 0xD8
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
                let img = try JPEGDecoder.decode(input, limits: limits)
                #expect(img.width > 0 && img.width <= limits.maxImageDimension)
                #expect(img.height > 0 && img.height <= limits.maxImageDimension)
                #expect(img.pixels.count == img.width * img.height * 4)
                #expect(img.pixels.count <= limits.maxOutputBytes)
            } catch {
                // Apenas AssetError tipado.
            }
        }
    }
}

// MARK: - Codificador JPEG Sintético para Testes

private enum SyntheticJPEGEncoder {
    enum Subsampling {
        case ycbcr444
        case ycbcr422
        case ycbcr420
    }

    private static let naturalToZigzag: [Int] = [
        0, 1, 5, 6, 14, 15, 27, 28,
        2, 4, 7, 13, 16, 26, 29, 42,
        3, 8, 12, 17, 25, 30, 41, 43,
        9, 11, 18, 24, 31, 40, 44, 53,
        10, 19, 23, 32, 39, 45, 52, 54,
        20, 22, 33, 38, 46, 51, 55, 60,
        21, 34, 37, 47, 50, 56, 59, 61,
        35, 36, 48, 49, 57, 58, 62, 63,
    ]

    private static let zigzagToNatural: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10,
        17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63,
    ]

    // Tabelas padrão ITU-T T.81 Anexo K
    private static let stdDCLumCounts: [UInt8] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    private static let stdDCLumValues: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

    private static let stdDCChrCounts: [UInt8] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
    private static let stdDCChrValues: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

    private static let stdACLumCounts: [UInt8] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
    private static let stdACLumValues: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    private static let stdACChrCounts: [UInt8] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
    private static let stdACChrValues: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
        0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
        0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
        0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    private static let lumQuantZigzag: [Int] = [UInt8](repeating: 2, count: 64).map { Int($0) }
    private static let chrQuantZigzag: [Int] = [UInt8](repeating: 3, count: 64).map { Int($0) }

    static func buildMinimalHeaderJPEG(
        sofMarker: UInt8,
        precision: UInt8,
        width: UInt16,
        height: UInt16,
        components: [(UInt8, UInt8, UInt8)]
    ) -> [UInt8] {
        var out: [UInt8] = [0xFF, 0xD8]
        var sof: [UInt8] = [
            precision,
            UInt8(height >> 8), UInt8(height & 0xFF),
            UInt8(width >> 8), UInt8(width & 0xFF),
            UInt8(components.count),
        ]
        for (id, h, v) in components {
            sof.append(id)
            sof.append((h << 4) | v)
            sof.append(0)
        }
        appendSegment(0xFF, sofMarker, payload: sof, to: &out)
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    static func buildProgressiveGrayscaleEOBRunVector() -> [UInt8] {
        // 24x8 (3 blocos), quant=1, tabela AC simples: 0x00=len1(0), 0x10=len2(10), 0x01=len2(11)
        // Bloco 0: AC[1] = +3 (Al=1 -> +1 no scan AC first, +1 bit no scan AC refine).
        // Blocos 1 e 2: todos AC zero -> cobertos por EOBRUN = 2 (símbolo 0x10 + extra bit 0).
        var out: [UInt8] = [0xFF, 0xD8]
        appendDQT(id: 0, quantZZ: [Int](repeating: 1, count: 64), to: &out)
        appendDHT(
            tcTh: 0x00,
            counts: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            values: [0],
            to: &out
        )
        appendDHT(
            tcTh: 0x10,
            counts: [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            values: [0x00, 0x10, 0x01],
            to: &out
        )
        appendSOF(marker: 0xC2, width: 24, height: 8, comps: [(1, 1, 1, 0)], to: &out)

        // Scan 1: DC 0..0 (3 blocos com diff=0)
        appendSegment(0xFF, 0xDA, payload: [1, 1, 0x00, 0, 0, 0x00], to: &out)
        do {
            var bw = JPEGBitWriter()
            for _ in 0..<3 { bw.writeBits(0, count: 1) }
            out.append(contentsOf: bw.finish())
        }

        // Scan 2: AC first Ss=1..63, Ah=0, Al=1
        appendSegment(0xFF, 0xDA, payload: [1, 1, 0x00, 1, 63, 0x01], to: &out)
        do {
            var bw = JPEGBitWriter()
            bw.writeBits(0b11, count: 2)  // 0x01
            bw.writeBits(1, count: 1)  // +1 (Al=1 => +2)
            bw.writeBits(0, count: 1)  // EOB1
            bw.writeBits(0b10, count: 2)  // 0x10 (EOBRUN=2)
            bw.writeBits(0, count: 1)  // extra 0 -> pula blocos 1 e 2
            out.append(contentsOf: bw.finish())
        }

        // Scan 3: AC refine Ss=1..63, Ah=1, Al=0
        appendSegment(0xFF, 0xDA, payload: [1, 1, 0x00, 1, 63, 0x10], to: &out)
        do {
            var bw = JPEGBitWriter()
            bw.writeBits(0, count: 1)  // EOB1
            bw.writeBits(1, count: 1)  // refina AC[1]: +2 -> +3
            bw.writeBits(0b10, count: 2)  // 0x10 (EOBRUN=2)
            bw.writeBits(0, count: 1)  // extra 0 -> pula blocos 1 e 2
            out.append(contentsOf: bw.finish())
        }

        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    static func encodeBaselineGrayscale(width: Int, height: Int, gray: [UInt8]) -> [UInt8] {
        let blocks = encodeComponentBlocks(
            plane: gray,
            planeW: width,
            planeH: height,
            mcuCols: (width + 7) / 8,
            mcuRows: (height + 7) / 8,
            h: 1,
            v: 1,
            quantZZ: lumQuantZigzag
        )

        var out: [UInt8] = [0xFF, 0xD8]
        appendDQT(id: 0, quantZZ: lumQuantZigzag, to: &out)
        appendDHT(tcTh: 0x00, counts: stdDCLumCounts, values: stdDCLumValues, to: &out)
        appendDHT(tcTh: 0x10, counts: stdACLumCounts, values: stdACLumValues, to: &out)
        appendSOF(marker: 0xC0, width: width, height: height, comps: [(1, 1, 1, 0)], to: &out)

        let dcTable = HuffmanEncoder(counts: stdDCLumCounts, values: stdDCLumValues)
        let acTable = HuffmanEncoder(counts: stdACLumCounts, values: stdACLumValues)

        appendSegment(0xFF, 0xDA, payload: [1, 1, 0x00, 0, 63, 0], to: &out)
        var bw = JPEGBitWriter()
        var dcPred = 0
        for blk in blocks {
            encodeSequentialBlock(blk, dcPred: &dcPred, dcEnc: dcTable, acEnc: acTable, bw: &bw)
        }
        out.append(contentsOf: bw.finish())
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    static func encodeBaselineRGB(
        width: Int,
        height: Int,
        rgb: [UInt8],
        subsampling: Subsampling,
        restartInterval: Int = 0,
        exifOrientation: UInt8? = nil,
        omitDQT: Bool = false,
        omitDHT: Bool = false
    ) -> [UInt8] {
        let (comps, planeBlocks) = prepareYCbCrBlocks(
            width: width,
            height: height,
            rgb: rgb,
            subsampling: subsampling
        )

        var out: [UInt8] = [0xFF, 0xD8]
        if let exifOrientation {
            appendEXIF(orientation: exifOrientation, to: &out)
        }
        if !omitDQT {
            appendDQT(id: 0, quantZZ: lumQuantZigzag, to: &out)
            appendDQT(id: 1, quantZZ: chrQuantZigzag, to: &out)
        }
        if !omitDHT {
            appendDHT(tcTh: 0x00, counts: stdDCLumCounts, values: stdDCLumValues, to: &out)
            appendDHT(tcTh: 0x10, counts: stdACLumCounts, values: stdACLumValues, to: &out)
            appendDHT(tcTh: 0x01, counts: stdDCChrCounts, values: stdDCChrValues, to: &out)
            appendDHT(tcTh: 0x11, counts: stdACChrCounts, values: stdACChrValues, to: &out)
        }
        if restartInterval > 0 {
            appendSegment(
                0xFF,
                0xDD,
                payload: [UInt8(restartInterval >> 8), UInt8(restartInterval & 0xFF)],
                to: &out
            )
        }
        appendSOF(marker: 0xC0, width: width, height: height, comps: comps, to: &out)
        appendSegment(
            0xFF,
            0xDA,
            payload: [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0],
            to: &out
        )

        let dcLum = HuffmanEncoder(counts: stdDCLumCounts, values: stdDCLumValues)
        let acLum = HuffmanEncoder(counts: stdACLumCounts, values: stdACLumValues)
        let dcChr = HuffmanEncoder(counts: stdDCChrCounts, values: stdDCChrValues)
        let acChr = HuffmanEncoder(counts: stdACChrCounts, values: stdACChrValues)

        let maxH = comps.map { Int($0.1) }.max() ?? 1
        let maxV = comps.map { Int($0.2) }.max() ?? 1
        let mcuCols = (width + maxH * 8 - 1) / (maxH * 8)
        let mcuRows = (height + maxV * 8 - 1) / (maxV * 8)

        var bw = JPEGBitWriter()
        var dcPred = [0, 0, 0]
        var mcuIdx = 0
        var rstIdx = 0

        for my in 0..<mcuRows {
            for mx in 0..<mcuCols {
                if restartInterval > 0 && mcuIdx > 0 && (mcuIdx % restartInterval) == 0 {
                    out.append(contentsOf: bw.finish())
                    out.append(0xFF)
                    out.append(UInt8(0xD0 + (rstIdx & 7)))
                    rstIdx += 1
                    bw = JPEGBitWriter()
                    dcPred = [0, 0, 0]
                }
                for c in 0..<3 {
                    let h = Int(comps[c].1)
                    let v = Int(comps[c].2)
                    let stride = mcuCols * h
                    let dcEnc = c == 0 ? dcLum : dcChr
                    let acEnc = c == 0 ? acLum : acChr
                    for dy in 0..<v {
                        for dx in 0..<h {
                            let blk = planeBlocks[c][(my * v + dy) * stride + (mx * h + dx)]
                            encodeSequentialBlock(
                                blk, dcPred: &dcPred[c], dcEnc: dcEnc, acEnc: acEnc, bw: &bw)
                        }
                    }
                }
                mcuIdx += 1
            }
        }
        out.append(contentsOf: bw.finish())
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    static func encodeMultiScanSequentialRGB(width: Int, height: Int, rgb: [UInt8]) -> [UInt8] {
        let (comps, planeBlocks) = prepareYCbCrBlocks(
            width: width,
            height: height,
            rgb: rgb,
            subsampling: .ycbcr444
        )
        var out: [UInt8] = [0xFF, 0xD8]
        appendDQT(id: 0, quantZZ: lumQuantZigzag, to: &out)
        appendDQT(id: 1, quantZZ: chrQuantZigzag, to: &out)
        appendDHT(tcTh: 0x00, counts: stdDCLumCounts, values: stdDCLumValues, to: &out)
        appendDHT(tcTh: 0x10, counts: stdACLumCounts, values: stdACLumValues, to: &out)
        appendDHT(tcTh: 0x01, counts: stdDCChrCounts, values: stdDCChrValues, to: &out)
        appendDHT(tcTh: 0x11, counts: stdACChrCounts, values: stdACChrValues, to: &out)
        appendSOF(marker: 0xC0, width: width, height: height, comps: comps, to: &out)

        let dcLum = HuffmanEncoder(counts: stdDCLumCounts, values: stdDCLumValues)
        let acLum = HuffmanEncoder(counts: stdACLumCounts, values: stdACLumValues)
        let dcChr = HuffmanEncoder(counts: stdDCChrCounts, values: stdDCChrValues)
        let acChr = HuffmanEncoder(counts: stdACChrCounts, values: stdACChrValues)

        for c in 0..<3 {
            let tdTa: UInt8 = c == 0 ? 0x00 : 0x11
            appendSegment(0xFF, 0xDA, payload: [1, UInt8(c + 1), tdTa, 0, 63, 0], to: &out)
            var bw = JPEGBitWriter()
            var dcPred = 0
            let dcEnc = c == 0 ? dcLum : dcChr
            let acEnc = c == 0 ? acLum : acChr
            for blk in planeBlocks[c] {
                encodeSequentialBlock(blk, dcPred: &dcPred, dcEnc: dcEnc, acEnc: acEnc, bw: &bw)
            }
            out.append(contentsOf: bw.finish())
        }
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    static func encodeProgressiveRGB(
        width: Int,
        height: Int,
        rgb: [UInt8],
        subsampling: Subsampling
    ) -> [UInt8] {
        let (comps, planeBlocks) = prepareYCbCrBlocks(
            width: width,
            height: height,
            rgb: rgb,
            subsampling: subsampling
        )

        var out: [UInt8] = [0xFF, 0xD8]
        appendDQT(id: 0, quantZZ: lumQuantZigzag, to: &out)
        appendDQT(id: 1, quantZZ: chrQuantZigzag, to: &out)
        appendDHT(tcTh: 0x00, counts: stdDCLumCounts, values: stdDCLumValues, to: &out)
        appendDHT(tcTh: 0x10, counts: stdACLumCounts, values: stdACLumValues, to: &out)
        appendDHT(tcTh: 0x01, counts: stdDCChrCounts, values: stdDCChrValues, to: &out)
        appendDHT(tcTh: 0x11, counts: stdACChrCounts, values: stdACChrValues, to: &out)
        appendSOF(marker: 0xC2, width: width, height: height, comps: comps, to: &out)

        let dcLum = HuffmanEncoder(counts: stdDCLumCounts, values: stdDCLumValues)
        let acLum = HuffmanEncoder(counts: stdACLumCounts, values: stdACLumValues)
        let dcChr = HuffmanEncoder(counts: stdDCChrCounts, values: stdDCChrValues)
        let acChr = HuffmanEncoder(counts: stdACChrCounts, values: stdACChrValues)

        let maxH = comps.map { Int($0.1) }.max() ?? 1
        let maxV = comps.map { Int($0.2) }.max() ?? 1
        let mcuCols = (width + maxH * 8 - 1) / (maxH * 8)
        let mcuRows = (height + maxV * 8 - 1) / (maxV * 8)

        // Scan 1: DC first visit (Ah=0, Al=1) intercalado
        appendSegment(0xFF, 0xDA, payload: [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 0, 0x01], to: &out)
        do {
            var bw = JPEGBitWriter()
            var dcPred = [0, 0, 0]
            for my in 0..<mcuRows {
                for mx in 0..<mcuCols {
                    for c in 0..<3 {
                        let h = Int(comps[c].1)
                        let v = Int(comps[c].2)
                        let stride = mcuCols * h
                        let dcEnc = c == 0 ? dcLum : dcChr
                        for dy in 0..<v {
                            for dx in 0..<h {
                                let dcVal = planeBlocks[c][(my * v + dy) * stride + (mx * h + dx)][0] >> 1
                                let diff = dcVal - dcPred[c]
                                dcPred[c] = dcVal
                                let (cat, bits) = encodeVLI(diff)
                                dcEnc.write(symbol: cat, to: &bw)
                                bw.writeBits(bits, count: cat)
                            }
                        }
                    }
                }
            }
            out.append(contentsOf: bw.finish())
        }

        // Scan 2: DC refinement (Ah=1, Al=0) intercalado
        appendSegment(0xFF, 0xDA, payload: [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 0, 0x10], to: &out)
        do {
            var bw = JPEGBitWriter()
            for my in 0..<mcuRows {
                for mx in 0..<mcuCols {
                    for c in 0..<3 {
                        let h = Int(comps[c].1)
                        let v = Int(comps[c].2)
                        let stride = mcuCols * h
                        for dy in 0..<v {
                            for dx in 0..<h {
                                let dcVal = planeBlocks[c][(my * v + dy) * stride + (mx * h + dx)][0]
                                bw.writeBits(dcVal & 1, count: 1)
                            }
                        }
                    }
                }
            }
            out.append(contentsOf: bw.finish())
        }

        // Scans AC por componente: Ss=1..15 (Ah=0, Al=1), refinamento (Ah=1, Al=0), e Ss=16..63 (Ah=0, Al=0).
        for c in 0..<3 {
            let h = Int(comps[c].1)
            let v = Int(comps[c].2)
            let compW = (width * h + maxH - 1) / maxH
            let compH = (height * v + maxV - 1) / maxV
            let compBX = (compW + 7) / 8
            let compBY = (compH + 7) / 8
            let stride = mcuCols * h
            let acEnc = c == 0 ? acLum : acChr
            let tdTa: UInt8 = c == 0 ? 0x00 : 0x11

            // AC first Ss=1..15, Al=1
            appendSegment(0xFF, 0xDA, payload: [1, UInt8(c + 1), tdTa, 1, 15, 0x01], to: &out)
            do {
                var bw = JPEGBitWriter()
                for by in 0..<compBY {
                    for bx in 0..<compBX {
                        let blk = planeBlocks[c][by * stride + bx]
                        encodeACFirst(blk: blk, ss: 1, se: 15, al: 1, acEnc: acEnc, bw: &bw)
                    }
                }
                out.append(contentsOf: bw.finish())
            }

            // AC refine Ss=1..15, Ah=1, Al=0
            appendSegment(0xFF, 0xDA, payload: [1, UInt8(c + 1), tdTa, 1, 15, 0x10], to: &out)
            do {
                var bw = JPEGBitWriter()
                for by in 0..<compBY {
                    for bx in 0..<compBX {
                        let blk = planeBlocks[c][by * stride + bx]
                        encodeACRefine(blk: blk, ss: 1, se: 15, al: 0, acEnc: acEnc, bw: &bw)
                    }
                }
                out.append(contentsOf: bw.finish())
            }

            // AC full Ss=16..63, Ah=0, Al=0
            appendSegment(0xFF, 0xDA, payload: [1, UInt8(c + 1), tdTa, 16, 63, 0x00], to: &out)
            do {
                var bw = JPEGBitWriter()
                for by in 0..<compBY {
                    for bx in 0..<compBX {
                        let blk = planeBlocks[c][by * stride + bx]
                        encodeACFirst(blk: blk, ss: 16, se: 63, al: 0, acEnc: acEnc, bw: &bw)
                    }
                }
                out.append(contentsOf: bw.finish())
            }
        }

        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    // MARK: - Helpers internos de codificação

    private static func prepareYCbCrBlocks(
        width: Int,
        height: Int,
        rgb: [UInt8],
        subsampling: Subsampling
    ) -> ([(UInt8, UInt8, UInt8, UInt8)], [[[Int]]]) {
        let (h0, v0, h1, v1): (Int, Int, Int, Int)
        switch subsampling {
        case .ycbcr444: (h0, v0, h1, v1) = (1, 1, 1, 1)
        case .ycbcr422: (h0, v0, h1, v1) = (2, 1, 1, 1)
        case .ycbcr420: (h0, v0, h1, v1) = (2, 2, 1, 1)
        }
        let maxH = h0
        let maxV = v0
        let mcuCols = (width + maxH * 8 - 1) / (maxH * 8)
        let mcuRows = (height + maxV * 8 - 1) / (maxV * 8)

        var yPlane = [UInt8](repeating: 0, count: width * height)
        var cbFull = [UInt8](repeating: 0, count: width * height)
        var crFull = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Double(rgb[i * 3])
            let g = Double(rgb[i * 3 + 1])
            let b = Double(rgb[i * 3 + 2])
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            let cb = 128.0 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 128.0 + 0.5 * r - 0.418688 * g - 0.081312 * b
            yPlane[i] = UInt8(max(0, min(255, Int(y.rounded()))))
            cbFull[i] = UInt8(max(0, min(255, Int(cb.rounded()))))
            crFull[i] = UInt8(max(0, min(255, Int(cr.rounded()))))
        }

        let subW = (width * h1 + maxH - 1) / maxH
        let subH = (height * v1 + maxV - 1) / maxV
        var cbSub = [UInt8](repeating: 0, count: subW * subH)
        var crSub = [UInt8](repeating: 0, count: subW * subH)
        for sy in 0..<subH {
            for sx in 0..<subW {
                var sumCb = 0
                var sumCr = 0
                var count = 0
                for dy in 0..<maxV {
                    let py = min(height - 1, sy * maxV + dy)
                    for dx in 0..<maxH {
                        let px = min(width - 1, sx * maxH + dx)
                        sumCb += Int(cbFull[py * width + px])
                        sumCr += Int(crFull[py * width + px])
                        count += 1
                    }
                }
                cbSub[sy * subW + sx] = UInt8(sumCb / count)
                crSub[sy * subW + sx] = UInt8(sumCr / count)
            }
        }

        let yBlocks = encodeComponentBlocks(
            plane: yPlane,
            planeW: width,
            planeH: height,
            mcuCols: mcuCols,
            mcuRows: mcuRows,
            h: h0,
            v: v0,
            quantZZ: lumQuantZigzag
        )
        let cbBlocks = encodeComponentBlocks(
            plane: cbSub,
            planeW: subW,
            planeH: subH,
            mcuCols: mcuCols,
            mcuRows: mcuRows,
            h: h1,
            v: v1,
            quantZZ: chrQuantZigzag
        )
        let crBlocks = encodeComponentBlocks(
            plane: crSub,
            planeW: subW,
            planeH: subH,
            mcuCols: mcuCols,
            mcuRows: mcuRows,
            h: h1,
            v: v1,
            quantZZ: chrQuantZigzag
        )

        let comps: [(UInt8, UInt8, UInt8, UInt8)] = [
            (1, UInt8(h0), UInt8(v0), 0),
            (2, UInt8(h1), UInt8(v1), 1),
            (3, UInt8(h1), UInt8(v1), 1),
        ]
        return (comps, [yBlocks, cbBlocks, crBlocks])
    }

    private static func encodeComponentBlocks(
        plane: [UInt8],
        planeW: Int,
        planeH: Int,
        mcuCols: Int,
        mcuRows: Int,
        h: Int,
        v: Int,
        quantZZ: [Int]
    ) -> [[Int]] {
        let bxTotal = mcuCols * h
        let byTotal = mcuRows * v
        var blocks: [[Int]] = []
        blocks.reserveCapacity(bxTotal * byTotal)

        for by in 0..<byTotal {
            for bx in 0..<bxTotal {
                var samples = [Double](repeating: 0, count: 64)
                for y in 0..<8 {
                    let py = min(planeH - 1, by * 8 + y)
                    for x in 0..<8 {
                        let px = min(planeW - 1, bx * 8 + x)
                        samples[y * 8 + x] = Double(plane[py * planeW + px]) - 128.0
                    }
                }
                let dct = fdct8x8(samples)
                var zz = [Int](repeating: 0, count: 64)
                for i in 0..<64 {
                    let nat = zigzagToNatural[i]
                    let q = Double(quantZZ[i])
                    zz[i] = Int((dct[nat] / q).rounded())
                }
                blocks.append(zz)
            }
        }
        return blocks
    }

    private static func fdct8x8(_ samples: [Double]) -> [Double] {
        // Tabela de cossenos pré-computada
        let piOver16 = Double.pi / 16.0
        var temp = [Double](repeating: 0, count: 64)
        for y in 0..<8 {
            for u in 0..<8 {
                let cu = u == 0 ? 0.7071067811865475 : 1.0
                var sum = 0.0
                for x in 0..<8 {
                    sum += samples[y * 8 + x] * cosApprox((2 * x + 1) * u, piOver16)
                }
                temp[y * 8 + u] = 0.5 * cu * sum
            }
        }
        var out = [Double](repeating: 0, count: 64)
        for v in 0..<8 {
            let cv = v == 0 ? 0.7071067811865475 : 1.0
            for u in 0..<8 {
                var sum = 0.0
                for y in 0..<8 {
                    sum += temp[y * 8 + u] * cosApprox((2 * y + 1) * v, piOver16)
                }
                out[v * 8 + u] = 0.5 * cv * sum
            }
        }
        return out
    }

    private static func cosApprox(_ k: Int, _ step: Double) -> Double {
        // Série de Taylor sobre módulo 2π para evitar importar Darwin/Glibc nos testes.
        let twoPi = 2.0 * Double.pi
        var x = (Double(k) * step).truncatingRemainder(dividingBy: twoPi)
        if x < 0 { x += twoPi }
        if x > Double.pi { x = twoPi - x }
        var sign = 1.0
        if x > Double.pi / 2.0 {
            x = Double.pi - x
            sign = -1.0
        }
        let x2 = x * x
        var term = 1.0
        var sum = 1.0
        for n in 1...10 {
            term *= -x2 / Double((2 * n - 1) * (2 * n))
            sum += term
        }
        return sign * sum
    }

    private static func encodeSequentialBlock(
        _ zz: [Int],
        dcPred: inout Int,
        dcEnc: HuffmanEncoder,
        acEnc: HuffmanEncoder,
        bw: inout JPEGBitWriter
    ) {
        let diff = zz[0] - dcPred
        dcPred = zz[0]
        let (dcCat, dcBits) = encodeVLI(diff)
        dcEnc.write(symbol: dcCat, to: &bw)
        bw.writeBits(dcBits, count: dcCat)

        var lastNonZero = 0
        for k in stride(from: 63, through: 1, by: -1) where zz[k] != 0 {
            lastNonZero = k
            break
        }
        if lastNonZero == 0 {
            acEnc.write(symbol: 0x00, to: &bw)
            return
        }

        var zeroRun = 0
        for k in 1...lastNonZero {
            if zz[k] == 0 {
                zeroRun += 1
            } else {
                while zeroRun >= 16 {
                    acEnc.write(symbol: 0xF0, to: &bw)
                    zeroRun -= 16
                }
                let (cat, bits) = encodeVLI(zz[k])
                acEnc.write(symbol: (zeroRun << 4) | cat, to: &bw)
                bw.writeBits(bits, count: cat)
                zeroRun = 0
            }
        }
        if lastNonZero < 63 {
            acEnc.write(symbol: 0x00, to: &bw)
        }
    }

    private static func encodeACFirst(
        blk: [Int],
        ss: Int,
        se: Int,
        al: Int,
        acEnc: HuffmanEncoder,
        bw: inout JPEGBitWriter
    ) {
        var lastNonZero = ss - 1
        for k in stride(from: se, through: ss, by: -1) {
            let v = blk[k] >= 0 ? (blk[k] >> al) : -((-blk[k]) >> al)
            if v != 0 {
                lastNonZero = k
                break
            }
        }
        if lastNonZero < ss {
            acEnc.write(symbol: 0x00, to: &bw)
            return
        }

        var zeroRun = 0
        for k in ss...lastNonZero {
            let v = blk[k] >= 0 ? (blk[k] >> al) : -((-blk[k]) >> al)
            if v == 0 {
                zeroRun += 1
            } else {
                while zeroRun >= 16 {
                    acEnc.write(symbol: 0xF0, to: &bw)
                    zeroRun -= 16
                }
                let (cat, bits) = encodeVLI(v)
                acEnc.write(symbol: (zeroRun << 4) | cat, to: &bw)
                bw.writeBits(bits, count: cat)
                zeroRun = 0
            }
        }
        if lastNonZero < se {
            acEnc.write(symbol: 0x00, to: &bw)
        }
    }

    private static func encodeACRefine(
        blk: [Int],
        ss: Int,
        se: Int,
        al: Int,
        acEnc: HuffmanEncoder,
        bw: inout JPEGBitWriter
    ) {
        let ah = al + 1
        var eobFrom = se + 1
        for k in stride(from: se, through: ss, by: -1) {
            let prev = blk[k] >= 0 ? (blk[k] >> ah) : -((-blk[k]) >> ah)
            let curr = blk[k] >= 0 ? (blk[k] >> al) : -((-blk[k]) >> al)
            if prev == 0 && curr != 0 {
                eobFrom = k + 1
                break
            }
        }

        var zeroRun = 0
        var pendingBits: [Int] = []
        for k in ss...se {
            let prev = blk[k] >= 0 ? (blk[k] >> ah) : -((-blk[k]) >> ah)
            let curr = blk[k] >= 0 ? (blk[k] >> al) : -((-blk[k]) >> al)

            if prev != 0 {
                let absCurr = abs(curr)
                pendingBits.append(absCurr & 1)
            } else if curr != 0 {
                while zeroRun >= 16 {
                    acEnc.write(symbol: 0xF0, to: &bw)
                    for b in pendingBits { bw.writeBits(b, count: 1) }
                    pendingBits.removeAll()
                    zeroRun -= 16
                }
                acEnc.write(symbol: (zeroRun << 4) | 1, to: &bw)
                bw.writeBits(curr > 0 ? 1 : 0, count: 1)
                for b in pendingBits { bw.writeBits(b, count: 1) }
                pendingBits.removeAll()
                zeroRun = 0
            } else {
                if k >= eobFrom {
                    break
                }
                zeroRun += 1
            }
        }

        if eobFrom <= se || zeroRun > 0 {
            if eobFrom <= se {
                // Restam coeficientes não-zeros em eobFrom...se após a última nova entrada
                var tailBits: [Int] = []
                for k in eobFrom...se {
                    let prev = blk[k] >= 0 ? (blk[k] >> ah) : -((-blk[k]) >> ah)
                    let curr = blk[k] >= 0 ? (blk[k] >> al) : -((-blk[k]) >> al)
                    if prev != 0 {
                        tailBits.append(abs(curr) & 1)
                    }
                }
                acEnc.write(symbol: 0x00, to: &bw)
                for b in tailBits { bw.writeBits(b, count: 1) }
            } else if zeroRun > 0 || !pendingBits.isEmpty {
                acEnc.write(symbol: 0x00, to: &bw)
                for b in pendingBits { bw.writeBits(b, count: 1) }
            }
        }
    }

    private static func encodeVLI(_ value: Int) -> (category: Int, bits: Int) {
        if value == 0 { return (0, 0) }
        let mag = abs(value)
        let cat = Int.bitWidth - mag.leadingZeroBitCount
        let bits = value > 0 ? value : (value + (1 << cat) - 1)
        return (cat, bits)
    }

    private static func appendSegment(_ ff: UInt8, _ marker: UInt8, payload: [UInt8], to out: inout [UInt8]) {
        let len = UInt16(payload.count + 2)
        out.append(ff)
        out.append(marker)
        out.append(UInt8(len >> 8))
        out.append(UInt8(len & 0xFF))
        out.append(contentsOf: payload)
    }

    private static func appendDQT(id: UInt8, quantZZ: [Int], to out: inout [UInt8]) {
        var payload: [UInt8] = [id]
        for q in quantZZ { payload.append(UInt8(q)) }
        appendSegment(0xFF, 0xDB, payload: payload, to: &out)
    }

    private static func appendDHT(tcTh: UInt8, counts: [UInt8], values: [UInt8], to out: inout [UInt8]) {
        var payload: [UInt8] = [tcTh]
        payload.append(contentsOf: counts)
        payload.append(contentsOf: values)
        appendSegment(0xFF, 0xC4, payload: payload, to: &out)
    }

    private static func appendSOF(
        marker: UInt8,
        width: Int,
        height: Int,
        comps: [(UInt8, UInt8, UInt8, UInt8)],
        to out: inout [UInt8]
    ) {
        var payload: [UInt8] = [
            8,
            UInt8(height >> 8), UInt8(height & 0xFF),
            UInt8(width >> 8), UInt8(width & 0xFF),
            UInt8(comps.count),
        ]
        for (id, h, v, tq) in comps {
            payload.append(id)
            payload.append((h << 4) | v)
            payload.append(tq)
        }
        appendSegment(0xFF, marker, payload: payload, to: &out)
    }

    private static func appendEXIF(orientation: UInt8, to out: inout [UInt8]) {
        let tiff: [UInt8] = [
            0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x01, 0x00,
            0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, orientation, 0x00, 0x00, 0x00,
        ]
        let payload = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] + tiff
        appendSegment(0xFF, 0xE1, payload: payload, to: &out)
    }

    private struct HuffmanEncoder {
        private var codes = [Int](repeating: 0, count: 256)
        private var lengths = [Int](repeating: 0, count: 256)

        init(counts: [UInt8], values: [UInt8]) {
            var code = 0
            var k = 0
            for len in 1...16 {
                let c = Int(counts[len - 1])
                for _ in 0..<c {
                    let sym = Int(values[k])
                    codes[sym] = code
                    lengths[sym] = len
                    code += 1
                    k += 1
                }
                code <<= 1
            }
        }

        func write(symbol: Int, to bw: inout JPEGBitWriter) {
            bw.writeBits(codes[symbol], count: lengths[symbol])
        }
    }

    private struct JPEGBitWriter {
        private var bytes: [UInt8] = []
        private var bitBuf = 0
        private var bitCount = 0

        mutating func writeBits(_ value: Int, count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) {
                bitBuf = (bitBuf << 1) | ((value >> i) & 1)
                bitCount += 1
                if bitCount == 8 {
                    let byte = UInt8(bitBuf & 0xFF)
                    bytes.append(byte)
                    if byte == 0xFF { bytes.append(0x00) }
                    bitBuf = 0
                    bitCount = 0
                }
            }
        }

        mutating func finish() -> [UInt8] {
            if bitCount > 0 {
                let pad = 8 - bitCount
                writeBits((1 << pad) - 1, count: pad)
            }
            return bytes
        }
    }
}
