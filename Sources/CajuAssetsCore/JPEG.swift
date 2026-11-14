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
/// A decodificação completa dos pixels JPEG fica fora do escopo de `CajuAssetsCore`.
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

/// Leitor de metadados JPEG puro em Swift (sem `Foundation`).
///
/// Analisa apenas marcadores de cabeçalho até `SOF0`/`SOF1`/`SOF2` e orientação EXIF opcional em `APP1`.
/// A decodificação completa de pixels JPEG (Huffman/IDCT) fica fora do escopo deste módulo.
///
/// ```swift
/// let info = try JPEGDecoder.readInfo(bytes)
/// ```
public enum JPEGDecoder {
    private static let exifHeader: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]

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
            let prefix = try reader.readU8("jpeg.marker")
            guard prefix == 0xFF else {
                throw .invalid(context: "jpeg.marker", reason: "marcador JPEG (0xFF) esperado")
            }

            var marker = try reader.readU8("jpeg.marker")
            while marker == 0xFF {
                marker = try reader.readU8("jpeg.marker")
            }

            if marker == 0x00 {
                throw .invalid(context: "jpeg.marker", reason: "byte 0x00 inesperado fora de scan")
            }
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
                return try parseSOF(
                    bytes: bytes,
                    payloadStart: payloadStart,
                    payloadLength: payloadLength,
                    isProgressive: marker == 0xC2,
                    exifOrientation: exifOrientation,
                    limits: limits
                )
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

    private static func parseSOF(
        bytes: [UInt8],
        payloadStart: Int,
        payloadLength: Int,
        isProgressive: Bool,
        exifOrientation: UInt8?,
        limits: AssetLimits
    ) throws(AssetError) -> JPEGInfo {
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
        var offset = payloadStart + 6
        for _ in 0..<componentCount {
            let id = bytes[offset]
            let sampling = bytes[offset + 1]
            let h = sampling >> 4
            let v = sampling & 0x0F
            guard h >= 1, h <= 4, v >= 1, v <= 4 else {
                throw .invalid(
                    context: "jpeg.SOF.sampling",
                    reason: "fator de subamostragem fora de 1...4"
                )
            }
            components.append(
                JPEGComponentSampling(id: id, horizontalFactor: h, verticalFactor: v)
            )
            offset += 3
        }

        return JPEGInfo(
            width: width,
            height: height,
            componentCount: componentCount,
            precision: precision,
            isProgressive: isProgressive,
            components: components,
            exifOrientation: exifOrientation
        )
    }

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
