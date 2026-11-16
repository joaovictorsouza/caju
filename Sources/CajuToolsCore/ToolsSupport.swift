import Foundation

/// Limites aplicados antes de alocar memória ou indexar dados externos em `CajuTools`.
public struct ToolsLimits: Sendable, Equatable {
    /// Tamanho máximo de entrada em bytes (`256 MiB`).
    public var maxInputBytes: Int
    /// Tamanho máximo de saída decodificada em bytes (`512 MiB`).
    public var maxOutputBytes: Int
    /// Dimensão máxima de largura ou altura de imagem em pixels (`16 384`).
    public var maxImageDimension: Int
    /// Profundidade máxima de aninhamento JSON (`64`).
    public var maxJSONDepth: Int
    /// Quantidade máxima de elementos em coleções JSON/glTF/KVD (`1 048 576`).
    public var maxElements: Int
    /// Quantidade máxima de níveis de mip em KTX2 (`32`).
    public var maxMipLevels: Int

    public init(
        maxInputBytes: Int = 256 << 20,
        maxOutputBytes: Int = 512 << 20,
        maxImageDimension: Int = 16_384,
        maxJSONDepth: Int = 64,
        maxElements: Int = 1 << 20,
        maxMipLevels: Int = 32
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxOutputBytes = maxOutputBytes
        self.maxImageDimension = maxImageDimension
        self.maxJSONDepth = maxJSONDepth
        self.maxElements = maxElements
        self.maxMipLevels = maxMipLevels
    }

    /// Limites padrão conservadores.
    public static let `default` = ToolsLimits()
}

// MARK: - Aritmética segura e limites

func checkedAdd(_ a: Int, _ b: Int, _ context: String) throws(CajuToolsError) -> Int {
    let (result, overflow) = a.addingReportingOverflow(b)
    if overflow {
        throw .invalid(context: context, reason: "estouro inteiro na soma")
    }
    return result
}

func checkedMul(_ a: Int, _ b: Int, _ context: String) throws(CajuToolsError) -> Int {
    let (result, overflow) = a.multipliedReportingOverflow(by: b)
    if overflow {
        throw .invalid(context: context, reason: "estouro inteiro na multiplicação")
    }
    return result
}

func checkLimit(_ requested: Int, _ limit: Int, _ context: String) throws(CajuToolsError) {
    guard limit >= 0 else {
        throw .limitExceeded(context: context, limit: limit, requested: requested)
    }
    guard requested <= limit else {
        throw .limitExceeded(context: context, limit: limit, requested: requested)
    }
}

func checkLimitUInt64(_ requested: UInt64, _ limit: Int, _ context: String) throws(CajuToolsError) -> Int {
    guard limit >= 0, requested <= UInt64(limit) else {
        throw .limitExceeded(context: context, limit: limit, requested: Int(clamping: requested))
    }
    return Int(requested)
}

// MARK: - Leitor e escritor de bytes seguro

struct ToolsByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int {
        bytes.count - offset
    }

    mutating func seek(to target: Int, context: String) throws(CajuToolsError) {
        guard target >= 0, target <= bytes.count else {
            throw .truncated(context: context)
        }
        offset = target
    }

    mutating func skip(_ count: Int, context: String) throws(CajuToolsError) {
        guard count >= 0, remaining >= count else {
            throw .truncated(context: context)
        }
        offset += count
    }

    mutating func readU8(_ context: String) throws(CajuToolsError) -> UInt8 {
        guard offset < bytes.count else {
            throw .truncated(context: context)
        }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func readU16LE(_ context: String) throws(CajuToolsError) -> UInt16 {
        guard remaining >= 2 else {
            throw .truncated(context: context)
        }
        let v = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return v
    }

    mutating func readU32LE(_ context: String) throws(CajuToolsError) -> UInt32 {
        guard remaining >= 4 else {
            throw .truncated(context: context)
        }
        let v =
            UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return v
    }

    mutating func readU32BE(_ context: String) throws(CajuToolsError) -> UInt32 {
        guard remaining >= 4 else {
            throw .truncated(context: context)
        }
        let v =
            (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        offset += 4
        return v
    }

    mutating func readU64LE(_ context: String) throws(CajuToolsError) -> UInt64 {
        guard remaining >= 8 else {
            throw .truncated(context: context)
        }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(bytes[offset + i]) << UInt64(8 * i)
        }
        offset += 8
        return v
    }

    mutating func readBytes(_ count: Int, context: String) throws(CajuToolsError) -> [UInt8] {
        guard count >= 0, remaining >= count else {
            throw .truncated(context: context)
        }
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }
}

func appendU32LE(_ value: UInt32, to buffer: inout [UInt8]) {
    buffer.append(UInt8(truncatingIfNeeded: value))
    buffer.append(UInt8(truncatingIfNeeded: value >> 8))
    buffer.append(UInt8(truncatingIfNeeded: value >> 16))
    buffer.append(UInt8(truncatingIfNeeded: value >> 24))
}

func writeU32LE(_ value: UInt32, at offset: Int, in buffer: inout [UInt8]) {
    buffer[offset] = UInt8(truncatingIfNeeded: value)
    buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

func writeU64LE(_ value: UInt64, at offset: Int, in buffer: inout [UInt8]) {
    for i in 0..<8 {
        buffer[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i))
    }
}

func padToAlignment(_ alignment: Int, buffer: inout [UInt8]) {
    let rem = buffer.count % alignment
    if rem != 0 {
        for _ in 0..<(alignment - rem) {
            buffer.append(0)
        }
    }
}

// MARK: - E/S de arquivos

func readFileBytes(atPath path: String, limits: ToolsLimits) throws(CajuToolsError) -> [UInt8] {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        throw .io(path: path, reason: "arquivo não encontrado")
    }
    guard !isDir.boolValue else {
        throw .io(path: path, reason: "caminho aponta para um diretório")
    }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw .io(path: path, reason: error.localizedDescription)
    }
    try checkLimit(data.count, limits.maxInputBytes, "input.size")
    return [UInt8](data)
}

func writeFileBytes(_ bytes: [UInt8], toPath path: String) throws(CajuToolsError) {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(bytes).write(to: url, options: .atomic)
    } catch {
        throw .io(path: path, reason: error.localizedDescription)
    }
}

func writeUTF8Text(_ text: String, toPath path: String) throws(CajuToolsError) {
    try writeFileBytes(Array(text.utf8), toPath: path)
}

// MARK: - SHA-256 determinístico em Swift puro

/// Implementação pura e multiplataforma de SHA-256 (FIPS 180-4) para hashes determinísticos.
public enum ToolsSHA256 {
    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    /// Calcula o resumo SHA-256 em hexadecimal minúsculo (64 caracteres).
    public static func hexDigest(_ bytes: [UInt8]) -> String {
        var h0: UInt32 = 0x6a09_e667
        var h1: UInt32 = 0xbb67_ae85
        var h2: UInt32 = 0x3c6e_f372
        var h3: UInt32 = 0xa54f_f53a
        var h4: UInt32 = 0x510e_527f
        var h5: UInt32 = 0x9b05_688c
        var h6: UInt32 = 0x1f83_d9ab
        var h7: UInt32 = 0x5be0_cd19

        let bitLength = UInt64(bytes.count) &* 8
        var padded = bytes
        padded.append(0x80)
        while (padded.count % 64) != 56 {
            padded.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> shift))
        }

        var w = [UInt32](repeating: 0, count: 64)
        var chunkStart = 0
        while chunkStart < padded.count {
            for i in 0..<16 {
                let idx = chunkStart + i * 4
                w[i] =
                    (UInt32(padded[idx]) << 24)
                    | (UInt32(padded[idx + 1]) << 16)
                    | (UInt32(padded[idx + 2]) << 8)
                    | UInt32(padded[idx + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h0 &+= a
            h1 &+= b
            h2 &+= c
            h3 &+= d
            h4 &+= e
            h5 &+= f
            h6 &+= g
            h7 &+= h
            chunkStart += 64
        }

        let words = [h0, h1, h2, h3, h4, h5, h6, h7]
        let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for word in words {
            for shift in stride(from: 28, through: 0, by: -4) {
                let nibble = Int((word >> shift) & 0xF)
                out.append(hexDigits[nibble])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

// MARK: - JSON determinístico (chaves ordenadas, idêntico em macOS e Linux)

enum DeterministicJSON {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([DeterministicJSON])
    case members([Member])

    /// Par chave/valor num `struct` (tupla recursiva no `enum` dá "circular reference" no Swift 6.2 do CI).
    struct Member {
        let key: String
        let value: DeterministicJSON
    }

    static func object(_ pairs: [(String, DeterministicJSON)]) -> DeterministicJSON {
        .members(pairs.map { Member(key: $0.0, value: $0.1) })
    }

    func format(indent: Int = 0) -> String {
        var out = ""
        appendFormatted(to: &out, indent: indent)
        out.append("\n")
        return out
    }

    private func appendFormatted(to out: inout String, indent: Int) {
        switch self {
        case .string(let s):
            appendEscapedString(s, to: &out)
        case .int(let n):
            out.append(String(n))
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .array(let items):
            if items.isEmpty {
                out.append("[]")
                return
            }
            out.append("[\n")
            let childIndent = indent + 2
            let pad = String(repeating: " ", count: childIndent)
            for (idx, item) in items.enumerated() {
                out.append(pad)
                item.appendFormatted(to: &out, indent: childIndent)
                if idx + 1 < items.count {
                    out.append(",")
                }
                out.append("\n")
            }
            out.append(String(repeating: " ", count: indent))
            out.append("]")
        case .members(let pairs):
            let sorted = pairs.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            if sorted.isEmpty {
                out.append("{}")
                return
            }
            out.append("{\n")
            let childIndent = indent + 2
            let pad = String(repeating: " ", count: childIndent)
            for (idx, member) in sorted.enumerated() {
                let key = member.key
                let value = member.value
                out.append(pad)
                appendEscapedString(key, to: &out)
                out.append(": ")
                value.appendFormatted(to: &out, indent: childIndent)
                if idx + 1 < sorted.count {
                    out.append(",")
                }
                out.append("\n")
            }
            out.append(String(repeating: " ", count: indent))
            out.append("}")
        }
    }

    private func appendEscapedString(_ string: String, to out: inout String) {
        out.append("\"")
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x00..<0x20:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                out.append("\\u")
                out.append(String(repeating: "0", count: max(0, 4 - hex.count)))
                out.append(hex)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }
}
