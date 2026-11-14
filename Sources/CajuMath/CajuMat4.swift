/// Matriz 4×4 em ordem de colunas (convenção de coluna: `M * v`).
public struct CajuMat4: Sendable, Equatable {
    public var c0: SIMD4<Float>
    public var c1: SIMD4<Float>
    public var c2: SIMD4<Float>
    public var c3: SIMD4<Float>

    @inlinable public init(
        columns c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>
    ) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }

    public static let identity = CajuMat4(
        columns: SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))

    @inlinable public static func translation(_ t: CajuVec3) -> Self {
        Self(
            columns: SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1))
    }

    @inlinable public static func scale(_ s: CajuVec3) -> Self {
        Self(
            columns: SIMD4(s.x, 0, 0, 0), SIMD4(0, s.y, 0, 0), SIMD4(0, 0, s.z, 0),
            SIMD4(0, 0, 0, 1))
    }

    @inlinable public static func rotation(_ q: CajuQuat) -> Self {
        let (x, y, z, w) = (q.x, q.y, q.z, q.w)
        return Self(
            columns: SIMD4(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0),
            SIMD4(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0),
            SIMD4(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0),
            SIMD4(0, 0, 0, 1))
    }

    @inlinable public static func * (a: Self, b: Self) -> Self {
        Self(columns: a * b.c0, a * b.c1, a * b.c2, a * b.c3)
    }

    @inlinable public static func * (m: Self, v: SIMD4<Float>) -> SIMD4<Float> {
        m.c0 * v.x + m.c1 * v.y + m.c2 * v.z + m.c3 * v.w
    }

    /// Transforma um ponto (w = 1).
    @inlinable public func transformPoint(_ p: CajuVec3) -> CajuVec3 {
        let r = self * SIMD4(p.x, p.y, p.z, 1)
        return CajuVec3(r.x, r.y, r.z)
    }

    @inlinable public var transposed: Self {
        Self(
            columns: SIMD4(c0.x, c1.x, c2.x, c3.x), SIMD4(c0.y, c1.y, c2.y, c3.y),
            SIMD4(c0.z, c1.z, c2.z, c3.z), SIMD4(c0.w, c1.w, c2.w, c3.w))
    }
}
