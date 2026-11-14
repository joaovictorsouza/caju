#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    import Musl
#endif

/// Quaternion unitário de rotação (`x, y, z, w`).
public struct CajuQuat: Sendable, Equatable, Hashable {
    public var storage: SIMD4<Float>

    @inlinable public init(x: Float, y: Float, z: Float, w: Float) { storage = SIMD4(x, y, z, w) }

    public static let identity = CajuQuat(x: 0, y: 0, z: 0, w: 1)

    @inlinable public var x: Float { storage.x }
    @inlinable public var y: Float { storage.y }
    @inlinable public var z: Float { storage.z }
    @inlinable public var w: Float { storage.w }

    /// Rotação de `radians` em torno de `axis`; `nil` se o eixo não puder ser normalizado.
    public init?(axis: CajuVec3, radians: Float) {
        guard let n = axis.normalized() else { return nil }
        let half = radians * 0.5
        let s = sinf(half)
        self.init(x: n.x * s, y: n.y * s, z: n.z * s, w: cosf(half))
    }

    @inlinable public var conjugate: Self { Self(x: -x, y: -y, z: -z, w: w) }

    /// Composição: aplica `rhs` primeiro, depois `lhs`.
    @inlinable public static func * (lhs: Self, rhs: Self) -> Self {
        Self(
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z
        )
    }

    /// Gira `v`.
    @inlinable public func rotate(_ v: CajuVec3) -> CajuVec3 {
        let u = CajuVec3(x, y, z)
        let t = u.cross(v) * 2
        return v + t * w + u.cross(t)
    }

    /// Versão normalizada, ou `nil` se a norma não for finita e positiva.
    @inlinable public func normalized() -> Self? {
        let l = (storage * storage).sum().squareRoot()
        guard l.isFinite, l > 0 else { return nil }
        let s = storage * (1 / l)
        return Self(x: s.x, y: s.y, z: s.z, w: s.w)
    }
}
