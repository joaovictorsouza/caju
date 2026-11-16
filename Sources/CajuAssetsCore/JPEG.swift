/// Fator de subamostragem horizontal e vertical de um componente JPEG.
public struct JPEGComponentSampling: Sendable, Equatable {
    /// Identificador do componente no marcador `SOF`.
    public let id: UInt8
    /// Fator de amostragem horizontal (`1...4`).
    public let horizontalFactor: UInt8
    /// Fator de amostragem vertical (`1...4`).
    public let verticalFactor: UInt8

    /// Cria um descritor de amostragem de componente JPEG.
    public init(id: UInt8, horizontalFactor: UInt8, verticalFactor: UInt8) {
        self.id = id
        self.horizontalFactor = horizontalFactor
        self.verticalFactor = verticalFactor
    }
}

/// Metadados extraídos do cabeçalho de um arquivo JPEG (`SOF0`/`SOF1`/`SOF2` e `APP1` EXIF).
///
/// ```swift
/// let info = try JPEGDecoder.readInfo(bytes)
/// print(info.width, info.height, info.exifOrientation ?? 1)
/// ```
public struct JPEGInfo: Sendable, Equatable {
    /// Largura da imagem em pixels.
    public let width: Int
    /// Altura da imagem em pixels.
    public let height: Int
    /// Quantidade de componentes de cor (`1`, `3` ou `4`).
    public let componentCount: Int
    /// Precisão em bits por amostra (`8` ou `12`).
    public let precision: Int
    /// Indica se o quadro é progressivo (`SOF2`).
    public let isProgressive: Bool
    /// Fatores de subamostragem horizontal/vertical por componente.
    public let components: [JPEGComponentSampling]
    /// Orientação EXIF opcional (tag `0x0112`, valores `1...8`), se presente em `APP1`.
    public let exifOrientation: UInt8?

    /// Cria uma instância de metadados JPEG.
    public init(
        width: Int,
        height: Int,
        componentCount: Int,
        precision: Int,
        isProgressive: Bool,
        components: [JPEGComponentSampling],
        exifOrientation: UInt8?
    ) {
        self.width = width
        self.height = height
        self.componentCount = componentCount
        self.precision = precision
        self.isProgressive = isProgressive
        self.components = components
        self.exifOrientation = exifOrientation
    }
}

/// Imagem JPEG decodificada em pixels RGBA8 (`width * height * 4` bytes).
///
/// A orientação EXIF é apenas reportada em ``exifOrientation`` e **não** é aplicada aos pixels.
///
/// ```swift
/// let image = try JPEGDecoder.decode(bytes)
/// // image.pixels.count == image.width * image.height * 4
/// ```
public struct JPEGImage: Sendable, Equatable {
    /// Largura da imagem em pixels.
    public let width: Int
    /// Altura da imagem em pixels.
    public let height: Int
    /// Pixels em ordem de varredura RGBA8 (`width * height * 4` bytes, alfa `255`).
    public let pixels: [UInt8]
    /// Orientação EXIF opcional (tag `0x0112`, valores `1...8`), reportada sem rotacionar pixels.
    public let exifOrientation: UInt8?

    /// Cria uma imagem JPEG decodificada.
    public init(
        width: Int,
        height: Int,
        pixels: [UInt8],
        exifOrientation: UInt8? = nil
    ) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.exifOrientation = exifOrientation
    }
}

/// Decodificador JPEG puro em Swift (sem `Foundation`).
///
/// Suporta leitura de metadados (``readInfo(_:limits:)``) e decodificação completa de pixels
/// (``decode(_:limits:)``) para JPEG Huffman de 8 bits (baseline/estendido sequencial `SOF0`/`SOF1`
/// e progressivo `SOF2`), 1 componente (cinza) ou 3 componentes (YCbCr), subamostragem
/// `4:4:4`/`4:2:2`/`4:2:0` e marcadores de reinício (`RST0...RST7`).
///
/// ```swift
/// let info = try JPEGDecoder.readInfo(bytes)
/// let image = try JPEGDecoder.decode(bytes)
/// ```
public enum JPEGDecoder {
    private static let exifHeader: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]

    /// Mapeamento da ordem zig-zag (0..63) para ordem natural por linhas (0..63).
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

    /// Lê apenas cabeçalho e metadados de um JPEG até o primeiro marcador `SOF`.
    ///
    /// Não decodifica os dados de imagem (`SOS`); marcadores `SOF3` e `SOF5...SOF15` lançam `.unsupported`.
    public static func readInfo(
        _ bytes: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> JPEGInfo {
        try checkLimit(bytes.count, limits.maxInputBytes, "jpeg")
        var reader = ByteReader(bytes)

        let soi0 = try reader.readU8("jpeg.SOI")
        let soi1 = try reader.readU8("jpeg.SOI")
        guard soi0 == 0xFF, soi1 == 0xD8 else {
            throw .invalid(context: "jpeg.SOI", reason: "assinatura JPEG (SOI) inválida")
        }

        var exifOrientation: UInt8?

        while reader.remaining > 0 {
            let marker = try readNextMarker(&reader, context: "jpeg.marker")

            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                continue
            }
            if marker == 0xD8 {
                throw .invalid(context: "jpeg.marker", reason: "SOI duplicado")
            }
            if marker == 0xD9 {
                throw .invalid(context: "jpeg.EOI", reason: "EOI encontrado antes de SOF")
            }

            let segmentLength = Int(try reader.readU16BE("jpeg.segment.length"))
            guard segmentLength >= 2 else {
                throw .invalid(context: "jpeg.segment.length", reason: "comprimento de segmento < 2")
            }
            let payloadLength = segmentLength - 2
            guard payloadLength <= reader.remaining else {
                throw .truncated(context: "jpeg.segment")
            }
            let payloadStart = reader.offset

            switch marker {
            case 0xC0, 0xC1, 0xC2:
                let frame = try parseSOF(
                    bytes: bytes,
                    payloadStart: payloadStart,
                    payloadLength: payloadLength,
                    isProgressive: marker == 0xC2,
                    exifOrientation: exifOrientation,
                    limits: limits
                )
                return frame.info
            case 0xC3, 0xC5...0xC7, 0xC8, 0xC9...0xCB, 0xCD...0xCF:
                throw .unsupported(
                    context: "jpeg.SOF",
                    reason: "modo JPEG não suportado (lossless/aritmético/hierárquico)"
                )
            case 0xDA:
                throw .invalid(context: "jpeg.SOS", reason: "SOS encontrado antes de SOF")
            case 0xE1:
                if exifOrientation == nil {
                    exifOrientation = try parseAPP1ExifOrientation(
                        bytes: bytes,
                        payloadStart: payloadStart,
                        payloadLength: payloadLength,
                        limits: limits
                    )
                }
                try reader.skip(payloadLength, context: "jpeg.APP1")
            default:
                try reader.skip(payloadLength, context: "jpeg.segment")
            }
        }

        throw .truncated(context: "jpeg.SOF")
    }

    /// Decodifica um arquivo JPEG Huffman de 8 bits (baseline/estendido sequencial ou progressivo) para RGBA8.
    ///
    /// Suporta 1 componente (escala de cinza → RGBA8) e 3 componentes (YCbCr → RGBA8),
    /// subamostragem `4:4:4`/`4:2:2`/`4:2:0` e marcadores de reinício (`DRI`/`RST`).
    /// A orientação EXIF é reportada em ``JPEGImage/exifOrientation`` sem rotacionar os pixels.
    public static func decode(
        _ bytes: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> JPEGImage {
        try checkLimit(bytes.count, limits.maxInputBytes, "jpeg")
        var reader = ByteReader(bytes)

        let soi0 = try reader.readU8("jpeg.SOI")
        let soi1 = try reader.readU8("jpeg.SOI")
        guard soi0 == 0xFF, soi1 == 0xD8 else {
            throw .invalid(context: "jpeg.SOI", reason: "assinatura JPEG (SOI) inválida")
        }

        var exifOrientation: UInt8?
        var frame: ParsedSOF?
        var quantTables = [[Int32]?](repeating: nil, count: 4)
        var dcTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
        var acTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
        var restartInterval = 0

        var scanCount = 0
        var decodedDirectBaseline = false
        var directPixels: [UInt8] = []
        var coeffBuffers: [[Int16]] = []
        var componentScannedDC = [Bool]()

        while reader.remaining > 0 {
            let marker = try readNextMarker(&reader, context: "jpeg.marker")

            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                continue
            }
            if marker == 0xD8 {
                throw .invalid(context: "jpeg.marker", reason: "SOI duplicado")
            }
            if marker == 0xD9 {
                guard let sof = frame else {
                    throw .invalid(context: "jpeg.EOI", reason: "EOI encontrado antes de SOF")
                }
                guard scanCount > 0 else {
                    throw .invalid(context: "jpeg.EOI", reason: "nenhum scan SOS encontrado antes de EOI")
                }
                for c in 0..<componentScannedDC.count where !componentScannedDC[c] {
                    throw .invalid(context: "jpeg.SOS", reason: "componente \(c) sem scan DC")
                }

                if decodedDirectBaseline {
                    return JPEGImage(
                        width: sof.info.width,
                        height: sof.info.height,
                        pixels: directPixels,
                        exifOrientation: exifOrientation
                    )
                }

                let pixels = try reconstructPixels(
                    sof: sof,
                    coeffBuffers: coeffBuffers,
                    quantTables: quantTables
                )
                return JPEGImage(
                    width: sof.info.width,
                    height: sof.info.height,
                    pixels: pixels,
                    exifOrientation: exifOrientation
                )
            }

            let segmentLength = Int(try reader.readU16BE("jpeg.segment.length"))
            guard segmentLength >= 2 else {
                throw .invalid(context: "jpeg.segment.length", reason: "comprimento de segmento < 2")
            }
            let payloadLength = segmentLength - 2
            guard payloadLength <= reader.remaining else {
                throw .truncated(context: "jpeg.segment")
            }
            let payloadStart = reader.offset

            switch marker {
            case 0xC0, 0xC1, 0xC2:
                guard frame == nil else {
                    throw .invalid(context: "jpeg.SOF", reason: "marcador SOF duplicado")
                }
                let parsed = try parseSOF(
                    bytes: bytes,
                    payloadStart: payloadStart,
                    payloadLength: payloadLength,
                    isProgressive: marker == 0xC2,
                    exifOrientation: exifOrientation,
                    limits: limits
                )
                try validateFrameForPixelDecode(parsed, limits: limits)
                frame = parsed
                componentScannedDC = [Bool](repeating: false, count: parsed.info.componentCount)
                try reader.skip(payloadLength, context: "jpeg.SOF")

            case 0xC3, 0xC5...0xC7, 0xC8, 0xC9...0xCB, 0xCD...0xCF:
                throw .unsupported(
                    context: "jpeg.SOF",
                    reason: "modo JPEG não suportado (lossless/aritmético/hierárquico)"
                )

            case 0xC4:
                try parseDHT(
                    bytes: bytes,
                    start: payloadStart,
                    length: payloadLength,
                    dcTables: &dcTables,
                    acTables: &acTables
                )
                try reader.skip(payloadLength, context: "jpeg.DHT")

            case 0xDB:
                try parseDQT(
                    bytes: bytes,
                    start: payloadStart,
                    length: payloadLength,
                    quantTables: &quantTables
                )
                try reader.skip(payloadLength, context: "jpeg.DQT")

            case 0xDD:
                guard payloadLength == 2 else {
                    throw .invalid(context: "jpeg.DRI", reason: "comprimento do segmento DRI deve ser 4")
                }
                restartInterval = Int((UInt16(bytes[payloadStart]) << 8) | UInt16(bytes[payloadStart + 1]))
                try reader.skip(payloadLength, context: "jpeg.DRI")

            case 0xE1:
                if exifOrientation == nil {
                    exifOrientation = try parseAPP1ExifOrientation(
                        bytes: bytes,
                        payloadStart: payloadStart,
                        payloadLength: payloadLength,
                        limits: limits
                    )
                }
                try reader.skip(payloadLength, context: "jpeg.APP1")

            case 0xDA:
                guard let sof = frame else {
                    throw .invalid(context: "jpeg.SOS", reason: "SOS encontrado antes de SOF")
                }
                guard !decodedDirectBaseline else {
                    throw .invalid(context: "jpeg.SOS", reason: "SOS adicional após scan sequencial completo")
                }

                let scan = try parseSOS(
                    bytes: bytes,
                    start: payloadStart,
                    length: payloadLength,
                    sof: sof,
                    quantTables: quantTables,
                    dcTables: dcTables,
                    acTables: acTables
                )
                try reader.skip(payloadLength, context: "jpeg.SOS")

                if !sof.info.isProgressive
                    && scanCount == 0
                    && scan.components.count == sof.info.componentCount
                {
                    directPixels = try decodeBaselineInterleavedScan(
                        bytes: bytes,
                        offset: &reader,
                        sof: sof,
                        scan: scan,
                        quantTables: quantTables,
                        dcTables: dcTables,
                        acTables: acTables,
                        restartInterval: restartInterval
                    )
                    decodedDirectBaseline = true
                    for c in 0..<componentScannedDC.count {
                        componentScannedDC[c] = true
                    }
                } else {
                    if coeffBuffers.isEmpty {
                        coeffBuffers = try allocateCoefficientBuffers(sof: sof)
                    }
                    try decodeBufferedScan(
                        bytes: bytes,
                        reader: &reader,
                        sof: sof,
                        scan: scan,
                        dcTables: dcTables,
                        acTables: acTables,
                        restartInterval: restartInterval,
                        coeffBuffers: &coeffBuffers
                    )
                    if scan.spectralStart == 0 {
                        for comp in scan.components {
                            componentScannedDC[comp.frameIndex] = true
                        }
                    }
                }
                scanCount += 1

            default:
                try reader.skip(payloadLength, context: "jpeg.segment")
            }
        }

        if frame == nil {
            throw .truncated(context: "jpeg.SOF")
        }
        throw .truncated(context: "jpeg.EOI")
    }

    // MARK: - Marcadores e cabeçalhos

    private static func readNextMarker(
        _ reader: inout ByteReader,
        context: String
    ) throws(AssetError) -> UInt8 {
        let prefix = try reader.readU8(context)
        guard prefix == 0xFF else {
            throw .invalid(context: context, reason: "marcador JPEG (0xFF) esperado")
        }
        var marker = try reader.readU8(context)
        while marker == 0xFF {
            marker = try reader.readU8(context)
        }
        if marker == 0x00 {
            throw .invalid(context: context, reason: "byte 0x00 inesperado fora de scan")
        }
        return marker
    }

    private struct ParsedSOF {
        let info: JPEGInfo
        let quantSelectors: [Int]
        let maxH: Int
        let maxV: Int
        let mcuCols: Int
        let mcuRows: Int
        let compBlocksX: [Int]
        let compBlocksY: [Int]
        let compStridesInBlocks: [Int]
    }

    private static func parseSOF(
        bytes: [UInt8],
        payloadStart: Int,
        payloadLength: Int,
        isProgressive: Bool,
        exifOrientation: UInt8?,
        limits: AssetLimits
    ) throws(AssetError) -> ParsedSOF {
        guard payloadLength >= 6 else {
            throw .truncated(context: "jpeg.SOF")
        }

        let precision = Int(bytes[payloadStart])
        guard precision == 8 || precision == 12 else {
            throw .invalid(context: "jpeg.SOF.precision", reason: "precisão JPEG deve ser 8 ou 12")
        }

        let height = Int((UInt16(bytes[payloadStart + 1]) << 8) | UInt16(bytes[payloadStart + 2]))
        if height == 0 {
            throw .unsupported(
                context: "jpeg.SOF.height",
                reason: "altura 0 com marcador DNL não suportada"
            )
        }
        try checkLimit(height, limits.maxImageDimension, "jpeg.height")

        let width = Int((UInt16(bytes[payloadStart + 3]) << 8) | UInt16(bytes[payloadStart + 4]))
        guard width > 0 else {
            throw .invalid(context: "jpeg.SOF.width", reason: "largura JPEG deve ser > 0")
        }
        try checkLimit(width, limits.maxImageDimension, "jpeg.width")

        let componentCount = Int(bytes[payloadStart + 5])
        if componentCount == 0 {
            throw .invalid(context: "jpeg.SOF.components", reason: "contagem de componentes zero")
        }
        guard componentCount == 1 || componentCount == 3 || componentCount == 4 else {
            throw .unsupported(
                context: "jpeg.SOF.components",
                reason: "apenas 1, 3 ou 4 componentes são suportados"
            )
        }
        try checkLimit(componentCount, limits.maxElements, "jpeg.components")

        let expectedPayloadLength = 6 + componentCount * 3
        guard payloadLength == expectedPayloadLength else {
            throw .invalid(context: "jpeg.SOF", reason: "tamanho do segmento SOF inconsistente")
        }

        let outputBytes = try checkedMul(
            try checkedMul(width, height, "jpeg.size"),
            componentCount,
            "jpeg.size"
        )
        try checkLimit(outputBytes, limits.maxOutputBytes, "jpeg.output")

        var components: [JPEGComponentSampling] = []
        components.reserveCapacity(componentCount)
        var quantSelectors: [Int] = []
        quantSelectors.reserveCapacity(componentCount)
        var maxH = 1
        var maxV = 1
        var offset = payloadStart + 6

        for _ in 0..<componentCount {
            let id = bytes[offset]
            let sampling = bytes[offset + 1]
            let tq = Int(bytes[offset + 2])
            let h = sampling >> 4
            let v = sampling & 0x0F
            guard h >= 1, h <= 4, v >= 1, v <= 4 else {
                throw .invalid(
                    context: "jpeg.SOF.sampling",
                    reason: "fator de subamostragem fora de 1...4"
                )
            }
            guard tq <= 3 else {
                throw .invalid(
                    context: "jpeg.SOF.quantTable",
                    reason: "seletor de tabela de quantização fora de 0...3"
                )
            }
            if components.contains(where: { $0.id == id }) {
                throw .invalid(
                    context: "jpeg.SOF.componentID",
                    reason: "identificador de componente duplicado"
                )
            }
            maxH = max(maxH, Int(h))
            maxV = max(maxV, Int(v))
            components.append(
                JPEGComponentSampling(id: id, horizontalFactor: h, verticalFactor: v)
            )
            quantSelectors.append(tq)
            offset += 3
        }

        let mcuWidth = maxH * 8
        let mcuHeight = maxV * 8
        let mcuCols = (width + mcuWidth - 1) / mcuWidth
        let mcuRows = (height + mcuHeight - 1) / mcuHeight

        var compBlocksX: [Int] = []
        var compBlocksY: [Int] = []
        var compStridesInBlocks: [Int] = []
        compBlocksX.reserveCapacity(componentCount)
        compBlocksY.reserveCapacity(componentCount)
        compStridesInBlocks.reserveCapacity(componentCount)

        for comp in components {
            let h = Int(comp.horizontalFactor)
            let v = Int(comp.verticalFactor)
            let compW = (width * h + maxH - 1) / maxH
            let compH = (height * v + maxV - 1) / maxV
            compBlocksX.append((compW + 7) / 8)
            compBlocksY.append((compH + 7) / 8)
            compStridesInBlocks.append(mcuCols * h)
        }

        let info = JPEGInfo(
            width: width,
            height: height,
            componentCount: componentCount,
            precision: precision,
            isProgressive: isProgressive,
            components: components,
            exifOrientation: exifOrientation
        )
        return ParsedSOF(
            info: info,
            quantSelectors: quantSelectors,
            maxH: maxH,
            maxV: maxV,
            mcuCols: mcuCols,
            mcuRows: mcuRows,
            compBlocksX: compBlocksX,
            compBlocksY: compBlocksY,
            compStridesInBlocks: compStridesInBlocks
        )
    }

    private static func validateFrameForPixelDecode(
        _ frame: ParsedSOF,
        limits: AssetLimits
    ) throws(AssetError) {
        let info = frame.info
        guard info.precision == 8 else {
            throw .unsupported(
                context: "jpeg.SOF.precision",
                reason: "apenas precisão de 8 bits é suportada na decodificação de pixels"
            )
        }
        guard info.componentCount == 1 || info.componentCount == 3 else {
            throw .unsupported(
                context: "jpeg.SOF.components",
                reason: "apenas 1 (cinza) ou 3 (YCbCr) componentes são suportados"
            )
        }

        let rgbaBytes = try checkedMul(
            try checkedMul(info.width, info.height, "jpeg.size"),
            4,
            "jpeg.size"
        )
        try checkLimit(rgbaBytes, limits.maxOutputBytes, "jpeg.output")
    }

    private static func parseDQT(
        bytes: [UInt8],
        start: Int,
        length: Int,
        quantTables: inout [[Int32]?]
    ) throws(AssetError) {
        var pos = start
        let end = start + length
        guard length > 0 else {
            throw .invalid(context: "jpeg.DQT", reason: "segmento DQT vazio")
        }
        while pos < end {
            let pqTq = bytes[pos]
            pos += 1
            let pq = pqTq >> 4
            let tq = Int(pqTq & 0x0F)
            guard pq <= 1 else {
                throw .invalid(context: "jpeg.DQT.precision", reason: "precisão DQT inválida")
            }
            guard tq <= 3 else {
                throw .invalid(context: "jpeg.DQT.id", reason: "índice de tabela DQT fora de 0...3")
            }

            let entryBytes = pq == 0 ? 64 : 128
            guard pos + entryBytes <= end else {
                throw .truncated(context: "jpeg.DQT")
            }

            var table = [Int32](repeating: 0, count: 64)
            if pq == 0 {
                for i in 0..<64 {
                    table[i] = Int32(bytes[pos + i])
                }
            } else {
                for i in 0..<64 {
                    let hi = UInt16(bytes[pos + i * 2])
                    let lo = UInt16(bytes[pos + i * 2 + 1])
                    table[i] = Int32((hi << 8) | lo)
                }
            }
            quantTables[tq] = table
            pos += entryBytes
        }
    }

    private static func parseDHT(
        bytes: [UInt8],
        start: Int,
        length: Int,
        dcTables: inout [JPEGHuffmanTable?],
        acTables: inout [JPEGHuffmanTable?]
    ) throws(AssetError) {
        var pos = start
        let end = start + length
        guard length > 0 else {
            throw .invalid(context: "jpeg.DHT", reason: "segmento DHT vazio")
        }
        while pos < end {
            let tcTh = bytes[pos]
            pos += 1
            let tc = tcTh >> 4
            let th = Int(tcTh & 0x0F)
            guard tc <= 1 else {
                throw .invalid(context: "jpeg.DHT.class", reason: "classe DHT inválida (esperado 0 ou 1)")
            }
            guard th <= 3 else {
                throw .invalid(context: "jpeg.DHT.id", reason: "índice de tabela DHT fora de 0...3")
            }
            guard pos + 16 <= end else {
                throw .truncated(context: "jpeg.DHT.counts")
            }

            var counts = [Int](repeating: 0, count: 17)
            var totalSymbols = 0
            for len in 1...16 {
                let c = Int(bytes[pos + len - 1])
                counts[len] = c
                totalSymbols += c
            }
            pos += 16

            guard totalSymbols <= 256 else {
                throw .invalid(context: "jpeg.DHT.symbols", reason: "tabela Huffman excede 256 símbolos")
            }
            guard pos + totalSymbols <= end else {
                throw .truncated(context: "jpeg.DHT.symbols")
            }

            let values = Array(bytes[pos..<(pos + totalSymbols)])
            pos += totalSymbols

            let table = try JPEGHuffmanTable(counts: counts, values: values)
            if tc == 0 {
                dcTables[th] = table
            } else {
                acTables[th] = table
            }
        }
    }

    private struct ScanComponent {
        let frameIndex: Int
        let dcTableIndex: Int
        let acTableIndex: Int
    }

    private struct ParsedSOS {
        let components: [ScanComponent]
        let spectralStart: Int
        let spectralEnd: Int
        let successiveHigh: Int
        let successiveLow: Int
    }

    private static func parseSOS(
        bytes: [UInt8],
        start: Int,
        length: Int,
        sof: ParsedSOF,
        quantTables: [[Int32]?],
        dcTables: [JPEGHuffmanTable?],
        acTables: [JPEGHuffmanTable?]
    ) throws(AssetError) -> ParsedSOS {
        guard length >= 1 else {
            throw .truncated(context: "jpeg.SOS")
        }
        let ns = Int(bytes[start])
        guard ns >= 1, ns <= 4, ns <= sof.info.componentCount else {
            throw .invalid(context: "jpeg.SOS.components", reason: "número de componentes no scan inválido")
        }
        let expectedLength = 1 + ns * 2 + 3
        guard length == expectedLength else {
            throw .invalid(context: "jpeg.SOS", reason: "tamanho do segmento SOS inconsistente")
        }

        var scanComponents: [ScanComponent] = []
        scanComponents.reserveCapacity(ns)
        var usedFrameIndices = 0
        var mcuBlockSum = 0

        var pos = start + 1
        for _ in 0..<ns {
            let cs = bytes[pos]
            let tdTa = bytes[pos + 1]
            pos += 2

            let td = Int(tdTa >> 4)
            let ta = Int(tdTa & 0x0F)
            guard td <= 3, ta <= 3 else {
                throw .invalid(context: "jpeg.SOS.tables", reason: "seletor de tabela Huffman fora de 0...3")
            }

            guard let frameIdx = sof.info.components.firstIndex(where: { $0.id == cs }) else {
                throw .invalid(context: "jpeg.SOS.component", reason: "componente do SOS ausente no SOF")
            }
            let mask = 1 << frameIdx
            guard (usedFrameIndices & mask) == 0 else {
                throw .invalid(context: "jpeg.SOS.component", reason: "componente repetido no SOS")
            }
            usedFrameIndices |= mask

            let comp = sof.info.components[frameIdx]
            mcuBlockSum += Int(comp.horizontalFactor) * Int(comp.verticalFactor)

            let qSel = sof.quantSelectors[frameIdx]
            guard quantTables[qSel] != nil else {
                throw .invalid(context: "jpeg.DQT", reason: "tabela de quantização \(qSel) ausente")
            }

            scanComponents.append(
                ScanComponent(frameIndex: frameIdx, dcTableIndex: td, acTableIndex: ta)
            )
        }

        if ns > 1 {
            guard mcuBlockSum <= 10 else {
                throw .invalid(
                    context: "jpeg.SOS.sampling",
                    reason: "soma de blocos por MCU intercalado excede 10"
                )
            }
        }

        let ss = Int(bytes[pos])
        let se = Int(bytes[pos + 1])
        let ahAl = bytes[pos + 2]
        let ah = Int(ahAl >> 4)
        let al = Int(ahAl & 0x0F)

        guard ss <= se, se <= 63, ah <= 13, al <= 13 else {
            throw .invalid(
                context: "jpeg.SOS.spectral", reason: "parâmetros espectrais/aproximação inválidos")
        }

        if !sof.info.isProgressive {
            guard ss == 0, se == 63, ah == 0, al == 0 else {
                throw .invalid(
                    context: "jpeg.SOS.spectral",
                    reason: "scan sequencial exige Ss=0, Se=63, Ah=0, Al=0"
                )
            }
        } else {
            if ss == 0 {
                guard se == 0 else {
                    throw .invalid(
                        context: "jpeg.SOS.spectral",
                        reason: "scan DC progressivo exige Se=0"
                    )
                }
            } else {
                guard ns == 1 else {
                    throw .invalid(
                        context: "jpeg.SOS.spectral",
                        reason: "scan AC progressivo exige apenas 1 componente"
                    )
                }
            }
            if ah > 0 {
                guard ah == al + 1 else {
                    throw .invalid(
                        context: "jpeg.SOS.approximation",
                        reason: "refinamento progressivo exige Ah == Al + 1"
                    )
                }
            }
        }

        // Valida existência das tabelas Huffman exigidas por este scan.
        for sc in scanComponents {
            if ss == 0, ah == 0 {
                guard dcTables[sc.dcTableIndex] != nil else {
                    throw .invalid(
                        context: "jpeg.DHT",
                        reason: "tabela Huffman DC \(sc.dcTableIndex) ausente"
                    )
                }
            }
            if se > 0 {
                guard acTables[sc.acTableIndex] != nil else {
                    throw .invalid(
                        context: "jpeg.DHT",
                        reason: "tabela Huffman AC \(sc.acTableIndex) ausente"
                    )
                }
            }
        }

        return ParsedSOS(
            components: scanComponents,
            spectralStart: ss,
            spectralEnd: se,
            successiveHigh: ah,
            successiveLow: al
        )
    }

    // MARK: - Decodificação Baseline Sequencial Direta

    private static func decodeBaselineInterleavedScan(
        bytes: [UInt8],
        offset reader: inout ByteReader,
        sof: ParsedSOF,
        scan: ParsedSOS,
        quantTables: [[Int32]?],
        dcTables: [JPEGHuffmanTable?],
        acTables: [JPEGHuffmanTable?],
        restartInterval: Int
    ) throws(AssetError) -> [UInt8] {
        let width = sof.info.width
        let height = sof.info.height
        let compCount = sof.info.componentCount
        var pixels = [UInt8](repeating: 255, count: width * height * 4)

        var bits = JPEGBitReader(bytes: bytes, offset: reader.offset)
        var dcPred = [Int](repeating: 0, count: compCount)
        var coeffBlock = [Int32](repeating: 0, count: 64)

        let mcuW = sof.maxH * 8
        let mcuH = sof.maxV * 8
        let totalMCUs = sof.mcuCols * sof.mcuRows

        // Buffer de saída por componente dentro de 1 MCU: máximo maxH*8 * maxV*8 bytes por componente.
        var compScratch = [[UInt8]]()
        compScratch.reserveCapacity(compCount)
        for c in 0..<compCount {
            let comp = sof.info.components[c]
            let sz = Int(comp.horizontalFactor) * 8 * Int(comp.verticalFactor) * 8
            compScratch.append([UInt8](repeating: 0, count: sz))
        }
        var blockPixels = [UInt8](repeating: 0, count: 64)

        var mcuIndex = 0
        var rstExpected = 0

        for mcuY in 0..<sof.mcuRows {
            let pyBase = mcuY * mcuH
            let validH = min(mcuH, height - pyBase)

            for mcuX in 0..<sof.mcuCols {
                if restartInterval > 0 && mcuIndex > 0 && (mcuIndex % restartInterval) == 0 {
                    try bits.consumeRestartMarker(expectedIndex: rstExpected)
                    rstExpected = (rstExpected + 1) & 7
                    for c in 0..<compCount { dcPred[c] = 0 }
                }

                for sc in scan.components {
                    let c = sc.frameIndex
                    let comp = sof.info.components[c]
                    let h = Int(comp.horizontalFactor)
                    let v = Int(comp.verticalFactor)
                    let stridePixels = h * 8
                    guard let dcTable = dcTables[sc.dcTableIndex],
                        let acTable = acTables[sc.acTableIndex],
                        let quant = quantTables[sof.quantSelectors[c]]
                    else {
                        throw .invalid(context: "jpeg.tables", reason: "tabela ausente")
                    }

                    for by in 0..<v {
                        for bx in 0..<h {
                            try decodeSequentialBlock(
                                &bits,
                                dcTable: dcTable,
                                acTable: acTable,
                                quant: quant,
                                dcPred: &dcPred[c],
                                outNaturalCoeffs: &coeffBlock
                            )
                            idct8x8(coeffBlock, into: &blockPixels)

                            let dstXBase = bx * 8
                            let dstYBase = by * 8
                            for row in 0..<8 {
                                let dstRow = (dstYBase + row) * stridePixels + dstXBase
                                let srcRow = row * 8
                                for col in 0..<8 {
                                    compScratch[c][dstRow + col] = blockPixels[srcRow + col]
                                }
                            }
                        }
                    }
                }

                let pxBase = mcuX * mcuW
                let validW = min(mcuW, width - pxBase)
                writeMCUToRGBA8(
                    compScratch: compScratch,
                    sof: sof,
                    pxBase: pxBase,
                    pyBase: pyBase,
                    validW: validW,
                    validH: validH,
                    into: &pixels
                )

                mcuIndex += 1
                _ = totalMCUs
            }
        }

        try bits.finishScanAndSyncReader(&reader)
        return pixels
    }

    private static func decodeSequentialBlock(
        _ bits: inout JPEGBitReader,
        dcTable: JPEGHuffmanTable,
        acTable: JPEGHuffmanTable,
        quant: [Int32],
        dcPred: inout Int,
        outNaturalCoeffs: inout [Int32]
    ) throws(AssetError) {
        for i in 0..<64 { outNaturalCoeffs[i] = 0 }

        let dcCat = try dcTable.decode(&bits, context: "jpeg.scan.dc")
        guard dcCat <= 15 else {
            throw .invalid(context: "jpeg.scan.dc", reason: "categoria DC > 15")
        }
        let dcDiff = try receiveAndExtend(&bits, count: dcCat, context: "jpeg.scan.dc")
        let dcVal = dcPred &+ dcDiff
        dcPred = dcVal
        outNaturalCoeffs[0] = Int32(truncatingIfNeeded: dcVal) &* quant[0]

        var k = 1
        while k < 64 {
            let rs = try acTable.decode(&bits, context: "jpeg.scan.ac")
            let r = rs >> 4
            let s = rs & 0x0F
            if s == 0 {
                if r == 15 {
                    k += 16
                } else {
                    break
                }
            } else {
                k += r
                guard k < 64 else {
                    throw .invalid(context: "jpeg.scan.ac", reason: "índice de coeficiente AC >= 64")
                }
                let acVal = try receiveAndExtend(&bits, count: s, context: "jpeg.scan.ac")
                let nat = zigzagToNatural[k]
                outNaturalCoeffs[nat] = Int32(truncatingIfNeeded: acVal) &* quant[k]
                k += 1
            }
        }
    }

    // MARK: - Decodificação Progressiva e Multi-Scan

    private static func allocateCoefficientBuffers(sof: ParsedSOF) throws(AssetError) -> [[Int16]] {
        var buffers: [[Int16]] = []
        buffers.reserveCapacity(sof.info.componentCount)
        for c in 0..<sof.info.componentCount {
            let comp = sof.info.components[c]
            let rowsInBlocks = try checkedMul(sof.mcuRows, Int(comp.verticalFactor), "jpeg.coeff")
            let totalBlocks = try checkedMul(sof.compStridesInBlocks[c], rowsInBlocks, "jpeg.coeff")
            let totalCoeffs = try checkedMul(totalBlocks, 64, "jpeg.coeff")
            buffers.append([Int16](repeating: 0, count: totalCoeffs))
        }
        return buffers
    }

    private static func decodeBufferedScan(
        bytes: [UInt8],
        reader: inout ByteReader,
        sof: ParsedSOF,
        scan: ParsedSOS,
        dcTables: [JPEGHuffmanTable?],
        acTables: [JPEGHuffmanTable?],
        restartInterval: Int,
        coeffBuffers: inout [[Int16]]
    ) throws(AssetError) {
        var bits = JPEGBitReader(bytes: bytes, offset: reader.offset)
        let ss = scan.spectralStart
        let se = scan.spectralEnd
        let ah = scan.successiveHigh
        let al = scan.successiveLow

        if scan.components.count == 1 {
            let sc = scan.components[0]
            let c = sc.frameIndex
            let bxCount = sof.compBlocksX[c]
            let byCount = sof.compBlocksY[c]
            let strideBlocks = sof.compStridesInBlocks[c]
            var dcPred = 0
            var eobRun = 0
            var blockIndex = 0
            var rstExpected = 0

            for by in 0..<byCount {
                for bx in 0..<bxCount {
                    if restartInterval > 0 && blockIndex > 0 && (blockIndex % restartInterval) == 0 {
                        try bits.consumeRestartMarker(expectedIndex: rstExpected)
                        rstExpected = (rstExpected + 1) & 7
                        dcPred = 0
                        eobRun = 0
                    }

                    let coeffBase = (by * strideBlocks + bx) * 64
                    try decodeScanBlock(
                        &bits,
                        dcTable: dcTables[sc.dcTableIndex],
                        acTable: acTables[sc.acTableIndex],
                        ss: ss,
                        se: se,
                        ah: ah,
                        al: al,
                        dcPred: &dcPred,
                        eobRun: &eobRun,
                        coeffs: &coeffBuffers[c],
                        coeffBase: coeffBase
                    )
                    blockIndex += 1
                }
            }
        } else {
            var dcPred = [Int](repeating: 0, count: sof.info.componentCount)
            var eobRun = 0
            var mcuIndex = 0
            var rstExpected = 0

            for mcuY in 0..<sof.mcuRows {
                for mcuX in 0..<sof.mcuCols {
                    if restartInterval > 0 && mcuIndex > 0 && (mcuIndex % restartInterval) == 0 {
                        try bits.consumeRestartMarker(expectedIndex: rstExpected)
                        rstExpected = (rstExpected + 1) & 7
                        for i in 0..<dcPred.count { dcPred[i] = 0 }
                        eobRun = 0
                    }

                    for sc in scan.components {
                        let c = sc.frameIndex
                        let comp = sof.info.components[c]
                        let h = Int(comp.horizontalFactor)
                        let v = Int(comp.verticalFactor)
                        let strideBlocks = sof.compStridesInBlocks[c]
                        for dy in 0..<v {
                            let by = mcuY * v + dy
                            for dx in 0..<h {
                                let bx = mcuX * h + dx
                                let coeffBase = (by * strideBlocks + bx) * 64
                                try decodeScanBlock(
                                    &bits,
                                    dcTable: dcTables[sc.dcTableIndex],
                                    acTable: acTables[sc.acTableIndex],
                                    ss: ss,
                                    se: se,
                                    ah: ah,
                                    al: al,
                                    dcPred: &dcPred[c],
                                    eobRun: &eobRun,
                                    coeffs: &coeffBuffers[c],
                                    coeffBase: coeffBase
                                )
                            }
                        }
                    }
                    mcuIndex += 1
                }
            }
        }

        try bits.finishScanAndSyncReader(&reader)
    }

    private static func decodeScanBlock(
        _ bits: inout JPEGBitReader,
        dcTable: JPEGHuffmanTable?,
        acTable: JPEGHuffmanTable?,
        ss: Int,
        se: Int,
        ah: Int,
        al: Int,
        dcPred: inout Int,
        eobRun: inout Int,
        coeffs: inout [Int16],
        coeffBase: Int
    ) throws(AssetError) {
        if ss == 0 {
            if ah == 0 {
                guard let dcTable else {
                    throw .invalid(context: "jpeg.DHT", reason: "tabela Huffman DC ausente")
                }
                let dcCat = try dcTable.decode(&bits, context: "jpeg.scan.dc")
                guard dcCat <= 15 else {
                    throw .invalid(context: "jpeg.scan.dc", reason: "categoria DC > 15")
                }
                let diff = try receiveAndExtend(&bits, count: dcCat, context: "jpeg.scan.dc")
                let dcVal = dcPred &+ diff
                dcPred = dcVal
                coeffs[coeffBase] = Int16(truncatingIfNeeded: dcVal << al)
            } else {
                let bit = try bits.readBits(1, context: "jpeg.scan.dcRefine")
                if bit != 0 {
                    coeffs[coeffBase] |= Int16(truncatingIfNeeded: 1 << al)
                }
            }
            if se == 0 {
                return
            }
        }

        guard let acTable else {
            throw .invalid(context: "jpeg.DHT", reason: "tabela Huffman AC ausente")
        }

        let acStart = max(ss, 1)
        if ah == 0 {
            if eobRun > 0 {
                eobRun -= 1
                return
            }
            var k = acStart
            while k <= se {
                let rs = try acTable.decode(&bits, context: "jpeg.scan.ac")
                let r = rs >> 4
                let s = rs & 0x0F
                if s == 0 {
                    if r == 15 {
                        k += 16
                    } else {
                        let extra = r > 0 ? try bits.readBits(r, context: "jpeg.scan.eob") : 0
                        eobRun = (1 << r) + extra - 1
                        break
                    }
                } else {
                    k += r
                    guard k <= se else {
                        throw .invalid(context: "jpeg.scan.ac", reason: "índice AC excede Se")
                    }
                    let val = try receiveAndExtend(&bits, count: s, context: "jpeg.scan.ac")
                    coeffs[coeffBase + k] = Int16(truncatingIfNeeded: val << al)
                    k += 1
                }
            }
            return
        }

        // Refinamento AC (Ah > 0, aproximação sucessiva).
        let p1 = Int16(truncatingIfNeeded: 1 << al)
        let m1 = Int16(truncatingIfNeeded: -(1 << al))
        var k = acStart

        if eobRun == 0 {
            while k <= se {
                let rs = try acTable.decode(&bits, context: "jpeg.scan.acRefine")
                let r = rs >> 4
                let s = rs & 0x0F

                var newVal: Int16 = 0
                if s == 0 {
                    if r != 15 {
                        let extra = r > 0 ? try bits.readBits(r, context: "jpeg.scan.eob") : 0
                        eobRun = (1 << r) + extra
                        break
                    }
                } else if s == 1 {
                    let signBit = try bits.readBits(1, context: "jpeg.scan.acSign")
                    newVal = signBit != 0 ? p1 : m1
                } else {
                    throw .invalid(
                        context: "jpeg.scan.acRefine",
                        reason: "símbolo AC inválido em refinamento (s > 1)"
                    )
                }

                var zeroSkip = r
                while k <= se {
                    let existing = coeffs[coeffBase + k]
                    if existing != 0 {
                        let refBit = try bits.readBits(1, context: "jpeg.scan.acRefineBit")
                        if refBit != 0 {
                            coeffs[coeffBase + k] = existing > 0 ? (existing &+ p1) : (existing &+ m1)
                        }
                        k += 1
                    } else {
                        if zeroSkip == 0 {
                            break
                        }
                        zeroSkip -= 1
                        k += 1
                    }
                }

                if s == 1 {
                    guard k <= se else {
                        throw .invalid(context: "jpeg.scan.acRefine", reason: "índice AC excede Se")
                    }
                    coeffs[coeffBase + k] = newVal
                    k += 1
                } else {
                    // ZRL (s == 0, r == 15): consome o 16º zero encontrado.
                    guard zeroSkip == 0, k <= se else {
                        throw .invalid(context: "jpeg.scan.acRefine", reason: "ZRL excede Se")
                    }
                    k += 1
                }
            }
        }

        if eobRun > 0 {
            while k <= se {
                let existing = coeffs[coeffBase + k]
                if existing != 0 {
                    let refBit = try bits.readBits(1, context: "jpeg.scan.acRefineBit")
                    if refBit != 0 {
                        coeffs[coeffBase + k] = existing > 0 ? (existing &+ p1) : (existing &+ m1)
                    }
                }
                k += 1
            }
            eobRun -= 1
        }
    }

    private static func reconstructPixels(
        sof: ParsedSOF,
        coeffBuffers: [[Int16]],
        quantTables: [[Int32]?]
    ) throws(AssetError) -> [UInt8] {
        let width = sof.info.width
        let height = sof.info.height
        let compCount = sof.info.componentCount
        var pixels = [UInt8](repeating: 255, count: width * height * 4)

        var naturalCoeffs = [Int32](repeating: 0, count: 64)
        var blockPixels = [UInt8](repeating: 0, count: 64)

        var compScratch = [[UInt8]]()
        compScratch.reserveCapacity(compCount)
        for c in 0..<compCount {
            let comp = sof.info.components[c]
            compScratch.append(
                [UInt8](repeating: 0, count: Int(comp.horizontalFactor) * 8 * Int(comp.verticalFactor) * 8)
            )
        }

        let mcuW = sof.maxH * 8
        let mcuH = sof.maxV * 8

        for mcuY in 0..<sof.mcuRows {
            let pyBase = mcuY * mcuH
            let validH = min(mcuH, height - pyBase)
            for mcuX in 0..<sof.mcuCols {
                for c in 0..<compCount {
                    let comp = sof.info.components[c]
                    let h = Int(comp.horizontalFactor)
                    let v = Int(comp.verticalFactor)
                    let strideBlocks = sof.compStridesInBlocks[c]
                    let stridePixels = h * 8
                    guard let quant = quantTables[sof.quantSelectors[c]] else {
                        throw .invalid(context: "jpeg.DQT", reason: "tabela de quantização ausente")
                    }

                    for dy in 0..<v {
                        let by = mcuY * v + dy
                        for dx in 0..<h {
                            let bx = mcuX * h + dx
                            let coeffBase = (by * strideBlocks + bx) * 64
                            for zz in 0..<64 {
                                let nat = zigzagToNatural[zz]
                                naturalCoeffs[nat] = Int32(coeffBuffers[c][coeffBase + zz]) &* quant[zz]
                            }
                            idct8x8(naturalCoeffs, into: &blockPixels)
                            let dstXBase = dx * 8
                            let dstYBase = dy * 8
                            for row in 0..<8 {
                                let dstRow = (dstYBase + row) * stridePixels + dstXBase
                                let srcRow = row * 8
                                for col in 0..<8 {
                                    compScratch[c][dstRow + col] = blockPixels[srcRow + col]
                                }
                            }
                        }
                    }
                }

                let pxBase = mcuX * mcuW
                let validW = min(mcuW, width - pxBase)
                writeMCUToRGBA8(
                    compScratch: compScratch,
                    sof: sof,
                    pxBase: pxBase,
                    pyBase: pyBase,
                    validW: validW,
                    validH: validH,
                    into: &pixels
                )
            }
        }

        return pixels
    }

    // MARK: - IDCT Inteira Determinística e Conversão YCbCr → RGBA8

    /// IDCT 8x8 inteira separável (Loeffler em ponto fixo, determinística e sem estouro em dados hostis).
    private static func idct8x8(_ coeffs: [Int32], into out: inout [UInt8]) {
        var workspace = [Int64](repeating: 0, count: 64)

        // Passo 1: colunas
        for col in 0..<8 {
            let s0 = Int64(coeffs[col])
            let s1 = Int64(coeffs[col + 8])
            let s2 = Int64(coeffs[col + 16])
            let s3 = Int64(coeffs[col + 24])
            let s4 = Int64(coeffs[col + 32])
            let s5 = Int64(coeffs[col + 40])
            let s6 = Int64(coeffs[col + 48])
            let s7 = Int64(coeffs[col + 56])

            if s1 == 0 && s2 == 0 && s3 == 0 && s4 == 0 && s5 == 0 && s6 == 0 && s7 == 0 {
                let dc = s0 << 2
                workspace[col] = dc
                workspace[col + 8] = dc
                workspace[col + 16] = dc
                workspace[col + 24] = dc
                workspace[col + 32] = dc
                workspace[col + 40] = dc
                workspace[col + 48] = dc
                workspace[col + 56] = dc
                continue
            }

            let p1e = (s2 &+ s6) &* 2217
            let t2e = p1e &+ s6 &* -7567
            let t3e = p1e &+ s2 &* 3135
            let t0e = (s0 &+ s4) << 12
            let t1e = (s0 &- s4) << 12
            let x0 = t0e &+ t3e &+ 512
            let x3 = t0e &- t3e &+ 512
            let x1 = t1e &+ t2e &+ 512
            let x2 = t1e &- t2e &+ 512

            var t0 = s7
            var t1 = s5
            var t2 = s3
            var t3 = s1
            var p3 = t0 &+ t2
            var p4 = t1 &+ t3
            var p1 = t0 &+ t3
            var p2 = t1 &+ t2
            let p5 = (p3 &+ p4) &* 4816
            t0 = t0 &* 1223
            t1 = t1 &* 8410
            t2 = t2 &* 12586
            t3 = t3 &* 6149
            p1 = p5 &+ p1 &* -3685
            p2 = p5 &+ p2 &* -10497
            p3 = p3 &* -8034
            p4 = p4 &* -1597
            t3 = t3 &+ p1 &+ p4
            t2 = t2 &+ p2 &+ p3
            t1 = t1 &+ p2 &+ p4
            t0 = t0 &+ p1 &+ p3

            workspace[col] = (x0 &+ t3) >> 10
            workspace[col + 56] = (x0 &- t3) >> 10
            workspace[col + 8] = (x1 &+ t2) >> 10
            workspace[col + 48] = (x1 &- t2) >> 10
            workspace[col + 16] = (x2 &+ t1) >> 10
            workspace[col + 40] = (x2 &- t1) >> 10
            workspace[col + 24] = (x3 &+ t0) >> 10
            workspace[col + 32] = (x3 &- t0) >> 10
        }

        // Passo 2: linhas
        let roundBias: Int64 = 65_536 + (128 << 17)
        for row in 0..<8 {
            let base = row * 8
            let s0 = workspace[base]
            let s1 = workspace[base + 1]
            let s2 = workspace[base + 2]
            let s3 = workspace[base + 3]
            let s4 = workspace[base + 4]
            let s5 = workspace[base + 5]
            let s6 = workspace[base + 6]
            let s7 = workspace[base + 7]

            let p1e = (s2 &+ s6) &* 2217
            let t2e = p1e &+ s6 &* -7567
            let t3e = p1e &+ s2 &* 3135
            let t0e = ((s0 &+ s4) << 12) &+ roundBias
            let t1e = ((s0 &- s4) << 12) &+ roundBias
            let x0 = t0e &+ t3e
            let x3 = t0e &- t3e
            let x1 = t1e &+ t2e
            let x2 = t1e &- t2e

            var t0 = s7
            var t1 = s5
            var t2 = s3
            var t3 = s1
            var p3 = t0 &+ t2
            var p4 = t1 &+ t3
            var p1 = t0 &+ t3
            var p2 = t1 &+ t2
            let p5 = (p3 &+ p4) &* 4816
            t0 = t0 &* 1223
            t1 = t1 &* 8410
            t2 = t2 &* 12586
            t3 = t3 &* 6149
            p1 = p5 &+ p1 &* -3685
            p2 = p5 &+ p2 &* -10497
            p3 = p3 &* -8034
            p4 = p4 &* -1597
            t3 = t3 &+ p1 &+ p4
            t2 = t2 &+ p2 &+ p3
            t1 = t1 &+ p2 &+ p4
            t0 = t0 &+ p1 &+ p3

            out[base] = clampByte((x0 &+ t3) >> 17)
            out[base + 7] = clampByte((x0 &- t3) >> 17)
            out[base + 1] = clampByte((x1 &+ t2) >> 17)
            out[base + 6] = clampByte((x1 &- t2) >> 17)
            out[base + 2] = clampByte((x2 &+ t1) >> 17)
            out[base + 5] = clampByte((x2 &- t1) >> 17)
            out[base + 3] = clampByte((x3 &+ t0) >> 17)
            out[base + 4] = clampByte((x3 &- t0) >> 17)
        }
    }

    @inline(__always)
    private static func clampByte(_ value: Int64) -> UInt8 {
        if value <= 0 { return 0 }
        if value >= 255 { return 255 }
        return UInt8(value)
    }

    @inline(__always)
    private static func clampByte32(_ value: Int32) -> UInt8 {
        if value <= 0 { return 0 }
        if value >= 255 { return 255 }
        return UInt8(value)
    }

    private static func writeMCUToRGBA8(
        compScratch: [[UInt8]],
        sof: ParsedSOF,
        pxBase: Int,
        pyBase: Int,
        validW: Int,
        validH: Int,
        into pixels: inout [UInt8]
    ) {
        let imgWidth = sof.info.width
        if sof.info.componentCount == 1 {
            let h0 = Int(sof.info.components[0].horizontalFactor)
            let v0 = Int(sof.info.components[0].verticalFactor)
            let stride0 = h0 * 8
            let maxH = sof.maxH
            let maxV = sof.maxV

            for ly in 0..<validH {
                let sy = (ly * v0) / maxV
                let srcRow = sy * stride0
                let dstRow = ((pyBase + ly) * imgWidth + pxBase) * 4
                for lx in 0..<validW {
                    let sx = (lx * h0) / maxH
                    let y = compScratch[0][srcRow + sx]
                    let idx = dstRow + lx * 4
                    pixels[idx] = y
                    pixels[idx + 1] = y
                    pixels[idx + 2] = y
                    pixels[idx + 3] = 255
                }
            }
            return
        }

        let h0 = Int(sof.info.components[0].horizontalFactor)
        let v0 = Int(sof.info.components[0].verticalFactor)
        let h1 = Int(sof.info.components[1].horizontalFactor)
        let v1 = Int(sof.info.components[1].verticalFactor)
        let h2 = Int(sof.info.components[2].horizontalFactor)
        let v2 = Int(sof.info.components[2].verticalFactor)
        let stride0 = h0 * 8
        let stride1 = h1 * 8
        let stride2 = h2 * 8
        let maxH = sof.maxH
        let maxV = sof.maxV

        for ly in 0..<validH {
            let sy0 = ((ly * v0) / maxV) * stride0
            let sy1 = ((ly * v1) / maxV) * stride1
            let sy2 = ((ly * v2) / maxV) * stride2
            let dstRow = ((pyBase + ly) * imgWidth + pxBase) * 4

            for lx in 0..<validW {
                let yVal = Int32(compScratch[0][sy0 + (lx * h0) / maxH])
                let cb = Int32(compScratch[1][sy1 + (lx * h1) / maxH]) - 128
                let cr = Int32(compScratch[2][sy2 + (lx * h2) / maxH]) - 128

                let r = yVal + ((91_881 * cr + 32_768) >> 16)
                let g = yVal - ((22_554 * cb + 46_802 * cr + 32_768) >> 16)
                let b = yVal + ((116_130 * cb + 32_768) >> 16)

                let idx = dstRow + lx * 4
                pixels[idx] = clampByte32(r)
                pixels[idx + 1] = clampByte32(g)
                pixels[idx + 2] = clampByte32(b)
                pixels[idx + 3] = 255
            }
        }
    }

    @inline(__always)
    private static func receiveAndExtend(
        _ bits: inout JPEGBitReader,
        count: Int,
        context: String
    ) throws(AssetError) -> Int {
        if count == 0 { return 0 }
        let v = try bits.readBits(count, context: context)
        let threshold = 1 << (count - 1)
        return v < threshold ? v - ((1 << count) - 1) : v
    }

    // MARK: - EXIF APP1

    private static func parseAPP1ExifOrientation(
        bytes: [UInt8],
        payloadStart: Int,
        payloadLength: Int,
        limits: AssetLimits
    ) throws(AssetError) -> UInt8? {
        guard payloadLength >= exifHeader.count else {
            return nil
        }
        for i in 0..<exifHeader.count {
            if bytes[payloadStart + i] != exifHeader[i] {
                return nil
            }
        }

        let tiffStart = payloadStart + exifHeader.count
        let tiffLength = payloadLength - exifHeader.count
        guard tiffLength >= 8 else {
            throw .truncated(context: "jpeg.exif.tiff")
        }

        let b0 = bytes[tiffStart]
        let b1 = bytes[tiffStart + 1]
        let isLittleEndian: Bool
        if b0 == 0x49 && b1 == 0x49 {
            isLittleEndian = true
        } else if b0 == 0x4D && b1 == 0x4D {
            isLittleEndian = false
        } else {
            throw .invalid(context: "jpeg.exif.endian", reason: "ordem de bytes TIFF inválida")
        }

        let magic = readU16(bytes, at: tiffStart + 2, littleEndian: isLittleEndian)
        guard magic == 42 else {
            throw .invalid(context: "jpeg.exif.magic", reason: "assinatura TIFF (42) inválida")
        }

        let rawIFD0Offset = readU32(bytes, at: tiffStart + 4, littleEndian: isLittleEndian)
        guard rawIFD0Offset >= 8 else {
            throw .invalid(context: "jpeg.exif.ifd0", reason: "offset de IFD0 aponta para cabeçalho")
        }
        guard let ifd0Offset = Int(exactly: rawIFD0Offset), ifd0Offset <= tiffLength else {
            throw .truncated(context: "jpeg.exif.ifd0")
        }
        guard tiffLength - ifd0Offset >= 2 else {
            throw .truncated(context: "jpeg.exif.ifd0")
        }

        let ifdStart = tiffStart + ifd0Offset
        let entryCount = Int(readU16(bytes, at: ifdStart, littleEndian: isLittleEndian))
        try checkLimit(entryCount, limits.maxElements, "jpeg.exif.ifd0")

        let entriesBytes = try checkedMul(entryCount, 12, "jpeg.exif.ifd0")
        let neededBytes = try checkedAdd(2, entriesBytes, "jpeg.exif.ifd0")
        guard neededBytes <= tiffLength - ifd0Offset else {
            throw .truncated(context: "jpeg.exif.ifd0")
        }

        var entryOffset = ifdStart + 2
        for _ in 0..<entryCount {
            let tag = readU16(bytes, at: entryOffset, littleEndian: isLittleEndian)
            if tag == 0x0112 {
                let type = readU16(bytes, at: entryOffset + 2, littleEndian: isLittleEndian)
                let count = readU32(bytes, at: entryOffset + 4, littleEndian: isLittleEndian)
                guard type == 3, count == 1 else {
                    throw .invalid(
                        context: "jpeg.exif.orientation",
                        reason: "tipo/contagem inválidos para tag 0x0112"
                    )
                }
                let value = readU16(bytes, at: entryOffset + 8, littleEndian: isLittleEndian)
                guard value >= 1, value <= 8 else {
                    throw .invalid(
                        context: "jpeg.exif.orientation",
                        reason: "valor de orientação fora de 1...8"
                    )
                }
                return UInt8(value)
            }
            entryOffset += 12
        }

        return nil
    }

    @inline(__always)
    private static func readU16(_ bytes: [UInt8], at offset: Int, littleEndian: Bool) -> UInt16 {
        if littleEndian {
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    @inline(__always)
    private static func readU32(_ bytes: [UInt8], at offset: Int, littleEndian: Bool) -> UInt32 {
        if littleEndian {
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

// MARK: - Leitor de bits MSB-first com byte stuffing (0xFF 0x00) e marcadores RST

private struct JPEGBitReader {
    private let bytes: [UInt8]
    private var byteOffset: Int
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0
    private var hitMarker: Bool = false

    init(bytes: [UInt8], offset: Int) {
        self.bytes = bytes
        self.byteOffset = offset
    }

    mutating func readBits(_ count: Int, context: String) throws(AssetError) -> Int {
        if count == 0 { return 0 }
        try fillBuffer(upTo: count, context: context)
        guard bitCount >= count else {
            throw .truncated(context: context)
        }
        let shift = bitCount - count
        let mask = (UInt64(1) << UInt64(count)) - 1
        let value = Int((bitBuffer >> UInt64(shift)) & mask)
        bitCount -= count
        bitBuffer &= (UInt64(1) << UInt64(bitCount)) - 1
        return value
    }

    mutating func peekUpTo8Bits(context: String) throws(AssetError) -> (bits: Int, available: Int) {
        try fillBuffer(upTo: 8, context: context)
        if bitCount == 0 { return (0, 0) }
        if bitCount >= 8 {
            let value = Int((bitBuffer >> UInt64(bitCount - 8)) & 0xFF)
            return (value, 8)
        }
        let value = Int((bitBuffer << UInt64(8 - bitCount)) & 0xFF)
        return (value, bitCount)
    }

    mutating func consumeBits(_ count: Int) {
        bitCount -= count
        bitBuffer &= (UInt64(1) << UInt64(bitCount)) - 1
    }

    mutating func consumeRestartMarker(expectedIndex: Int) throws(AssetError) {
        // Descarta bits de preenchimento do byte atual e retorna ao marcador não consumido.
        bitBuffer = 0
        bitCount = 0
        hitMarker = false

        guard byteOffset < bytes.count else {
            throw .truncated(context: "jpeg.RST")
        }
        guard bytes[byteOffset] == 0xFF else {
            throw .invalid(context: "jpeg.RST", reason: "marcador de reinício (0xFF) esperado")
        }
        var idx = byteOffset + 1
        while idx < bytes.count && bytes[idx] == 0xFF {
            idx += 1
        }
        guard idx < bytes.count else {
            throw .truncated(context: "jpeg.RST")
        }
        let marker = bytes[idx]
        let expectedMarker = UInt8(0xD0 + (expectedIndex & 7))
        guard marker == expectedMarker else {
            throw .invalid(
                context: "jpeg.RST",
                reason: "marcador RST\(expectedIndex & 7) esperado, encontrado \(marker)"
            )
        }
        byteOffset = idx + 1
    }

    mutating func finishScanAndSyncReader(_ reader: inout ByteReader) throws(AssetError) {
        // Descarta bits restantes do último byte parcial.
        bitBuffer = 0
        bitCount = 0
        hitMarker = false
        try reader.seek(to: byteOffset, context: "jpeg.scan.end")
    }

    private mutating func fillBuffer(upTo needed: Int, context: String) throws(AssetError) {
        while bitCount < needed && !hitMarker && byteOffset < bytes.count {
            let b = bytes[byteOffset]
            if b == 0xFF {
                guard byteOffset + 1 < bytes.count else {
                    throw .truncated(context: context)
                }
                let next = bytes[byteOffset + 1]
                if next == 0x00 {
                    bitBuffer = (bitBuffer << 8) | 0xFF
                    bitCount += 8
                    byteOffset += 2
                } else {
                    // Chegou a um marcador real (EOI/RST/próximo SOS); deixa `byteOffset` nele.
                    hitMarker = true
                    break
                }
            } else {
                bitBuffer = (bitBuffer << 8) | UInt64(b)
                bitCount += 8
                byteOffset += 1
            }
        }
    }
}

// MARK: - Tabela Huffman Canônica JPEG (MSB-first)

private struct JPEGHuffmanTable: Sendable {
    private let minCode: [Int]
    private let maxCode: [Int]
    private let valPtr: [Int]
    private let values: [UInt8]
    private let fastTable: [UInt16]

    init(counts: [Int], values: [UInt8]) throws(AssetError) {
        var left = 1
        for len in 1...16 {
            left <<= 1
            left -= counts[len]
            if left < 0 {
                throw .invalid(context: "jpeg.DHT", reason: "árvore Huffman sobre-subscrita")
            }
        }

        var minCode = [Int](repeating: 0, count: 17)
        var maxCode = [Int](repeating: -1, count: 17)
        var valPtr = [Int](repeating: 0, count: 17)
        var fast = [UInt16](repeating: 0, count: 256)

        var code = 0
        var k = 0
        for len in 1...16 {
            let count = counts[len]
            if count > 0 {
                valPtr[len] = k
                minCode[len] = code
                if len <= 8 {
                    let shift = 8 - len
                    let span = 1 << shift
                    for i in 0..<count {
                        let sym = values[k + i]
                        let base = (code + i) << shift
                        let packed = UInt16((len << 8) | Int(sym))
                        for fill in 0..<span {
                            fast[base + fill] = packed
                        }
                    }
                }
                code += count - 1
                maxCode[len] = code
                k += count
                code += 1
            }
            code <<= 1
        }

        self.minCode = minCode
        self.maxCode = maxCode
        self.valPtr = valPtr
        self.values = values
        self.fastTable = fast
    }

    func decode(_ bits: inout JPEGBitReader, context: String) throws(AssetError) -> Int {
        let (peek, available) = try bits.peekUpTo8Bits(context: context)
        guard available > 0 else {
            throw .truncated(context: context)
        }
        let fastEntry = fastTable[peek]
        if fastEntry != 0 {
            let len = Int(fastEntry >> 8)
            guard available >= len else {
                throw .truncated(context: context)
            }
            bits.consumeBits(len)
            return Int(fastEntry & 0xFF)
        }

        var code = 0
        for len in 1...16 {
            code = (code << 1) | (try bits.readBits(1, context: context))
            if code <= maxCode[len] {
                let idx = valPtr[len] + (code - minCode[len])
                guard idx >= 0, idx < values.count else {
                    throw .invalid(context: context, reason: "índice Huffman inválido")
                }
                return Int(values[idx])
            }
        }
        throw .invalid(context: context, reason: "código Huffman JPEG inválido no fluxo")
    }
}
