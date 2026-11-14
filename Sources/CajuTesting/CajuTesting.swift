/// Gerador pseudoaleatório PCG-XSH-RR 32 bits, **semeável e determinístico**.
///
/// Testes e *fuzz* usam este gerador (nunca aleatoriedade não semeada; `docs/standards/testes.md`).
///
/// ```swift
/// var rng = CajuPCG32(seed: 42)
/// let f = rng.nextFloat(in: -1...1)
/// ```
public struct CajuPCG32: RandomNumberGenerator, Sendable {
    private var state: UInt64
    private let increment: UInt64 = 1_442_695_040_888_963_407

    public init(seed: UInt64) {
        state = 0
        _ = nextUInt32()
        state &+= seed
        _ = nextUInt32()
    }

    public mutating func nextUInt32() -> UInt32 {
        let old = state
        state = old &* 6_364_136_223_846_793_005 &+ increment
        let xorshifted = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
        let rot = UInt32(truncatingIfNeeded: old >> 59)
        return (xorshifted >> rot) | (xorshifted << ((~rot &+ 1) & 31))
    }

    public mutating func next() -> UInt64 {
        (UInt64(nextUInt32()) << 32) | UInt64(nextUInt32())
    }

    /// Valor uniforme em `range` (24 bits de mantissa).
    public mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        let unit = Float(nextUInt32() >> 8) / Float(1 << 24)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

/// Executa um corpo por iteração com um gerador semeado por iteração, para reproduzir falhas.
public enum CajuFuzz {
    /// Chama `body` `iterations` vezes; a iteração `i` recebe `CajuPCG32(seed: seed &+ i)`.
    public static func run(
        seed: UInt64 = 0xCA11,
        iterations: Int,
        _ body: (inout CajuPCG32, Int) throws -> Void
    ) rethrows {
        for i in 0..<iterations {
            var rng = CajuPCG32(seed: seed &+ UInt64(i))
            try body(&rng, i)
        }
    }
}
