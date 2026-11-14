/// Tipo de cor de uma imagem PNG (IHDR byte 9).
public enum PNGColorType: UInt8, Sendable, Equatable {
    /// Escala de cinza (1 canal; profundidades 1, 2, 4, 8, 16).
    case grayscale = 0
    /// RGB verdadeiro (3 canais; profundidades 8, 16).
    case rgb = 2
    /// Paleta indexada via chunk `PLTE` (profundidades 1, 2, 4, 8).
    case indexed = 3
    /// Escala de cinza com alfa (2 canais; profundidades 8, 16).
    case grayscaleAlpha = 4
    /// RGBA verdadeiro (4 canais; profundidades 8, 16).
    case rgba = 6
}

/// Metadados do cabeçalho `IHDR` de uma imagem PNG.
///
/// ```swift
/// let info = try PNGDecoder.readInfo(bytes)
/// print(info.width, info.height)
/// ```
public struct PNGInfo: Sendable, Equatable {
    /// Largura da imagem em pixels.
    public let width: Int
    /// Altura da imagem em pixels.
    public let height: Int
    /// Profundidade de bits por amostra (1, 2, 4, 8 ou 16).
    public let bitDepth: UInt8
    /// Tipo de cor PNG.
    public let colorType: PNGColorType
    /// Indica se a imagem usa entrelaçamento Adam7.
    public let isInterlaced: Bool

    /// Cria uma instância de metadados PNG.
    public init(
        width: Int,
        height: Int,
        bitDepth: UInt8,
        colorType: PNGColorType,
        isInterlaced: Bool
    ) {
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.colorType = colorType
        self.isInterlaced = isInterlaced
    }
}

/// Imagem PNG decodificada em pixels RGBA8 (não pré-multiplicados).
///
/// Canais originalmente em 16 bits são reduzidos para 8 bits preservando o byte alto (`valor >> 8`).
///
/// ```swift
/// let image = try PNGDecoder.decode(bytes)
/// // image.pixels.count == image.width * image.height * 4
/// ```
public struct PNGImage: Sendable, Equatable {
    /// Largura da imagem em pixels.
    public let width: Int
    /// Altura da imagem em pixels.
    public let height: Int
    /// Pixels em ordem de varredura RGBA8 (`width * height * 4` bytes, sem pré-multiplicação).
    public let pixels: [UInt8]

    /// Cria uma imagem PNG decodificada.
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Decodificador PNG puro em Swift (sem `Foundation`).
///
/// Suporta todos os tipos de cor (0, 2, 3, 4, 6), profundidades válidas (1, 2, 4, 8, 16),
/// chunks `PLTE` e `tRNS`, filtros 0..4 e entrelaçamento Adam7.
/// Canais de 16 bits são reduzidos para 8 bits pelo byte mais significativo (byte alto).
///
/// ```swift
/// let info = try PNGDecoder.readInfo(bytes)
/// let image = try PNGDecoder.decode(bytes)
/// ```
public enum PNGDecoder {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let crcTable: [UInt32] = makeCRCTable()

    private static let adam7XStart = [0, 4, 0, 2, 0, 1, 0]
    private static let adam7YStart = [0, 0, 4, 0, 2, 0, 1]
    private static let adam7XStep = [8, 8, 4, 4, 2, 2, 1]
    private static let adam7YStep = [8, 8, 8, 4, 4, 2, 2]

    /// Lê e valida apenas o cabeçalho `IHDR` de um PNG, sem descomprimir `IDAT`.
    public static func readInfo(
        _ bytes: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> PNGInfo {
        try checkLimit(bytes.count, limits.maxInputBytes, "png")
        var reader = ByteReader(bytes)
        try verifySignature(&reader)
        let (info, _) = try readIHDRChunk(&reader, bytes: bytes, limits: limits)
        return info
    }

    /// Decodifica um arquivo PNG completo para RGBA8 (`width * height * 4` bytes, sem pré-multiplicar).
    ///
    /// Canais de 16 bits têm a chave `tRNS` avaliada em 16 bits e são então reduzidos para 8 bits
    /// usando o byte mais significativo (`valor >> 8`).
    public static func decode(
        _ bytes: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> PNGImage {
        try checkLimit(bytes.count, limits.maxInputBytes, "png")
        var reader = ByteReader(bytes)
        try verifySignature(&reader)

        let (info, _) = try readIHDRChunk(&reader, bytes: bytes, limits: limits)
        let outputByteCount = try checkedMul(
            try checkedMul(info.width, info.height, "png.size"),
            4,
            "png.size"
        )
        try checkLimit(outputByteCount, limits.maxOutputBytes, "png.output")

        let expectedDecompressed = try computeExpectedDecompressedSize(info: info)

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
            let chunk = try readChunkHeaderAndVerifyCRC(&reader, bytes: bytes)
            let name = chunk.name

            if name == "IHDR" {
                throw .invalid(context: "png.IHDR", reason: "chunk IHDR duplicado")
            } else if name == "PLTE" {
                inIDATRun = false
                guard !seenIDAT else {
                    throw .invalid(context: "png.PLTE", reason: "PLTE após IDAT")
                }
                guard !seenPLTE else {
                    throw .invalid(context: "png.PLTE", reason: "PLTE duplicado")
                }
                guard info.colorType != .grayscale, info.colorType != .grayscaleAlpha else {
                    throw .invalid(context: "png.PLTE", reason: "PLTE proibido para tipo de cor")
                }
                guard chunk.length >= 3, chunk.length <= 768, chunk.length % 3 == 0 else {
                    throw .invalid(context: "png.PLTE", reason: "tamanho de PLTE inválido")
                }
                let entries = chunk.length / 3
                if info.colorType == .indexed {
                    let maxEntries = 1 << Int(info.bitDepth)
                    guard entries <= maxEntries else {
                        throw .invalid(context: "png.PLTE", reason: "PLTE excede 2^bitDepth entradas")
                    }
                }
                palette = Array(bytes[chunk.dataStart..<(chunk.dataStart + chunk.length)])
                paletteCount = entries
                seenPLTE = true
            } else if name == "tRNS" {
                inIDATRun = false
                guard !seenIDAT else {
                    throw .invalid(context: "png.tRNS", reason: "tRNS após IDAT")
                }
                guard !seenTRNS else {
                    throw .invalid(context: "png.tRNS", reason: "tRNS duplicado")
                }
                seenTRNS = true
                let start = chunk.dataStart
                switch info.colorType {
                case .grayscale:
                    guard chunk.length == 2 else {
                        throw .invalid(context: "png.tRNS", reason: "tRNS para cinza deve ter 2 bytes")
                    }
                    trnsGrayKey = (UInt16(bytes[start]) << 8) | UInt16(bytes[start + 1])
                case .rgb:
                    guard chunk.length == 6 else {
                        throw .invalid(context: "png.tRNS", reason: "tRNS para RGB deve ter 6 bytes")
                    }
                    let r = (UInt16(bytes[start]) << 8) | UInt16(bytes[start + 1])
                    let g = (UInt16(bytes[start + 2]) << 8) | UInt16(bytes[start + 3])
                    let b = (UInt16(bytes[start + 4]) << 8) | UInt16(bytes[start + 5])
                    trnsRGBKey = (r, g, b)
                case .indexed:
                    guard seenPLTE else {
                        throw .invalid(context: "png.tRNS", reason: "tRNS antes de PLTE")
                    }
                    guard chunk.length <= paletteCount else {
                        throw .invalid(context: "png.tRNS", reason: "tRNS excede entradas da paleta")
                    }
                    trnsAlpha = Array(bytes[start..<(start + chunk.length)])
                case .grayscaleAlpha, .rgba:
                    throw .invalid(context: "png.tRNS", reason: "tRNS proibido para tipo de cor com alfa")
                }
            } else if name == "IDAT" {
                if seenIDAT && !inIDATRun {
                    throw .invalid(context: "png.IDAT", reason: "chunks IDAT não contíguos")
                }
                if info.colorType == .indexed && !seenPLTE {
                    throw .invalid(context: "png.IDAT", reason: "PLTE ausente antes de IDAT")
                }
                seenIDAT = true
                inIDATRun = true
                let newSum = try checkedAdd(idatData.count, chunk.length, "png.IDAT")
                try checkLimit(newSum, limits.maxInputBytes, "png.IDAT")
                idatData.append(contentsOf: bytes[chunk.dataStart..<(chunk.dataStart + chunk.length)])
            } else if name == "IEND" {
                guard chunk.length == 0 else {
                    throw .invalid(context: "png.IEND", reason: "IEND deve ter comprimento 0")
                }
                guard seenIDAT else {
                    throw .invalid(context: "png.IEND", reason: "nenhum chunk IDAT encontrado")
                }
                seenIEND = true
                break
            } else {
                inIDATRun = false
                let isCritical = (chunk.type0 & 0x20) == 0
                if isCritical {
                    throw .unsupported(
                        context: "png.chunk(\(name))",
                        reason: "chunk crítico desconhecido"
                    )
                }
            }
        }

        guard seenIEND else {
            throw .truncated(context: "png.IEND")
        }

        let decompressed = try Inflate.zlibDecompress(
            idatData,
            from: 0,
            maxOutput: expectedDecompressed,
            context: "png.IDAT"
        )
        guard decompressed.count == expectedDecompressed else {
            throw .invalid(
                context: "png.IDAT",
                reason: "tamanho descomprimido diverge do esperado"
            )
        }

        var pixels = [UInt8](repeating: 0, count: outputByteCount)
        let colorState = ColorDecodeState(
            colorType: info.colorType,
            bitDepth: Int(info.bitDepth),
            palette: palette,
            paletteCount: paletteCount,
            trnsAlpha: trnsAlpha,
            trnsGrayKey: trnsGrayKey,
            trnsRGBKey: trnsRGBKey
        )

        if info.isInterlaced {
            try decodeAdam7(
                decompressed: decompressed,
                info: info,
                colorState: colorState,
                into: &pixels
            )
        } else {
            try decodePass(
                decompressed: decompressed,
                srcOffset: 0,
                passWidth: info.width,
                passHeight: info.height,
                destWidth: info.width,
                xStart: 0,
                yStart: 0,
                xStep: 1,
                yStep: 1,
                colorState: colorState,
                into: &pixels
            )
        }

        return PNGImage(width: info.width, height: info.height, pixels: pixels)
    }

    private static func verifySignature(_ reader: inout ByteReader) throws(AssetError) {
        let sig = try reader.readBytes(8, context: "png.signature")
        guard sig == signature else {
            throw .invalid(context: "png.signature", reason: "assinatura PNG inválida")
        }
    }

    private static func readIHDRChunk(
        _ reader: inout ByteReader,
        bytes: [UInt8],
        limits: AssetLimits
    ) throws(AssetError) -> (PNGInfo, Int) {
        let chunk = try readChunkHeaderAndVerifyCRC(&reader, bytes: bytes)
        guard chunk.name == "IHDR" else {
            throw .invalid(context: "png.IHDR", reason: "primeiro chunk deve ser IHDR")
        }
        guard chunk.length == 13 else {
            throw .invalid(context: "png.IHDR", reason: "IHDR deve ter 13 bytes")
        }

        let s = chunk.dataStart
        let rawWidth = readU32BE(bytes, at: s)
        let rawHeight = readU32BE(bytes, at: s + 4)
        guard rawWidth > 0, rawWidth <= 0x7FFF_FFFF else {
            throw .invalid(context: "png.IHDR.width", reason: "largura PNG inválida")
        }
        guard rawHeight > 0, rawHeight <= 0x7FFF_FFFF else {
            throw .invalid(context: "png.IHDR.height", reason: "altura PNG inválida")
        }

        let width = Int(rawWidth)
        let height = Int(rawHeight)
        try checkLimit(width, limits.maxImageDimension, "png.width")
        try checkLimit(height, limits.maxImageDimension, "png.height")

        let outputByteCount = try checkedMul(
            try checkedMul(width, height, "png.size"),
            4,
            "png.size"
        )
        try checkLimit(outputByteCount, limits.maxOutputBytes, "png.output")

        let bitDepth = bytes[s + 8]
        let colorTypeRaw = bytes[s + 9]
        let compression = bytes[s + 10]
        let filter = bytes[s + 11]
        let interlace = bytes[s + 12]

        guard let colorType = PNGColorType(rawValue: colorTypeRaw) else {
            throw .invalid(context: "png.IHDR.colorType", reason: "tipo de cor inválido")
        }
        guard isValidBitDepth(bitDepth, for: colorType) else {
            throw .invalid(
                context: "png.IHDR.bitDepth",
                reason: "combinação tipo de cor/profundidade inválida"
            )
        }
        guard compression == 0 else {
            throw .invalid(context: "png.IHDR.compression", reason: "método de compressão inválido")
        }
        guard filter == 0 else {
            throw .invalid(context: "png.IHDR.filter", reason: "método de filtro inválido")
        }
        guard interlace == 0 || interlace == 1 else {
            throw .invalid(context: "png.IHDR.interlace", reason: "método de entrelaçamento inválido")
        }

        let info = PNGInfo(
            width: width,
            height: height,
            bitDepth: bitDepth,
            colorType: colorType,
            isInterlaced: interlace == 1
        )
        return (info, reader.offset)
    }

    private struct ChunkSlice {
        let name: String
        let type0: UInt8
        let dataStart: Int
        let length: Int
    }

    private static func readChunkHeaderAndVerifyCRC(
        _ reader: inout ByteReader,
        bytes: [UInt8]
    ) throws(AssetError) -> ChunkSlice {
        let rawLength = try reader.readU32BE("png.chunk.length")
        guard rawLength <= 0x7FFF_FFFF else {
            throw .invalid(context: "png.chunk.length", reason: "comprimento de chunk excede 2^31-1")
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

        let totalNeeded = try checkedAdd(length, 4, "png.chunk(\(name))")
        guard reader.remaining >= totalNeeded else {
            throw .truncated(context: "png.chunk(\(name))")
        }

        let dataStart = reader.offset
        try reader.skip(length, context: "png.chunk(\(name))")
        let expectedCRC = try reader.readU32BE("png.chunk(\(name)).crc")
        let actualCRC = crc32(bytes, start: typeOffset, count: 4 + length)
        guard actualCRC == expectedCRC else {
            throw .invalid(context: "png.chunk(\(name))", reason: "CRC-32 inválido")
        }

        return ChunkSlice(name: name, type0: t0, dataStart: dataStart, length: length)
    }

    private static func computeExpectedDecompressedSize(info: PNGInfo) throws(AssetError) -> Int {
        let bppBits = bitsPerPixel(colorType: info.colorType, bitDepth: Int(info.bitDepth))
        if !info.isInterlaced {
            let rowData = try scanlineDataBytes(width: info.width, bppBits: bppBits)
            let rowTotal = try checkedAdd(1, rowData, "png.scanline")
            return try checkedMul(rowTotal, info.height, "png.decompressedSize")
        }

        var total = 0
        for pass in 0..<7 {
            let passW = passDimension(
                full: info.width,
                start: adam7XStart[pass],
                step: adam7XStep[pass]
            )
            let passH = passDimension(
                full: info.height,
                start: adam7YStart[pass],
                step: adam7YStep[pass]
            )
            if passW > 0 && passH > 0 {
                let rowData = try scanlineDataBytes(width: passW, bppBits: bppBits)
                let rowTotal = try checkedAdd(1, rowData, "png.adam7.scanline")
                let passBytes = try checkedMul(rowTotal, passH, "png.adam7.pass")
                total = try checkedAdd(total, passBytes, "png.decompressedSize")
            }
        }
        return total
    }

    private static func decodeAdam7(
        decompressed: [UInt8],
        info: PNGInfo,
        colorState: ColorDecodeState,
        into pixels: inout [UInt8]
    ) throws(AssetError) {
        var srcOffset = 0
        for pass in 0..<7 {
            let passW = passDimension(
                full: info.width,
                start: adam7XStart[pass],
                step: adam7XStep[pass]
            )
            let passH = passDimension(
                full: info.height,
                start: adam7YStart[pass],
                step: adam7YStep[pass]
            )
            if passW == 0 || passH == 0 {
                continue
            }
            srcOffset = try decodePass(
                decompressed: decompressed,
                srcOffset: srcOffset,
                passWidth: passW,
                passHeight: passH,
                destWidth: info.width,
                xStart: adam7XStart[pass],
                yStart: adam7YStart[pass],
                xStep: adam7XStep[pass],
                yStep: adam7YStep[pass],
                colorState: colorState,
                into: &pixels
            )
        }
    }

    @discardableResult
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
    ) throws(AssetError) -> Int {
        let bppBits = bitsPerPixel(colorType: colorState.colorType, bitDepth: colorState.bitDepth)
        let rowBytes = try scanlineDataBytes(width: passWidth, bppBits: bppBits)
        let filterBpp = max(1, (bppBits + 7) / 8)

        var prevRow = [UInt8](repeating: 0, count: rowBytes)
        var currRow = [UInt8](repeating: 0, count: rowBytes)
        var offset = startOffset

        for py in 0..<passHeight {
            guard offset < decompressed.count else {
                throw .truncated(context: "png.scanline")
            }
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

            let destY = yStart + py * yStep
            try writeScanlinePixels(
                currRow: currRow,
                passWidth: passWidth,
                destWidth: destWidth,
                xStart: xStart,
                xStep: xStep,
                destY: destY,
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
    ) throws(AssetError) {
        switch filterType {
        case 0:
            for i in 0..<rowBytes {
                curr[i] = src[srcStart + i]
            }
        case 1:
            for i in 0..<rowBytes {
                let a: UInt8 = i >= bpp ? curr[i - bpp] : 0
                curr[i] = src[srcStart + i] &+ a
            }
        case 2:
            for i in 0..<rowBytes {
                curr[i] = src[srcStart + i] &+ prev[i]
            }
        case 3:
            for i in 0..<rowBytes {
                let a = i >= bpp ? Int(curr[i - bpp]) : 0
                let b = Int(prev[i])
                curr[i] = src[srcStart + i] &+ UInt8((a + b) >> 1)
            }
        case 4:
            for i in 0..<rowBytes {
                let a = i >= bpp ? Int(curr[i - bpp]) : 0
                let b = Int(prev[i])
                let c = i >= bpp ? Int(prev[i - bpp]) : 0
                let predictor = paethPredictor(a: a, b: b, c: c)
                curr[i] = src[srcStart + i] &+ UInt8(predictor)
            }
        default:
            throw .invalid(context: "png.scanline.filter", reason: "tipo de filtro PNG inválido")
        }
    }

    @inline(__always)
    private static func paethPredictor(a: Int, b: Int, c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc {
            return a
        } else if pb <= pc {
            return b
        } else {
            return c
        }
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
    ) throws(AssetError) {
        let rowBase = destY * destWidth
        let bitDepth = colorState.bitDepth

        switch colorState.colorType {
        case .grayscale:
            for px in 0..<passWidth {
                let destIndex = (rowBase + xStart + px * xStep) * 4
                let gray8: UInt8
                let rawSample: UInt16
                if bitDepth < 8 {
                    let sample = extractSubByteSample(row: currRow, x: px, bitDepth: bitDepth)
                    rawSample = UInt16(sample)
                    gray8 = scaleSubByteGray(sample: sample, bitDepth: bitDepth)
                } else if bitDepth == 8 {
                    let g = currRow[px]
                    rawSample = UInt16(g)
                    gray8 = g
                } else {
                    let hi = currRow[2 * px]
                    let lo = currRow[2 * px + 1]
                    rawSample = (UInt16(hi) << 8) | UInt16(lo)
                    gray8 = hi
                }
                let alpha: UInt8 = colorState.trnsGrayKey == rawSample ? 0 : 255
                pixels[destIndex] = gray8
                pixels[destIndex + 1] = gray8
                pixels[destIndex + 2] = gray8
                pixels[destIndex + 3] = alpha
            }

        case .rgb:
            for px in 0..<passWidth {
                let destIndex = (rowBase + xStart + px * xStep) * 4
                let r: UInt8
                let g: UInt8
                let b: UInt8
                let alpha: UInt8
                if bitDepth == 8 {
                    let base = 3 * px
                    r = currRow[base]
                    g = currRow[base + 1]
                    b = currRow[base + 2]
                    if let key = colorState.trnsRGBKey,
                        key.0 == UInt16(r), key.1 == UInt16(g), key.2 == UInt16(b)
                    {
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
                    if let key = colorState.trnsRGBKey, key.0 == r16, key.1 == g16, key.2 == b16 {
                        alpha = 0
                    } else {
                        alpha = 255
                    }
                }
                pixels[destIndex] = r
                pixels[destIndex + 1] = g
                pixels[destIndex + 2] = b
                pixels[destIndex + 3] = alpha
            }

        case .indexed:
            for px in 0..<passWidth {
                let index: Int
                if bitDepth < 8 {
                    index = extractSubByteSample(row: currRow, x: px, bitDepth: bitDepth)
                } else {
                    index = Int(currRow[px])
                }
                guard index < colorState.paletteCount else {
                    throw .invalid(context: "png.pixels", reason: "índice de paleta fora dos limites")
                }
                let pBase = 3 * index
                let destIndex = (rowBase + xStart + px * xStep) * 4
                pixels[destIndex] = colorState.palette[pBase]
                pixels[destIndex + 1] = colorState.palette[pBase + 1]
                pixels[destIndex + 2] = colorState.palette[pBase + 2]
                pixels[destIndex + 3] =
                    index < colorState.trnsAlpha.count
                    ? colorState.trnsAlpha[index]
                    : 255
            }

        case .grayscaleAlpha:
            for px in 0..<passWidth {
                let destIndex = (rowBase + xStart + px * xStep) * 4
                let gray: UInt8
                let alpha: UInt8
                if bitDepth == 8 {
                    gray = currRow[2 * px]
                    alpha = currRow[2 * px + 1]
                } else {
                    gray = currRow[4 * px]
                    alpha = currRow[4 * px + 2]
                }
                pixels[destIndex] = gray
                pixels[destIndex + 1] = gray
                pixels[destIndex + 2] = gray
                pixels[destIndex + 3] = alpha
            }

        case .rgba:
            for px in 0..<passWidth {
                let destIndex = (rowBase + xStart + px * xStep) * 4
                if bitDepth == 8 {
                    let base = 4 * px
                    pixels[destIndex] = currRow[base]
                    pixels[destIndex + 1] = currRow[base + 1]
                    pixels[destIndex + 2] = currRow[base + 2]
                    pixels[destIndex + 3] = currRow[base + 3]
                } else {
                    let base = 8 * px
                    pixels[destIndex] = currRow[base]
                    pixels[destIndex + 1] = currRow[base + 2]
                    pixels[destIndex + 2] = currRow[base + 4]
                    pixels[destIndex + 3] = currRow[base + 6]
                }
            }
        }
    }

    @inline(__always)
    private static func extractSubByteSample(row: [UInt8], x: Int, bitDepth: Int) -> Int {
        let pixelsPerByte = 8 / bitDepth
        let byteVal = row[x / pixelsPerByte]
        let shift = (pixelsPerByte - 1 - (x % pixelsPerByte)) * bitDepth
        let mask = UInt8((1 << bitDepth) - 1)
        return Int((byteVal >> shift) & mask)
    }

    @inline(__always)
    private static func scaleSubByteGray(sample: Int, bitDepth: Int) -> UInt8 {
        switch bitDepth {
        case 1: return sample == 0 ? 0 : 255
        case 2: return UInt8(sample * 85)
        case 4: return UInt8(sample * 17)
        default: return UInt8(sample)
        }
    }

    private static func isValidBitDepth(_ bitDepth: UInt8, for colorType: PNGColorType) -> Bool {
        switch colorType {
        case .grayscale:
            return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8 || bitDepth == 16
        case .rgb, .grayscaleAlpha, .rgba:
            return bitDepth == 8 || bitDepth == 16
        case .indexed:
            return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8
        }
    }

    private static func bitsPerPixel(colorType: PNGColorType, bitDepth: Int) -> Int {
        switch colorType {
        case .grayscale, .indexed: return bitDepth
        case .grayscaleAlpha: return 2 * bitDepth
        case .rgb: return 3 * bitDepth
        case .rgba: return 4 * bitDepth
        }
    }

    private static func scanlineDataBytes(width: Int, bppBits: Int) throws(AssetError) -> Int {
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
        let end = start + count
        for i in start..<end {
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
                if (c & 1) != 0 {
                    c = 0xEDB8_8320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            table[n] = c
        }
        return table
    }
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
