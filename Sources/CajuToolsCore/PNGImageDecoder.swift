/// Imagem RGBA8 decodificada para entrada do pipeline de texturas.
public struct DecodedRGBAImage: Sendable, Equatable {
    /// Largura da imagem em pixels.
    public let width: Int
    /// Altura da imagem em pixels.
    public let height: Int
    /// Pixels em ordem RGBA8 (`width * height * 4` bytes, sem pré-multiplicação).
    public let pixels: [UInt8]
}

/// Decodificador de imagens de entrada (PNG e PPM P6) para RGBA8 em Swift puro.
public enum ToolsImageDecoder {
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let crcTable: [UInt32] = makeCRCTable()

    private static let adam7XStart = [0, 4, 0, 2, 0, 1, 0]
    private static let adam7YStart = [0, 0, 4, 0, 2, 0, 1]
    private static let adam7XStep = [8, 8, 4, 4, 2, 2, 1]
    private static let adam7YStep = [8, 8, 8, 4, 4, 2, 2]

    /// Decodifica bytes PNG ou PPM P6 para pixels RGBA8 validando limites antes de alocar.
    public static func decode(
        _ bytes: [UInt8],
        limits: ToolsLimits = .default
    ) throws(CajuToolsError) -> DecodedRGBAImage {
        try checkLimit(bytes.count, limits.maxInputBytes, "image.input")
        guard !bytes.isEmpty else {
            throw .truncated(context: "image.input")
        }
        if bytes.count >= 8, Array(bytes[0..<8]) == pngSignature {
            return try decodePNG(bytes, limits: limits)
        }
        if bytes.count >= 2, bytes[0] == 0x50, bytes[1] == 0x36 {
            return try decodePPMP6(bytes, limits: limits)
        }
        throw .unsupported(
            context: "image.format",
            reason: "formato de entrada não suportado (use PNG ou PPM P6)"
        )
    }

    private static func decodePPMP6(
        _ bytes: [UInt8],
        limits: ToolsLimits
    ) throws(CajuToolsError) -> DecodedRGBAImage {
        var idx = 2

        func nextToken() throws(CajuToolsError) -> String {
            while idx < bytes.count {
                let b = bytes[idx]
                if b == 0x23 {  // '#'
                    while idx < bytes.count, bytes[idx] != 0x0A {
                        idx += 1
                    }
                } else if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    idx += 1
                } else {
                    break
                }
            }
            guard idx < bytes.count else {
                throw .truncated(context: "ppm.header")
            }
            let start = idx
            while idx < bytes.count {
                let b = bytes[idx]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x23 {
                    break
                }
                idx += 1
            }
            return String(decoding: bytes[start..<idx], as: UTF8.self)
        }

        let wStr = try nextToken()
        let hStr = try nextToken()
        let maxStr = try nextToken()
        guard let width = Int(wStr), width > 0,
            let height = Int(hStr), height > 0,
            let maxVal = Int(maxStr), maxVal == 255
        else {
            throw .invalid(context: "ppm.header", reason: "dimensões inválidas ou maxval != 255")
        }
        guard idx < bytes.count else {
            throw .truncated(context: "ppm.header")
        }
        let ws = bytes[idx]
        guard ws == 0x20 || ws == 0x09 || ws == 0x0A || ws == 0x0D else {
            throw .invalid(context: "ppm.header", reason: "separador esperado após maxval")
        }
        idx += 1

        try checkLimit(width, limits.maxImageDimension, "ppm.width")
        try checkLimit(height, limits.maxImageDimension, "ppm.height")
        let pixelCount = try checkedMul(width, height, "ppm.size")
        let rgbBytes = try checkedMul(pixelCount, 3, "ppm.rgb")
        let rgbaBytes = try checkedMul(pixelCount, 4, "ppm.rgba")
        try checkLimit(rgbaBytes, limits.maxOutputBytes, "ppm.output")
        guard bytes.count - idx == rgbBytes else {
            if bytes.count - idx < rgbBytes {
                throw .truncated(context: "ppm.pixels")
            }
            throw .invalid(context: "ppm.pixels", reason: "tamanho de pixels diverge do cabeçalho")
        }

        var pixels = [UInt8](repeating: 255, count: rgbaBytes)
        for p in 0..<pixelCount {
            let src = idx + p * 3
            let dst = p * 4
            pixels[dst] = bytes[src]
            pixels[dst + 1] = bytes[src + 1]
            pixels[dst + 2] = bytes[src + 2]
        }
        return DecodedRGBAImage(width: width, height: height, pixels: pixels)
    }

    // MARK: - PNG

    private enum PNGColorType: UInt8 {
        case grayscale = 0
        case rgb = 2
        case indexed = 3
        case grayscaleAlpha = 4
        case rgba = 6
    }

    private struct PNGHeader {
        let width: Int
        let height: Int
        let bitDepth: UInt8
        let colorType: PNGColorType
        let isInterlaced: Bool
    }

    private struct ChunkSlice {
        let name: String
        let type0: UInt8
        let dataStart: Int
        let length: Int
    }

    private struct ColorDecodeState {
        let colorType: PNGColorType
        let bitDepth: Int
        let palette: [UInt8]
        let paletteCount: Int
        let trnsAlpha: [UInt8]
        let trnsGrayKey: UInt16?
        let trnsRGBKey: (UInt16, UInt16, UInt16)?
    }

    private static func decodePNG(
        _ bytes: [UInt8],
        limits: ToolsLimits
    ) throws(CajuToolsError) -> DecodedRGBAImage {
        var reader = ToolsByteReader(bytes)
        try reader.skip(8, context: "png.signature")

        let header = try readIHDR(&reader, bytes: bytes, limits: limits)
        let outputBytes = try checkedMul(
            try checkedMul(header.width, header.height, "png.size"),
            4,
            "png.size"
        )
        try checkLimit(outputBytes, limits.maxOutputBytes, "png.output")
        let expectedDecompressed = try computeExpectedDecompressedSize(header: header)

        var palette: [UInt8] = []
        var paletteCount = 0
        var seenPLTE = false
        var seenTRNS = false
        var trnsAlpha: [UInt8] = []
        var trnsGrayKey: UInt16?
        var trnsRGBKey: (UInt16, UInt16, UInt16)?
        var idatData: [UInt8] = []
        var seenIDAT = false
        var inIDATRun = false
        var seenIEND = false

        while reader.remaining > 0 {
            let chunk = try readChunk(&reader, bytes: bytes)
            switch chunk.name {
            case "IHDR":
                throw .invalid(context: "png.IHDR", reason: "chunk IHDR duplicado")
            case "PLTE":
                inIDATRun = false
                guard !seenIDAT else { throw .invalid(context: "png.PLTE", reason: "PLTE após IDAT") }
                guard !seenPLTE else { throw .invalid(context: "png.PLTE", reason: "PLTE duplicado") }
                guard header.colorType != .grayscale, header.colorType != .grayscaleAlpha else {
                    throw .invalid(context: "png.PLTE", reason: "PLTE proibido para tipo de cor")
                }
                guard chunk.length >= 3, chunk.length <= 768, chunk.length % 3 == 0 else {
                    throw .invalid(context: "png.PLTE", reason: "tamanho de PLTE inválido")
                }
                let entries = chunk.length / 3
                if header.colorType == .indexed {
                    let maxEntries = 1 << Int(header.bitDepth)
                    guard entries <= maxEntries else {
                        throw .invalid(context: "png.PLTE", reason: "PLTE excede 2^bitDepth entradas")
                    }
                }
                palette = Array(bytes[chunk.dataStart..<(chunk.dataStart + chunk.length)])
                paletteCount = entries
                seenPLTE = true
            case "tRNS":
                inIDATRun = false
                guard !seenIDAT else { throw .invalid(context: "png.tRNS", reason: "tRNS após IDAT") }
                guard !seenTRNS else { throw .invalid(context: "png.tRNS", reason: "tRNS duplicado") }
                seenTRNS = true
                let s = chunk.dataStart
                switch header.colorType {
                case .grayscale:
                    guard chunk.length == 2 else {
                        throw .invalid(context: "png.tRNS", reason: "tRNS para cinza deve ter 2 bytes")
                    }
                    trnsGrayKey = (UInt16(bytes[s]) << 8) | UInt16(bytes[s + 1])
                case .rgb:
                    guard chunk.length == 6 else {
                        throw .invalid(context: "png.tRNS", reason: "tRNS para RGB deve ter 6 bytes")
                    }
                    trnsRGBKey = (
                        (UInt16(bytes[s]) << 8) | UInt16(bytes[s + 1]),
                        (UInt16(bytes[s + 2]) << 8) | UInt16(bytes[s + 3]),
                        (UInt16(bytes[s + 4]) << 8) | UInt16(bytes[s + 5])
                    )
                case .indexed:
                    guard seenPLTE else { throw .invalid(context: "png.tRNS", reason: "tRNS antes de PLTE") }
                    guard chunk.length <= paletteCount else {
                        throw .invalid(context: "png.tRNS", reason: "tRNS excede paleta")
                    }
                    trnsAlpha = Array(bytes[s..<(s + chunk.length)])
                case .grayscaleAlpha, .rgba:
                    throw .invalid(context: "png.tRNS", reason: "tRNS proibido para tipo com alfa")
                }
            case "IDAT":
                if seenIDAT && !inIDATRun {
                    throw .invalid(context: "png.IDAT", reason: "chunks IDAT não contíguos")
                }
                if header.colorType == .indexed && !seenPLTE {
                    throw .invalid(context: "png.IDAT", reason: "PLTE ausente antes de IDAT")
                }
                seenIDAT = true
                inIDATRun = true
                let newSum = try checkedAdd(idatData.count, chunk.length, "png.IDAT")
                try checkLimit(newSum, limits.maxInputBytes, "png.IDAT")
                idatData.append(contentsOf: bytes[chunk.dataStart..<(chunk.dataStart + chunk.length)])
            case "IEND":
                guard chunk.length == 0 else {
                    throw .invalid(context: "png.IEND", reason: "IEND deve ter comprimento 0")
                }
                guard seenIDAT else {
                    throw .invalid(context: "png.IEND", reason: "nenhum chunk IDAT encontrado")
                }
                seenIEND = true
            default:
                inIDATRun = false
                if (chunk.type0 & 0x20) == 0 {
                    throw .unsupported(
                        context: "png.chunk(\(chunk.name))",
                        reason: "chunk crítico desconhecido"
                    )
                }
            }
            if seenIEND { break }
        }

        guard seenIEND else {
            throw .truncated(context: "png.IEND")
        }

        let decompressed = try ToolsInflate.zlibDecompress(
            idatData,
            from: 0,
            maxOutput: expectedDecompressed,
            context: "png.IDAT"
        )
        guard decompressed.count == expectedDecompressed else {
            throw .invalid(context: "png.IDAT", reason: "tamanho descomprimido diverge do esperado")
        }

        var pixels = [UInt8](repeating: 0, count: outputBytes)
        let colorState = ColorDecodeState(
            colorType: header.colorType,
            bitDepth: Int(header.bitDepth),
            palette: palette,
            paletteCount: paletteCount,
            trnsAlpha: trnsAlpha,
            trnsGrayKey: trnsGrayKey,
            trnsRGBKey: trnsRGBKey
        )

        if header.isInterlaced {
            var srcOffset = 0
            for pass in 0..<7 {
                let passW = passDimension(
                    full: header.width, start: adam7XStart[pass], step: adam7XStep[pass])
                let passH = passDimension(
                    full: header.height, start: adam7YStart[pass], step: adam7YStep[pass])
                if passW == 0 || passH == 0 { continue }
                srcOffset = try decodePass(
                    decompressed: decompressed,
                    srcOffset: srcOffset,
                    passWidth: passW,
                    passHeight: passH,
                    destWidth: header.width,
                    xStart: adam7XStart[pass],
                    yStart: adam7YStart[pass],
                    xStep: adam7XStep[pass],
                    yStep: adam7YStep[pass],
                    colorState: colorState,
                    into: &pixels
                )
            }
        } else {
            _ = try decodePass(
                decompressed: decompressed,
                srcOffset: 0,
                passWidth: header.width,
                passHeight: header.height,
                destWidth: header.width,
                xStart: 0,
                yStart: 0,
                xStep: 1,
                yStep: 1,
                colorState: colorState,
                into: &pixels
            )
        }

        return DecodedRGBAImage(width: header.width, height: header.height, pixels: pixels)
    }

    private static func readIHDR(
        _ reader: inout ToolsByteReader,
        bytes: [UInt8],
        limits: ToolsLimits
    ) throws(CajuToolsError) -> PNGHeader {
        let chunk = try readChunk(&reader, bytes: bytes)
        guard chunk.name == "IHDR", chunk.length == 13 else {
            throw .invalid(context: "png.IHDR", reason: "IHDR ausente ou inválido")
        }
        let s = chunk.dataStart
        let rawW = readU32BE(bytes, at: s)
        let rawH = readU32BE(bytes, at: s + 4)
        guard rawW > 0, rawW <= 0x7FFF_FFFF, rawH > 0, rawH <= 0x7FFF_FFFF else {
            throw .invalid(context: "png.IHDR", reason: "dimensões PNG inválidas")
        }
        let width = Int(rawW)
        let height = Int(rawH)
        try checkLimit(width, limits.maxImageDimension, "png.width")
        try checkLimit(height, limits.maxImageDimension, "png.height")

        let bitDepth = bytes[s + 8]
        guard let colorType = PNGColorType(rawValue: bytes[s + 9]) else {
            throw .invalid(context: "png.IHDR.colorType", reason: "tipo de cor inválido")
        }
        guard isValidBitDepth(bitDepth, for: colorType) else {
            throw .invalid(context: "png.IHDR.bitDepth", reason: "bitDepth inválido para colorType")
        }
        guard bytes[s + 10] == 0, bytes[s + 11] == 0 else {
            throw .invalid(context: "png.IHDR", reason: "compressão ou filtro inválido")
        }
        let interlace = bytes[s + 12]
        guard interlace == 0 || interlace == 1 else {
            throw .invalid(context: "png.IHDR.interlace", reason: "entrelaçamento inválido")
        }
        return PNGHeader(
            width: width,
            height: height,
            bitDepth: bitDepth,
            colorType: colorType,
            isInterlaced: interlace == 1
        )
    }

    private static func readChunk(
        _ reader: inout ToolsByteReader,
        bytes: [UInt8]
    ) throws(CajuToolsError) -> ChunkSlice {
        let rawLength = try reader.readU32BE("png.chunk.length")
        guard rawLength <= 0x7FFF_FFFF else {
            throw .invalid(context: "png.chunk.length", reason: "comprimento excede 2^31-1")
        }
        let length = Int(rawLength)
        let typeOffset = reader.offset
        let t0 = try reader.readU8("png.chunk.type")
        let t1 = try reader.readU8("png.chunk.type")
        let t2 = try reader.readU8("png.chunk.type")
        let t3 = try reader.readU8("png.chunk.type")
        guard isASCIILetter(t0), isASCIILetter(t1), isASCIILetter(t2), isASCIILetter(t3) else {
            throw .invalid(context: "png.chunk.type", reason: "nome de chunk inválido")
        }
        let name = String(decoding: [t0, t1, t2, t3], as: UTF8.self)
        let needed = try checkedAdd(length, 4, "png.chunk(\(name))")
        guard reader.remaining >= needed else {
            throw .truncated(context: "png.chunk(\(name))")
        }
        let dataStart = reader.offset
        try reader.skip(length, context: "png.chunk(\(name))")
        let expectedCRC = try reader.readU32BE("png.chunk(\(name)).crc")
        guard crc32(bytes, start: typeOffset, count: 4 + length) == expectedCRC else {
            throw .invalid(context: "png.chunk(\(name))", reason: "CRC-32 inválido")
        }
        return ChunkSlice(name: name, type0: t0, dataStart: dataStart, length: length)
    }

    private static func computeExpectedDecompressedSize(header: PNGHeader) throws(CajuToolsError) -> Int {
        let bppBits = bitsPerPixel(colorType: header.colorType, bitDepth: Int(header.bitDepth))
        if !header.isInterlaced {
            let rowData = try scanlineDataBytes(width: header.width, bppBits: bppBits)
            let rowTotal = try checkedAdd(1, rowData, "png.scanline")
            return try checkedMul(rowTotal, header.height, "png.decompressedSize")
        }
        var total = 0
        for pass in 0..<7 {
            let passW = passDimension(full: header.width, start: adam7XStart[pass], step: adam7XStep[pass])
            let passH = passDimension(full: header.height, start: adam7YStart[pass], step: adam7YStep[pass])
            if passW > 0 && passH > 0 {
                let rowData = try scanlineDataBytes(width: passW, bppBits: bppBits)
                let rowTotal = try checkedAdd(1, rowData, "png.adam7.scanline")
                let passBytes = try checkedMul(rowTotal, passH, "png.adam7.pass")
                total = try checkedAdd(total, passBytes, "png.decompressedSize")
            }
        }
        return total
    }

    private static func decodePass(
        decompressed: [UInt8],
        srcOffset startOffset: Int,
        passWidth: Int,
        passHeight: Int,
        destWidth: Int,
        xStart: Int,
        yStart: Int,
        xStep: Int,
        yStep: Int,
        colorState: ColorDecodeState,
        into pixels: inout [UInt8]
    ) throws(CajuToolsError) -> Int {
        let bppBits = bitsPerPixel(colorType: colorState.colorType, bitDepth: colorState.bitDepth)
        let rowBytes = try scanlineDataBytes(width: passWidth, bppBits: bppBits)
        let filterBpp = max(1, (bppBits + 7) / 8)
        var prevRow = [UInt8](repeating: 0, count: rowBytes)
        var currRow = [UInt8](repeating: 0, count: rowBytes)
        var offset = startOffset

        for py in 0..<passHeight {
            guard offset < decompressed.count else { throw .truncated(context: "png.scanline") }
            let filterType = decompressed[offset]
            offset += 1
            guard offset + rowBytes <= decompressed.count else {
                throw .truncated(context: "png.scanline")
            }
            try unfilterRow(
                filterType: filterType,
                src: decompressed,
                srcStart: offset,
                prev: prevRow,
                curr: &currRow,
                rowBytes: rowBytes,
                bpp: filterBpp
            )
            offset += rowBytes

            try writeScanlinePixels(
                currRow: currRow,
                passWidth: passWidth,
                destWidth: destWidth,
                xStart: xStart,
                xStep: xStep,
                destY: yStart + py * yStep,
                colorState: colorState,
                into: &pixels
            )
            swap(&prevRow, &currRow)
        }
        return offset
    }

    private static func unfilterRow(
        filterType: UInt8,
        src: [UInt8],
        srcStart: Int,
        prev: [UInt8],
        curr: inout [UInt8],
        rowBytes: Int,
        bpp: Int
    ) throws(CajuToolsError) {
        switch filterType {
        case 0:
            for i in 0..<rowBytes { curr[i] = src[srcStart + i] }
        case 1:
            for i in 0..<rowBytes {
                let a: UInt8 = i >= bpp ? curr[i - bpp] : 0
                curr[i] = src[srcStart + i] &+ a
            }
        case 2:
            for i in 0..<rowBytes { curr[i] = src[srcStart + i] &+ prev[i] }
        case 3:
            for i in 0..<rowBytes {
                let a = i >= bpp ? Int(curr[i - bpp]) : 0
                curr[i] = src[srcStart + i] &+ UInt8((a + Int(prev[i])) >> 1)
            }
        case 4:
            for i in 0..<rowBytes {
                let a = i >= bpp ? Int(curr[i - bpp]) : 0
                let b = Int(prev[i])
                let c = i >= bpp ? Int(prev[i - bpp]) : 0
                curr[i] = src[srcStart + i] &+ UInt8(paeth(a: a, b: b, c: c))
            }
        default:
            throw .invalid(context: "png.scanline.filter", reason: "tipo de filtro PNG inválido")
        }
    }

    @inline(__always)
    private static func paeth(a: Int, b: Int, c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    private static func writeScanlinePixels(
        currRow: [UInt8],
        passWidth: Int,
        destWidth: Int,
        xStart: Int,
        xStep: Int,
        destY: Int,
        colorState: ColorDecodeState,
        into pixels: inout [UInt8]
    ) throws(CajuToolsError) {
        let rowBase = destY * destWidth
        let bitDepth = colorState.bitDepth

        switch colorState.colorType {
        case .grayscale:
            for px in 0..<passWidth {
                let dst = (rowBase + xStart + px * xStep) * 4
                let gray8: UInt8
                let rawSample: UInt16
                if bitDepth < 8 {
                    let s = extractSubByteSample(row: currRow, x: px, bitDepth: bitDepth)
                    rawSample = UInt16(s)
                    gray8 = scaleSubByteGray(sample: s, bitDepth: bitDepth)
                } else if bitDepth == 8 {
                    gray8 = currRow[px]
                    rawSample = UInt16(gray8)
                } else {
                    gray8 = currRow[2 * px]
                    rawSample = (UInt16(gray8) << 8) | UInt16(currRow[2 * px + 1])
                }
                pixels[dst] = gray8
                pixels[dst + 1] = gray8
                pixels[dst + 2] = gray8
                pixels[dst + 3] = colorState.trnsGrayKey == rawSample ? 0 : 255
            }
        case .rgb:
            for px in 0..<passWidth {
                let dst = (rowBase + xStart + px * xStep) * 4
                let r: UInt8
                let g: UInt8
                let b: UInt8
                let alpha: UInt8
                if bitDepth == 8 {
                    let base = 3 * px
                    r = currRow[base]
                    g = currRow[base + 1]
                    b = currRow[base + 2]
                    if let k = colorState.trnsRGBKey, k.0 == UInt16(r), k.1 == UInt16(g), k.2 == UInt16(b) {
                        alpha = 0
                    } else {
                        alpha = 255
                    }
                } else {
                    let base = 6 * px
                    r = currRow[base]
                    g = currRow[base + 2]
                    b = currRow[base + 4]
                    let r16 = (UInt16(r) << 8) | UInt16(currRow[base + 1])
                    let g16 = (UInt16(g) << 8) | UInt16(currRow[base + 3])
                    let b16 = (UInt16(b) << 8) | UInt16(currRow[base + 5])
                    if let k = colorState.trnsRGBKey, k.0 == r16, k.1 == g16, k.2 == b16 {
                        alpha = 0
                    } else {
                        alpha = 255
                    }
                }
                pixels[dst] = r
                pixels[dst + 1] = g
                pixels[dst + 2] = b
                pixels[dst + 3] = alpha
            }
        case .indexed:
            for px in 0..<passWidth {
                let idx =
                    bitDepth < 8
                    ? extractSubByteSample(row: currRow, x: px, bitDepth: bitDepth)
                    : Int(currRow[px])
                guard idx < colorState.paletteCount else {
                    throw .invalid(context: "png.pixels", reason: "índice de paleta fora dos limites")
                }
                let pBase = 3 * idx
                let dst = (rowBase + xStart + px * xStep) * 4
                pixels[dst] = colorState.palette[pBase]
                pixels[dst + 1] = colorState.palette[pBase + 1]
                pixels[dst + 2] = colorState.palette[pBase + 2]
                pixels[dst + 3] = idx < colorState.trnsAlpha.count ? colorState.trnsAlpha[idx] : 255
            }
        case .grayscaleAlpha:
            for px in 0..<passWidth {
                let dst = (rowBase + xStart + px * xStep) * 4
                let gray = bitDepth == 8 ? currRow[2 * px] : currRow[4 * px]
                let alpha = bitDepth == 8 ? currRow[2 * px + 1] : currRow[4 * px + 2]
                pixels[dst] = gray
                pixels[dst + 1] = gray
                pixels[dst + 2] = gray
                pixels[dst + 3] = alpha
            }
        case .rgba:
            for px in 0..<passWidth {
                let dst = (rowBase + xStart + px * xStep) * 4
                if bitDepth == 8 {
                    let base = 4 * px
                    pixels[dst] = currRow[base]
                    pixels[dst + 1] = currRow[base + 1]
                    pixels[dst + 2] = currRow[base + 2]
                    pixels[dst + 3] = currRow[base + 3]
                } else {
                    let base = 8 * px
                    pixels[dst] = currRow[base]
                    pixels[dst + 1] = currRow[base + 2]
                    pixels[dst + 2] = currRow[base + 4]
                    pixels[dst + 3] = currRow[base + 6]
                }
            }
        }
    }

    @inline(__always)
    private static func extractSubByteSample(row: [UInt8], x: Int, bitDepth: Int) -> Int {
        let perByte = 8 / bitDepth
        let byteVal = row[x / perByte]
        let shift = (perByte - 1 - (x % perByte)) * bitDepth
        let mask = UInt8((1 << bitDepth) - 1)
        return Int((byteVal >> shift) & mask)
    }

    @inline(__always)
    private static func scaleSubByteGray(sample: Int, bitDepth: Int) -> UInt8 {
        switch bitDepth {
        case 1: sample == 0 ? 0 : 255
        case 2: UInt8(sample * 85)
        case 4: UInt8(sample * 17)
        default: UInt8(sample)
        }
    }

    private static func isValidBitDepth(_ bitDepth: UInt8, for colorType: PNGColorType) -> Bool {
        switch colorType {
        case .grayscale: bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8 || bitDepth == 16
        case .rgb, .grayscaleAlpha, .rgba: bitDepth == 8 || bitDepth == 16
        case .indexed: bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8
        }
    }

    private static func bitsPerPixel(colorType: PNGColorType, bitDepth: Int) -> Int {
        switch colorType {
        case .grayscale, .indexed: bitDepth
        case .grayscaleAlpha: 2 * bitDepth
        case .rgb: 3 * bitDepth
        case .rgba: 4 * bitDepth
        }
    }

    private static func scanlineDataBytes(width: Int, bppBits: Int) throws(CajuToolsError) -> Int {
        let totalBits = try checkedMul(width, bppBits, "png.scanline")
        let padded = try checkedAdd(totalBits, 7, "png.scanline")
        return padded / 8
    }

    private static func passDimension(full: Int, start: Int, step: Int) -> Int {
        guard full > start else { return 0 }
        return (full - start + step - 1) / step
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private static func readU32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func crc32(_ bytes: [UInt8], start: Int, count: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for i in start..<(start + count) {
            let idx = Int((crc ^ UInt32(bytes[i])) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func makeCRCTable() -> [UInt32] {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }
}
