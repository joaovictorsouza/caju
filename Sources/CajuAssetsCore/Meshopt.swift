// Algoritmo portado de meshoptimizer (https://github.com/zeux/meshoptimizer).
// Copyright (c) 2016-2025 Arseny Kapoulkine (licença MIT).
//
// Decisão arquitetural: porte em Swift puro (sem dependência C e sem Foundation),
// garantindo portabilidade imediata em iOS, Android e Linux sem alterações em
// `Package.swift` nem introdução de alvos C na camada `CajuAssetsCore`.

/// Decodificador puro em Swift para buffers de vértices e índices no formato `meshoptimizer`
/// (`EXT_meshopt_compression`, versões v0 e v1) e filtros pós-decodificação.
///
/// Todos os métodos validam limites de entrada e saída via ``AssetLimits`` **antes** de alocar
/// qualquer buffer e verificam os limites de leitura a cada passo sobre o fluxo codificado.
///
/// - Note: Índices decodificados por ``decodeIndexBuffer(count:indexSize:_:limits:)`` e
///   ``decodeIndexSequence(count:indexSize:_:limits:)`` têm seu intervalo validado para caber
///   em `indexSize` bytes (por exemplo `0...65_535` quando `indexSize == 2`), mas **não** são
///   validados contra a contagem de vértices da primitiva; essa checagem deve ser feita no
///   consumidor ou na camada glTF.
///
/// ```swift
/// let vertices = try Meshopt.decodeVertexBuffer(count: 4, stride: 16, encodedVertices)
/// var normals = try Meshopt.decodeVertexBuffer(count: 4, stride: 4, encodedNormals)
/// try Meshopt.applyFilter(.octahedral, count: 4, stride: 4, to: &normals)
/// let indices = try Meshopt.decodeIndexBuffer(count: 12, indexSize: 4, encodedIndices)
/// ```
public enum Meshopt: Sendable {
    /// Filtro de reconstrução aplicado *in-place* após a decodificação de vértices.
    public enum Filter: Sendable, Equatable {
        /// Filtro octaedral para normais/tangentes (stride 4 ou 8 bytes).
        case octahedral
        /// Filtro de quatérnio unitário com componente máximo implícito (stride 8 bytes).
        case quaternion
        /// Filtro exponencial de ponto flutuante (stride múltiplo de 4 bytes).
        case exponential
    }

    private static let vertexHeaderMask: UInt8 = 0xf0
    private static let vertexHeaderTag: UInt8 = 0xa0
    private static let indexHeaderTag: UInt8 = 0xe0
    private static let sequenceHeaderTag: UInt8 = 0xd0

    private static let maxVertexVersion = 1
    private static let maxIndexVersion = 1

    private static let vertexBlockSizeBytes = 8192
    private static let vertexBlockMaxSize = 256
    private static let byteGroupSize = 16
    private static let byteGroupDecodeLimit = 24
    private static let tailMinSizeV0 = 32
    private static let tailMinSizeV1 = 24

    /// Decodifica um buffer de vértices comprimido pelo `meshoptimizer` (versões v0 e v1).
    ///
    /// - Parameters:
    ///   - count: Quantidade de vértices a decodificar (`>= 0`).
    ///   - stride: Tamanho de cada vértice em bytes (múltiplo de 4, `4...256`).
    ///   - encoded: Fluxo de bytes codificado com cabeçalho `0xa0 | version`.
    ///   - limits: Limites de segurança aplicados antes de alocar.
    /// - Returns: Buffer decodificado com `count * stride` bytes.
    public static func decodeVertexBuffer(
        count: Int,
        stride: Int,
        _ encoded: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> [UInt8] {
        guard count >= 0 else {
            throw .invalid(context: "meshopt.vertex.count", reason: "contagem negativa")
        }
        guard stride > 0, stride <= 256, stride % 4 == 0 else {
            throw .invalid(
                context: "meshopt.vertex.stride",
                reason: "stride deve ser múltiplo de 4 entre 4 e 256"
            )
        }
        try checkLimit(encoded.count, limits.maxInputBytes, "meshopt.vertex.input")
        let outputSize = try checkedMul(count, stride, "meshopt.vertex.outputSize")
        try checkLimit(outputSize, limits.maxOutputBytes, "meshopt.vertex.output")

        guard encoded.count >= 1 else {
            throw .truncated(context: "meshopt.vertex.header")
        }
        let header = encoded[0]
        guard (header & vertexHeaderMask) == vertexHeaderTag else {
            throw .invalid(context: "meshopt.vertex.header", reason: "cabeçalho de vértice inválido")
        }
        let version = Int(header & 0x0f)
        guard version <= maxVertexVersion else {
            throw .unsupported(
                context: "meshopt.vertex.version",
                reason: "versão \(version) não suportada"
            )
        }

        let tailSize = stride + (version == 0 ? 0 : stride / 4)
        let tailSizeMin = version == 0 ? tailMinSizeV0 : tailMinSizeV1
        let tailSizePad = tailSize < tailSizeMin ? tailSizeMin : tailSize

        guard encoded.count - 1 >= tailSizePad else {
            throw .truncated(context: "meshopt.vertex.tail")
        }

        let tailOffset = encoded.count - tailSize
        var lastVertex = Array(encoded[tailOffset..<(tailOffset + stride)])
        let channelsOffset = tailOffset + stride

        var output = [UInt8](repeating: 0, count: outputSize)
        var channelScratch = [UInt8](repeating: 0, count: vertexBlockMaxSize * 4)

        let blockSizeCap = (vertexBlockSizeBytes / stride) & ~(byteGroupSize - 1)
        let vertexBlockSize = blockSizeCap < vertexBlockMaxSize ? blockSizeCap : vertexBlockMaxSize

        var dataOffset = 1
        let dataEnd = encoded.count
        var vertexOffset = 0

        while vertexOffset < count {
            let remainingVertices = count - vertexOffset
            let blockCount = remainingVertices < vertexBlockSize ? remainingVertices : vertexBlockSize

            try decodeVertexBlock(
                encoded: encoded,
                dataOffset: &dataOffset,
                dataEnd: dataEnd,
                output: &output,
                outputVertexOffset: vertexOffset,
                blockCount: blockCount,
                stride: stride,
                lastVertex: &lastVertex,
                channelsOffset: channelsOffset,
                version: version,
                scratch: &channelScratch
            )

            vertexOffset += blockCount
        }

        guard dataEnd - dataOffset == tailSizePad else {
            throw .invalid(
                context: "meshopt.vertex.tail",
                reason: "bytes residuais divergentes do tail esperado"
            )
        }

        return output
    }

    /// Decodifica um buffer de índices de triângulos comprimido pelo `meshoptimizer` (versões v0 e v1).
    ///
    /// Os índices decodificados devem caber em `indexSize` bytes (`2` ou `4`). A validação em relação
    /// à contagem de vértices não é feita aqui e deve ser aplicada pelo consumidor ou camada glTF.
    ///
    /// - Parameters:
    ///   - count: Quantidade de índices (`>= 0`, múltiplo de 3).
    ///   - indexSize: Tamanho de cada índice em bytes (`2` ou `4`).
    ///   - encoded: Fluxo codificado com cabeçalho `0xe0 | version`.
    ///   - limits: Limites de segurança aplicados antes de alocar.
    /// - Returns: Buffer decodificado em *little-endian* com `count * indexSize` bytes.
    public static func decodeIndexBuffer(
        count: Int,
        indexSize: Int,
        _ encoded: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> [UInt8] {
        guard count >= 0 else {
            throw .invalid(context: "meshopt.index.count", reason: "contagem negativa")
        }
        guard count % 3 == 0 else {
            throw .invalid(
                context: "meshopt.index.count",
                reason: "contagem de índices deve ser múltipla de 3"
            )
        }
        guard indexSize == 2 || indexSize == 4 else {
            throw .invalid(context: "meshopt.index.indexSize", reason: "indexSize deve ser 2 ou 4")
        }
        try checkLimit(encoded.count, limits.maxInputBytes, "meshopt.index.input")
        let outputSize = try checkedMul(count, indexSize, "meshopt.index.outputSize")
        try checkLimit(outputSize, limits.maxOutputBytes, "meshopt.index.output")

        let triCount = count / 3
        let minEncodedSize = try checkedAdd(
            try checkedAdd(1, triCount, "meshopt.index.minSize"),
            16,
            "meshopt.index.minSize"
        )
        guard encoded.count >= minEncodedSize else {
            throw .truncated(context: "meshopt.index.input")
        }

        let header = encoded[0]
        guard (header & 0xf0) == indexHeaderTag else {
            throw .invalid(context: "meshopt.index.header", reason: "cabeçalho de índice inválido")
        }
        let version = Int(header & 0x0f)
        guard version <= maxIndexVersion else {
            throw .unsupported(
                context: "meshopt.index.version",
                reason: "versão \(version) não suportada"
            )
        }

        var output = [UInt8](repeating: 0, count: outputSize)

        var edgeFifo = [(UInt32, UInt32)](repeating: (0xFFFF_FFFF, 0xFFFF_FFFF), count: 16)
        var vertexFifo = [UInt32](repeating: 0xFFFF_FFFF, count: 16)
        var edgeFifoOffset = 0
        var vertexFifoOffset = 0

        var next: UInt32 = 0
        var last: UInt32 = 0
        let fecMax = version >= 1 ? 13 : 15

        var codeOffset = 1
        let codeEnd = 1 + triCount
        var dataOffset = codeEnd
        let dataSafeEnd = encoded.count - 16
        let codeauxTableOffset = dataSafeEnd
        var outOffset = 0

        while codeOffset < codeEnd {
            let codetri = encoded[codeOffset]
            codeOffset += 1

            if codetri < 0xf0 {
                let fe = Int(codetri >> 4)
                let edgeIdx = (edgeFifoOffset &- 1 &- fe) & 15
                let a = edgeFifo[edgeIdx].0
                let b = edgeFifo[edgeIdx].1
                let c: UInt32

                let fec = Int(codetri & 15)
                if fec < fecMax {
                    let cf = vertexFifo[(vertexFifoOffset &- 1 &- fec) & 15]
                    c = fec == 0 ? next : cf
                    if fec == 0 {
                        next &+= 1
                        vertexFifo[vertexFifoOffset] = c
                        vertexFifoOffset = (vertexFifoOffset + 1) & 15
                    }
                } else {
                    guard dataOffset <= dataSafeEnd else {
                        throw .truncated(context: "meshopt.index.data")
                    }
                    if fec != 15 {
                        let delta = Int32(fec * 2 - 27)
                        c = last &+ UInt32(bitPattern: delta)
                    } else {
                        c = try decodeIndexDelta(
                            encoded,
                            offset: &dataOffset,
                            end: encoded.count,
                            last: last,
                            context: "meshopt.index.data"
                        )
                    }
                    last = c
                    vertexFifo[vertexFifoOffset] = c
                    vertexFifoOffset = (vertexFifoOffset + 1) & 15
                }

                edgeFifo[edgeFifoOffset] = (c, b)
                edgeFifoOffset = (edgeFifoOffset + 1) & 15
                edgeFifo[edgeFifoOffset] = (a, c)
                edgeFifoOffset = (edgeFifoOffset + 1) & 15

                try writeIndex(a, indexSize: indexSize, to: &output, at: outOffset)
                try writeIndex(b, indexSize: indexSize, to: &output, at: outOffset + indexSize)
                try writeIndex(c, indexSize: indexSize, to: &output, at: outOffset + indexSize * 2)
                outOffset += indexSize * 3
            } else if codetri < 0xfe {
                let codeaux = encoded[codeauxTableOffset + Int(codetri & 15)]
                let feb = Int(codeaux >> 4)
                let fec = Int(codeaux & 15)

                let a = next
                next &+= 1

                let bf = vertexFifo[(vertexFifoOffset &- feb) & 15]
                let b = feb == 0 ? next : bf
                if feb == 0 { next &+= 1 }

                let cf = vertexFifo[(vertexFifoOffset &- fec) & 15]
                let c = fec == 0 ? next : cf
                if fec == 0 { next &+= 1 }

                try writeIndex(a, indexSize: indexSize, to: &output, at: outOffset)
                try writeIndex(b, indexSize: indexSize, to: &output, at: outOffset + indexSize)
                try writeIndex(c, indexSize: indexSize, to: &output, at: outOffset + indexSize * 2)
                outOffset += indexSize * 3

                vertexFifo[vertexFifoOffset] = a
                vertexFifoOffset = (vertexFifoOffset + 1) & 15
                if feb == 0 {
                    vertexFifo[vertexFifoOffset] = b
                    vertexFifoOffset = (vertexFifoOffset + 1) & 15
                }
                if fec == 0 {
                    vertexFifo[vertexFifoOffset] = c
                    vertexFifoOffset = (vertexFifoOffset + 1) & 15
                }

                edgeFifo[edgeFifoOffset] = (b, a)
                edgeFifoOffset = (edgeFifoOffset + 1) & 15
                edgeFifo[edgeFifoOffset] = (c, b)
                edgeFifoOffset = (edgeFifoOffset + 1) & 15
                edgeFifo[edgeFifoOffset] = (a, c)
                edgeFifoOffset = (edgeFifoOffset + 1) & 15
            } else {
                guard dataOffset <= dataSafeEnd else {
                    throw .truncated(context: "meshopt.index.data")
                }

                let codeaux = encoded[dataOffset]
                dataOffset += 1

                let fea = codetri == 0xfe ? 0 : 15
                let feb = Int(codeaux >> 4)
                let fec = Int(codeaux & 15)

                if codeaux == 0 {
                    next = 0
                }

                var a: UInt32 = 0
                if fea == 0 {
                    a = next
                    next &+= 1
                }

                var b: UInt32
                if feb == 0 {
                    b = next
                    next &+= 1
                } else {
                    b = vertexFifo[(vertexFifoOffset &- feb) & 15]
                }

                var c: UInt32
                if fec == 0 {
                    c = next
                    next &+= 1
                } else {
                    c = vertexFifo[(vertexFifoOffset &- fec) & 15]
                }

                if fea == 15 {
                    a = try decodeIndexDelta(
                        encoded,
                        offset: &dataOffset,
                        end: encoded.count,
                        last: last,
                        context: "meshopt.index.data"
                    )
                    last = a
                }
                if feb == 15 {
                    b = try decodeIndexDelta(
                        encoded,
                        offset: &dataOffset,
                        end: encoded.count,
                        last: last,
                        context: "meshopt.index.data"
                    )
                    last = b
                }
                if fec == 15 {
                    c = try decodeIndexDelta(
                        encoded,
                        offset: &dataOffset,
                        end: encoded.count,
                        last: last,
                        context: "meshopt.index.data"
                    )
                    last = c
                }

                try writeIndex(a, indexSize: indexSize, to: &output, at: outOffset)
                try writeIndex(b, indexSize: indexSize, to: &output, at: outOffset + indexSize)
                try writeIndex(c, indexSize: indexSize, to: &output, at: outOffset + indexSize * 2)
                outOffset += indexSize * 3

                vertexFifo[vertexFifoOffset] = a
                vertexFifoOffset = (vertexFifoOffset + 1) & 15
                if feb == 0 || feb == 15 {
                    vertexFifo[vertexFifoOffset] = b
                    vertexFifoOffset = (vertexFifoOffset + 1) & 15
                }
                if fec == 0 || fec == 15 {
                    vertexFifo[vertexFifoOffset] = c
                    vertexFifoOffset = (vertexFifoOffset + 1) & 15
                }

                edgeFifo[edgeFifoOffset] = (b, a)
                edgeFifoOffset = (edgeFifoOffset + 1) & 15
                edgeFifo[edgeFifoOffset] = (c, b)
                edgeFifoOffset = (edgeFifoOffset + 1) & 15
                edgeFifo[edgeFifoOffset] = (a, c)
                edgeFifoOffset = (edgeFifoOffset + 1) & 15
            }
        }

        guard dataOffset == dataSafeEnd else {
            throw .invalid(
                context: "meshopt.index.data",
                reason: "bytes extras ou desalinhados no stream de índices"
            )
        }

        return output
    }

    /// Decodifica uma sequência genérica de índices comprimida pelo `meshoptimizer` (versões v0 e v1).
    ///
    /// Os índices decodificados devem caber em `indexSize` bytes (`2` ou `4`). A validação em relação
    /// à contagem de vértices deve ser feita pelo consumidor ou camada glTF.
    ///
    /// - Parameters:
    ///   - count: Quantidade de índices na sequência (`>= 0`).
    ///   - indexSize: Tamanho de cada índice em bytes (`2` ou `4`).
    ///   - encoded: Fluxo codificado com cabeçalho `0xd0 | version`.
    ///   - limits: Limites de segurança aplicados antes de alocar.
    /// - Returns: Buffer decodificado em *little-endian* com `count * indexSize` bytes.
    public static func decodeIndexSequence(
        count: Int,
        indexSize: Int,
        _ encoded: [UInt8],
        limits: AssetLimits = .default
    ) throws(AssetError) -> [UInt8] {
        guard count >= 0 else {
            throw .invalid(context: "meshopt.sequence.count", reason: "contagem negativa")
        }
        guard indexSize == 2 || indexSize == 4 else {
            throw .invalid(context: "meshopt.sequence.indexSize", reason: "indexSize deve ser 2 ou 4")
        }
        try checkLimit(encoded.count, limits.maxInputBytes, "meshopt.sequence.input")
        let outputSize = try checkedMul(count, indexSize, "meshopt.sequence.outputSize")
        try checkLimit(outputSize, limits.maxOutputBytes, "meshopt.sequence.output")

        let minEncodedSize = try checkedAdd(
            try checkedAdd(1, count, "meshopt.sequence.minSize"),
            4,
            "meshopt.sequence.minSize"
        )
        guard encoded.count >= minEncodedSize else {
            throw .truncated(context: "meshopt.sequence.input")
        }

        let header = encoded[0]
        guard (header & 0xf0) == sequenceHeaderTag else {
            throw .invalid(
                context: "meshopt.sequence.header",
                reason: "cabeçalho de sequência inválido"
            )
        }
        let version = Int(header & 0x0f)
        guard version <= maxIndexVersion else {
            throw .unsupported(
                context: "meshopt.sequence.version",
                reason: "versão \(version) não suportada"
            )
        }

        var output = [UInt8](repeating: 0, count: outputSize)
        var dataOffset = 1
        let dataSafeEnd = encoded.count - 4
        var last0: UInt32 = 0
        var last1: UInt32 = 0

        for i in 0..<count {
            guard dataOffset < dataSafeEnd else {
                throw .truncated(context: "meshopt.sequence.data")
            }

            var v = try decodeVByte(
                encoded,
                offset: &dataOffset,
                end: encoded.count,
                context: "meshopt.sequence.data"
            )
            let current = v & 1
            v >>= 1

            let d = (v >> 1) ^ (0 &- (v & 1))
            let index: UInt32
            if current == 0 {
                last0 &+= d
                index = last0
            } else {
                last1 &+= d
                index = last1
            }

            try writeIndex(index, indexSize: indexSize, to: &output, at: i * indexSize)
        }

        guard dataOffset == dataSafeEnd else {
            throw .invalid(
                context: "meshopt.sequence.data",
                reason: "bytes extras ou desalinhados na sequência de índices"
            )
        }

        return output
    }

    /// Aplica um filtro pós-decodificação *in-place* sobre um buffer de vértices decodificado.
    ///
    /// - Parameters:
    ///   - filter: Filtro a aplicar (`.octahedral`, `.quaternion` ou `.exponential`).
    ///   - count: Quantidade de vértices no buffer (`>= 0`).
    ///   - stride: Tamanho de cada vértice em bytes (`4` ou `8` para `.octahedral`, `8` para
    ///     `.quaternion`, múltiplo de `4` positivo para `.exponential`).
    ///   - buffer: Buffer mutável cujo tamanho deve ser exatamente `count * stride` bytes.
    public static func applyFilter(
        _ filter: Filter,
        count: Int,
        stride: Int,
        to buffer: inout [UInt8]
    ) throws(AssetError) {
        guard count >= 0 else {
            throw .invalid(context: "meshopt.filter.count", reason: "contagem negativa")
        }

        switch filter {
        case .octahedral:
            guard stride == 4 || stride == 8 else {
                throw .invalid(
                    context: "meshopt.filter.stride",
                    reason: "filtro octahedral requer stride 4 ou 8"
                )
            }
        case .quaternion:
            guard stride == 8 else {
                throw .invalid(
                    context: "meshopt.filter.stride",
                    reason: "filtro quaternion requer stride 8"
                )
            }
        case .exponential:
            guard stride > 0, stride % 4 == 0 else {
                throw .invalid(
                    context: "meshopt.filter.stride",
                    reason: "filtro exponential requer stride positivo múltiplo de 4"
                )
            }
        }

        let expectedBytes = try checkedMul(count, stride, "meshopt.filter.bufferSize")
        if buffer.count < expectedBytes {
            throw .truncated(context: "meshopt.filter.buffer")
        }
        if buffer.count > expectedBytes {
            throw .invalid(
                context: "meshopt.filter.buffer",
                reason: "tamanho do buffer (\(buffer.count)) excede count * stride (\(expectedBytes))"
            )
        }

        switch filter {
        case .octahedral:
            if stride == 4 {
                applyFilterOct8(count: count, to: &buffer)
            } else {
                applyFilterOct16(count: count, to: &buffer)
            }
        case .quaternion:
            applyFilterQuat(count: count, to: &buffer)
        case .exponential:
            let wordCount = count * (stride / 4)
            applyFilterExp(wordCount: wordCount, to: &buffer)
        }
    }

    // MARK: - Helpers internos de vértices

    private static func decodeVertexBlock(
        encoded: [UInt8],
        dataOffset: inout Int,
        dataEnd: Int,
        output: inout [UInt8],
        outputVertexOffset: Int,
        blockCount: Int,
        stride: Int,
        lastVertex: inout [UInt8],
        channelsOffset: Int,
        version: Int,
        scratch: inout [UInt8]
    ) throws(AssetError) {
        let blockCountAligned = (blockCount + byteGroupSize - 1) & ~(byteGroupSize - 1)

        let controlSize = version == 0 ? 0 : stride / 4
        guard dataEnd - dataOffset >= controlSize else {
            throw .truncated(context: "meshopt.vertex.control")
        }

        let controlOffset = dataOffset
        dataOffset += controlSize

        for k in Swift.stride(from: 0, to: stride, by: 4) {
            let ctrlByte: UInt8 = version == 0 ? 0 : encoded[controlOffset + k / 4]

            for j in 0..<4 {
                let ctrl = Int((ctrlByte >> (j * 2)) & 3)
                let dstStart = j * blockCount

                if ctrl == 3 {
                    guard dataEnd - dataOffset >= blockCount else {
                        throw .truncated(context: "meshopt.vertex.literal")
                    }
                    for i in 0..<blockCount {
                        scratch[dstStart + i] = encoded[dataOffset + i]
                    }
                    dataOffset += blockCount
                } else if ctrl == 2 {
                    for i in 0..<blockCount {
                        scratch[dstStart + i] = 0
                    }
                } else {
                    try decodeBytes(
                        encoded: encoded,
                        dataOffset: &dataOffset,
                        dataEnd: dataEnd,
                        scratch: &scratch,
                        scratchStart: dstStart,
                        alignedSize: blockCountAligned,
                        version: version,
                        ctrl: ctrl
                    )
                }
            }

            let channel: UInt8 = version == 0 ? 0 : encoded[channelsOffset + k / 4]
            switch channel & 3 {
            case 0:
                decodeDeltasU8(
                    scratch: scratch,
                    output: &output,
                    outputBase: outputVertexOffset * stride + k,
                    blockCount: blockCount,
                    stride: stride,
                    lastVertex: lastVertex,
                    lastOffset: k
                )
            case 1:
                decodeDeltasU16(
                    scratch: scratch,
                    output: &output,
                    outputBase: outputVertexOffset * stride + k,
                    blockCount: blockCount,
                    stride: stride,
                    lastVertex: lastVertex,
                    lastOffset: k
                )
            case 2:
                let rot = (32 - Int(channel >> 4)) & 31
                decodeDeltasU32Xor(
                    scratch: scratch,
                    output: &output,
                    outputBase: outputVertexOffset * stride + k,
                    blockCount: blockCount,
                    stride: stride,
                    lastVertex: lastVertex,
                    lastOffset: k,
                    rot: rot
                )
            default:
                throw .invalid(context: "meshopt.vertex.channel", reason: "tipo de canal inválido")
            }
        }

        let lastVertexStart = (outputVertexOffset + blockCount - 1) * stride
        for i in 0..<stride {
            lastVertex[i] = output[lastVertexStart + i]
        }
    }

    private static func bitWidth(version: Int, ctrl: Int, selector: Int) -> Int {
        if version == 0 {
            switch selector {
            case 0: return 0
            case 1: return 2
            case 2: return 4
            default: return 8
            }
        } else if ctrl == 0 {
            switch selector {
            case 0: return 0
            case 1: return 1
            case 2: return 2
            default: return 4
            }
        } else {
            switch selector {
            case 0: return 1
            case 1: return 2
            case 2: return 4
            default: return 8
            }
        }
    }

    private static func decodeBytes(
        encoded: [UInt8],
        dataOffset: inout Int,
        dataEnd: Int,
        scratch: inout [UInt8],
        scratchStart: Int,
        alignedSize: Int,
        version: Int,
        ctrl: Int
    ) throws(AssetError) {
        let groupCount = alignedSize / byteGroupSize
        let headerSize = (groupCount + 3) / 4
        guard dataEnd - dataOffset >= headerSize else {
            throw .truncated(context: "meshopt.vertex.byteHeader")
        }

        let headerOffset = dataOffset
        dataOffset += headerSize

        for group in 0..<groupCount {
            guard dataEnd - dataOffset >= byteGroupDecodeLimit else {
                throw .truncated(context: "meshopt.vertex.byteGroup")
            }

            let selector = Int((encoded[headerOffset + group / 4] >> ((group % 4) * 2)) & 3)
            let bits = bitWidth(version: version, ctrl: ctrl, selector: selector)

            try decodeBytesGroup(
                encoded: encoded,
                dataOffset: &dataOffset,
                dataEnd: dataEnd,
                scratch: &scratch,
                dst: scratchStart + group * byteGroupSize,
                bits: bits
            )
        }
    }

    private static func decodeBytesGroup(
        encoded: [UInt8],
        dataOffset: inout Int,
        dataEnd: Int,
        scratch: inout [UInt8],
        dst: Int,
        bits: Int
    ) throws(AssetError) {
        switch bits {
        case 0:
            for i in 0..<byteGroupSize {
                scratch[dst + i] = 0
            }
        case 1:
            var dataVar = dataOffset + 2
            for chunk in 0..<2 {
                let byte = encoded[dataOffset + chunk]
                for bit in 0..<8 {
                    if ((byte >> bit) & 1) == 1 {
                        guard dataVar < dataEnd else {
                            throw .truncated(context: "meshopt.vertex.byteGroup")
                        }
                        scratch[dst + chunk * 8 + bit] = encoded[dataVar]
                        dataVar += 1
                    } else {
                        scratch[dst + chunk * 8 + bit] = 0
                    }
                }
            }
            dataOffset = dataVar
        case 2:
            var dataVar = dataOffset + 4
            for chunk in 0..<4 {
                let byte = encoded[dataOffset + chunk]
                for sub in 0..<4 {
                    let enc = (byte >> ((3 - sub) * 2)) & 3
                    if enc == 3 {
                        guard dataVar < dataEnd else {
                            throw .truncated(context: "meshopt.vertex.byteGroup")
                        }
                        scratch[dst + chunk * 4 + sub] = encoded[dataVar]
                        dataVar += 1
                    } else {
                        scratch[dst + chunk * 4 + sub] = enc
                    }
                }
            }
            dataOffset = dataVar
        case 4:
            var dataVar = dataOffset + 8
            for chunk in 0..<8 {
                let byte = encoded[dataOffset + chunk]
                let hi = (byte >> 4) & 15
                if hi == 15 {
                    guard dataVar < dataEnd else {
                        throw .truncated(context: "meshopt.vertex.byteGroup")
                    }
                    scratch[dst + chunk * 2] = encoded[dataVar]
                    dataVar += 1
                } else {
                    scratch[dst + chunk * 2] = hi
                }

                let lo = byte & 15
                if lo == 15 {
                    guard dataVar < dataEnd else {
                        throw .truncated(context: "meshopt.vertex.byteGroup")
                    }
                    scratch[dst + chunk * 2 + 1] = encoded[dataVar]
                    dataVar += 1
                } else {
                    scratch[dst + chunk * 2 + 1] = lo
                }
            }
            dataOffset = dataVar
        case 8:
            for i in 0..<byteGroupSize {
                scratch[dst + i] = encoded[dataOffset + i]
            }
            dataOffset += byteGroupSize
        default:
            throw .invalid(context: "meshopt.vertex.byteGroup", reason: "largura de bits inválida")
        }
    }

    private static func decodeDeltasU8(
        scratch: [UInt8],
        output: inout [UInt8],
        outputBase: Int,
        blockCount: Int,
        stride: Int,
        lastVertex: [UInt8],
        lastOffset: Int
    ) {
        for lane in 0..<4 {
            var p = lastVertex[lastOffset + lane]
            var outOffset = outputBase + lane
            let bufBase = lane * blockCount

            for i in 0..<blockCount {
                let v = scratch[bufBase + i]
                let d = (0 &- (v & 1)) ^ (v >> 1)
                let decoded = d &+ p
                output[outOffset] = decoded
                p = decoded
                outOffset += stride
            }
        }
    }

    private static func decodeDeltasU16(
        scratch: [UInt8],
        output: inout [UInt8],
        outputBase: Int,
        blockCount: Int,
        stride: Int,
        lastVertex: [UInt8],
        lastOffset: Int
    ) {
        for lane in 0..<2 {
            let byteOff = lane * 2
            var p =
                UInt16(lastVertex[lastOffset + byteOff])
                | (UInt16(lastVertex[lastOffset + byteOff + 1]) << 8)
            var outOffset = outputBase + byteOff
            let bufBase0 = byteOff * blockCount
            let bufBase1 = (byteOff + 1) * blockCount

            for i in 0..<blockCount {
                let v = UInt16(scratch[bufBase0 + i]) | (UInt16(scratch[bufBase1 + i]) << 8)
                let d = (0 &- (v & 1)) ^ (v >> 1)
                let decoded = d &+ p
                output[outOffset] = UInt8(truncatingIfNeeded: decoded)
                output[outOffset + 1] = UInt8(truncatingIfNeeded: decoded >> 8)
                p = decoded
                outOffset += stride
            }
        }
    }

    private static func decodeDeltasU32Xor(
        scratch: [UInt8],
        output: inout [UInt8],
        outputBase: Int,
        blockCount: Int,
        stride: Int,
        lastVertex: [UInt8],
        lastOffset: Int,
        rot: Int
    ) {
        var p =
            UInt32(lastVertex[lastOffset])
            | (UInt32(lastVertex[lastOffset + 1]) << 8)
            | (UInt32(lastVertex[lastOffset + 2]) << 16)
            | (UInt32(lastVertex[lastOffset + 3]) << 24)
        var outOffset = outputBase
        let b1 = blockCount
        let b2 = blockCount * 2
        let b3 = blockCount * 3
        let r = UInt32(rot)
        let invR = UInt32((32 - rot) & 31)

        for i in 0..<blockCount {
            let v =
                UInt32(scratch[i])
                | (UInt32(scratch[b1 + i]) << 8)
                | (UInt32(scratch[b2 + i]) << 16)
                | (UInt32(scratch[b3 + i]) << 24)
            let rotated = (v << r) | (v >> invR)
            let decoded = rotated ^ p
            output[outOffset] = UInt8(truncatingIfNeeded: decoded)
            output[outOffset + 1] = UInt8(truncatingIfNeeded: decoded >> 8)
            output[outOffset + 2] = UInt8(truncatingIfNeeded: decoded >> 16)
            output[outOffset + 3] = UInt8(truncatingIfNeeded: decoded >> 24)
            p = decoded
            outOffset += stride
        }
    }

    // MARK: - Helpers internos de índices

    private static func decodeVByte(
        _ encoded: [UInt8],
        offset: inout Int,
        end: Int,
        context: String
    ) throws(AssetError) -> UInt32 {
        guard offset < end else {
            throw .truncated(context: context)
        }
        let lead = encoded[offset]
        offset += 1

        if lead < 128 {
            return UInt32(lead)
        }

        var result = UInt32(lead & 127)
        var shift: UInt32 = 7

        // Máximo de 4 bytes extras (total <= 5 bytes para 32 bits).
        for _ in 0..<4 {
            guard offset < end else {
                throw .truncated(context: context)
            }
            let group = encoded[offset]
            offset += 1
            result |= UInt32(group & 127) << shift
            shift += 7
            if group < 128 {
                break
            }
        }

        return result
    }

    private static func decodeIndexDelta(
        _ encoded: [UInt8],
        offset: inout Int,
        end: Int,
        last: UInt32,
        context: String
    ) throws(AssetError) -> UInt32 {
        let v = try decodeVByte(encoded, offset: &offset, end: end, context: context)
        let d = (v >> 1) ^ (0 &- (v & 1))
        return last &+ d
    }

    @inline(__always)
    private static func writeIndex(
        _ value: UInt32,
        indexSize: Int,
        to output: inout [UInt8],
        at offset: Int
    ) throws(AssetError) {
        if indexSize == 2 {
            guard let u16 = UInt16(exactly: value) else {
                throw .invalid(context: "meshopt.index.value", reason: "índice \(value) excede 16 bits")
            }
            output[offset] = UInt8(truncatingIfNeeded: u16)
            output[offset + 1] = UInt8(truncatingIfNeeded: u16 >> 8)
        } else {
            output[offset] = UInt8(truncatingIfNeeded: value)
            output[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            output[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            output[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
    }

    // MARK: - Helpers internos de filtros

    private static func applyFilterOct8(count: Int, to buffer: inout [UInt8]) {
        let maxVal: Float = 127.0
        for i in 0..<count {
            let base = i * 4
            var x = Float(Int8(bitPattern: buffer[base]))
            var y = Float(Int8(bitPattern: buffer[base + 1]))
            let z = Float(Int8(bitPattern: buffer[base + 2])) - abs(x) - abs(y)

            let t: Float = z >= 0.0 ? 0.0 : z
            x += x >= 0.0 ? t : -t
            y += y >= 0.0 ? t : -t

            let length = (x * x + y * y + z * z).squareRoot()
            // Evita divisão por zero e NaN caso todos os componentes sejam 0 em entrada hostil.
            let scale: Float = length > 0.0 ? maxVal / length : 0.0

            let xf = Int(x * scale + (x >= 0.0 ? 0.5 : -0.5))
            let yf = Int(y * scale + (y >= 0.0 ? 0.5 : -0.5))
            let zf = Int(z * scale + (z >= 0.0 ? 0.5 : -0.5))

            buffer[base] = UInt8(bitPattern: Int8(truncatingIfNeeded: xf))
            buffer[base + 1] = UInt8(bitPattern: Int8(truncatingIfNeeded: yf))
            buffer[base + 2] = UInt8(bitPattern: Int8(truncatingIfNeeded: zf))
        }
    }

    private static func applyFilterOct16(count: Int, to buffer: inout [UInt8]) {
        let maxVal: Float = 32767.0
        for i in 0..<count {
            let base = i * 8
            var x = Float(readI16LE(buffer, at: base))
            var y = Float(readI16LE(buffer, at: base + 2))
            let z = Float(readI16LE(buffer, at: base + 4)) - abs(x) - abs(y)

            let t: Float = z >= 0.0 ? 0.0 : z
            x += x >= 0.0 ? t : -t
            y += y >= 0.0 ? t : -t

            let length = (x * x + y * y + z * z).squareRoot()
            // Evita divisão por zero e NaN caso todos os componentes sejam 0 em entrada hostil.
            let scale: Float = length > 0.0 ? maxVal / length : 0.0

            let xf = Int(x * scale + (x >= 0.0 ? 0.5 : -0.5))
            let yf = Int(y * scale + (y >= 0.0 ? 0.5 : -0.5))
            let zf = Int(z * scale + (z >= 0.0 ? 0.5 : -0.5))

            writeI16LE(Int16(truncatingIfNeeded: xf), to: &buffer, at: base)
            writeI16LE(Int16(truncatingIfNeeded: yf), to: &buffer, at: base + 2)
            writeI16LE(Int16(truncatingIfNeeded: zf), to: &buffer, at: base + 4)
        }
    }

    private static func applyFilterQuat(count: Int, to buffer: inout [UInt8]) {
        let scale: Float = 32767.0 / Float(2.0).squareRoot()
        for i in 0..<count {
            let base = i * 8
            let d0 = readI16LE(buffer, at: base)
            let d1 = readI16LE(buffer, at: base + 2)
            let d2 = readI16LE(buffer, at: base + 4)
            let d3 = readI16LE(buffer, at: base + 6)

            let sf = Int(d3) | 3
            let s = Float(sf)

            let x = Float(d0)
            let y = Float(d1)
            let z = Float(d2)

            let ws = s * s
            let ww = ws * 2.0 - x * x - y * y - z * z
            let w = ww >= 0.0 ? ww.squareRoot() : 0.0

            let ss = scale / s

            let xf = Int16(truncatingIfNeeded: Int(x * ss + (x >= 0.0 ? 0.5 : -0.5)))
            let yf = Int16(truncatingIfNeeded: Int(y * ss + (y >= 0.0 ? 0.5 : -0.5)))
            let zf = Int16(truncatingIfNeeded: Int(z * ss + (z >= 0.0 ? 0.5 : -0.5)))
            let wf = Int16(truncatingIfNeeded: Int(w * ss + 0.5))

            let qc = Int(d3) & 3
            writeI16LE(wf, to: &buffer, at: base + ((qc + 0) & 3) * 2)
            writeI16LE(xf, to: &buffer, at: base + ((qc + 1) & 3) * 2)
            writeI16LE(yf, to: &buffer, at: base + ((qc + 2) & 3) * 2)
            writeI16LE(zf, to: &buffer, at: base + ((qc + 3) & 3) * 2)
        }
    }

    private static func applyFilterExp(wordCount: Int, to buffer: inout [UInt8]) {
        for i in 0..<wordCount {
            let base = i * 4
            let v =
                UInt32(buffer[base])
                | (UInt32(buffer[base + 1]) << 8)
                | (UInt32(buffer[base + 2]) << 16)
                | (UInt32(buffer[base + 3]) << 24)

            let signedV = Int32(bitPattern: v)
            let mantissa = (signedV << 8) >> 8
            let exponent = signedV >> 24

            let expBits = UInt32(bitPattern: exponent &+ 127) << 23
            let decoded = (Float(bitPattern: expBits) * Float(mantissa)).bitPattern

            buffer[base] = UInt8(truncatingIfNeeded: decoded)
            buffer[base + 1] = UInt8(truncatingIfNeeded: decoded >> 8)
            buffer[base + 2] = UInt8(truncatingIfNeeded: decoded >> 16)
            buffer[base + 3] = UInt8(truncatingIfNeeded: decoded >> 24)
        }
    }

    @inline(__always)
    private static func readI16LE(_ buffer: [UInt8], at offset: Int) -> Int16 {
        let u = UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
        return Int16(bitPattern: u)
    }

    @inline(__always)
    private static func writeI16LE(_ value: Int16, to buffer: inout [UInt8], at offset: Int) {
        let u = UInt16(bitPattern: value)
        buffer[offset] = UInt8(truncatingIfNeeded: u)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: u >> 8)
    }
}
