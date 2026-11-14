/// Leitor de bytes com verificação de limites; toda leitura valida antes de indexar.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func seek(to position: Int, context: String) throws(AssetError) {
        guard position >= 0, position <= bytes.count else { throw .truncated(context: context) }
        offset = position
    }

    mutating func skip(_ count: Int, context: String) throws(AssetError) {
        guard count >= 0, count <= remaining else { throw .truncated(context: context) }
        offset += count
    }

    mutating func readU8(_ context: String) throws(AssetError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated(context: context) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readU16LE(_ context: String) throws(AssetError) -> UInt16 {
        guard remaining >= 2 else { throw .truncated(context: context) }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func readU32LE(_ context: String) throws(AssetError) -> UInt32 {
        guard remaining >= 4 else { throw .truncated(context: context) }
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << UInt32(8 * i) }
        return v
    }

    mutating func readU64LE(_ context: String) throws(AssetError) -> UInt64 {
        guard remaining >= 8 else { throw .truncated(context: context) }
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << UInt64(8 * i) }
        return v
    }

    mutating func readU16BE(_ context: String) throws(AssetError) -> UInt16 {
        guard remaining >= 2 else { throw .truncated(context: context) }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func readU32BE(_ context: String) throws(AssetError) -> UInt32 {
        guard remaining >= 4 else { throw .truncated(context: context) }
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(bytes[offset + i]) }
        return v
    }

    /// Cópia de `count` bytes a partir da posição atual (valida antes de alocar).
    mutating func readBytes(_ count: Int, context: String) throws(AssetError) -> [UInt8] {
        guard count >= 0, count <= remaining else { throw .truncated(context: context) }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// Soma/multiplicação com verificação de estouro; falha como `AssetError.invalid`.
@inline(__always)
func checkedMul(_ a: Int, _ b: Int, _ context: String) throws(AssetError) -> Int {
    let (r, o) = a.multipliedReportingOverflow(by: b)
    guard !o else { throw .invalid(context: context, reason: "overflow aritmético") }
    return r
}

@inline(__always)
func checkedAdd(_ a: Int, _ b: Int, _ context: String) throws(AssetError) -> Int {
    let (r, o) = a.addingReportingOverflow(b)
    guard !o else { throw .invalid(context: context, reason: "overflow aritmético") }
    return r
}

/// Falha com `limitExceeded` se `requested > limit` (chamar ANTES de alocar).
@inline(__always)
func checkLimit(_ requested: Int, _ limit: Int, _ context: String) throws(AssetError) {
    guard requested <= limit else {
        throw .limitExceeded(context: context, limit: limit, requested: requested)
    }
}
