/// Vetor de 2 componentes (`Float`).
public struct CajuVec2: Sendable, Equatable, Hashable {
    public var x: Float
    public var y: Float

    @inlinable public init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }

    public static let zero = CajuVec2(0, 0)

    @inlinable public static func + (a: Self, b: Self) -> Self { Self(a.x + b.x, a.y + b.y) }
    @inlinable public static func - (a: Self, b: Self) -> Self { Self(a.x - b.x, a.y - b.y) }
    @inlinable public static func * (v: Self, s: Float) -> Self { Self(v.x * s, v.y * s) }
    @inlinable public static prefix func - (v: Self) -> Self { Self(-v.x, -v.y) }

    @inlinable public func dot(_ o: Self) -> Float { x * o.x + y * o.y }
    @inlinable public var lengthSquared: Float { dot(self) }
    @inlinable public var length: Float { lengthSquared.squareRoot() }
}

/// Vetor de 3 componentes (`Float`), armazenado como `SIMD3<Float>`.
///
/// ```swift
/// let c = CajuVec3(1, 0, 0).cross(CajuVec3(0, 1, 0))  // (0, 0, 1)
/// ```
public struct CajuVec3: Sendable, Equatable, Hashable {
    public var storage: SIMD3<Float>

    @inlinable public init(_ x: Float, _ y: Float, _ z: Float) { storage = SIMD3(x, y, z) }
    @inlinable public init(storage: SIMD3<Float>) { self.storage = storage }

    @inlinable public var x: Float {
        get { storage.x }
        set { storage.x = newValue }
    }
    @inlinable public var y: Float {
        get { storage.y }
        set { storage.y = newValue }
    }
    @inlinable public var z: Float {
        get { storage.z }
        set { storage.z = newValue }
    }

    public static let zero = CajuVec3(0, 0, 0)
    public static let one = CajuVec3(1, 1, 1)
    public static let unitX = CajuVec3(1, 0, 0)
    public static let unitY = CajuVec3(0, 1, 0)
    public static let unitZ = CajuVec3(0, 0, 1)

    @inlinable public static func + (a: Self, b: Self) -> Self { Self(storage: a.storage + b.storage) }
    @inlinable public static func - (a: Self, b: Self) -> Self { Self(storage: a.storage - b.storage) }
    @inlinable public static func * (v: Self, s: Float) -> Self { Self(storage: v.storage * s) }
    @inlinable public static prefix func - (v: Self) -> Self { Self(storage: -v.storage) }

    @inlinable public func dot(_ o: Self) -> Float { (storage * o.storage).sum() }

    @inlinable public func cross(_ o: Self) -> Self {
        Self(
            y * o.z - z * o.y,
            z * o.x - x * o.z,
            x * o.y - y * o.x
        )
    }

    @inlinable public var lengthSquared: Float { dot(self) }
    @inlinable public var length: Float { lengthSquared.squareRoot() }

    /// Vetor de comprimento 1, ou `nil` se o comprimento não for finito e positivo.
    @inlinable public func normalized() -> Self? {
        let l = length
        guard l.isFinite, l > 0 else { return nil }
        return self * (1 / l)
    }
}

/// Vetor de 4 componentes (`Float`), armazenado como `SIMD4<Float>`.
public struct CajuVec4: Sendable, Equatable, Hashable {
    public var storage: SIMD4<Float>

    @inlinable public init(_ x: Float, _ y: Float, _ z: Float, _ w: Float) {
        storage = SIMD4(x, y, z, w)
    }
    @inlinable public init(storage: SIMD4<Float>) { self.storage = storage }

    @inlinable public init(_ v: CajuVec3, w: Float) { storage = SIMD4(v.storage, w) }

    @inlinable public var x: Float { storage.x }
    @inlinable public var y: Float { storage.y }
    @inlinable public var z: Float { storage.z }
    @inlinable public var w: Float { storage.w }

    /// Os três primeiros componentes.
    @inlinable public var xyz: CajuVec3 { CajuVec3(storage: storage[SIMD3(0, 1, 2)]) }

    public static let zero = CajuVec4(0, 0, 0, 0)

    @inlinable public static func + (a: Self, b: Self) -> Self { Self(storage: a.storage + b.storage) }
    @inlinable public static func - (a: Self, b: Self) -> Self { Self(storage: a.storage - b.storage) }
    @inlinable public static func * (v: Self, s: Float) -> Self { Self(storage: v.storage * s) }

    @inlinable public func dot(_ o: Self) -> Float { (storage * o.storage).sum() }
}
