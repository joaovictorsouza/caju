/// Leitor big-endian com verificação de limites. Nunca indexa fora do buffer.
struct CajuByteReader {
    let bytes: [UInt8]

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count - 2 else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    func i16(_ offset: Int) -> Int16? {
        guard let v = u16(offset) else { return nil }
        return Int16(bitPattern: v)
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(bytes[offset + i]) }
        return v
    }

    /// `true` se `[offset, offset + length)` cabe no buffer.
    func contains(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= bytes.count - length
    }
}
