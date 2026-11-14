/// Vetor de 2 componentes (`Float`).
///
/// ```swift
/// let v = CajuVec2(3, 4)
/// let n = v.normalized()  // CajuVec2(0.6, 0.8)
/// ```
public struct CajuVec2: Sendable, BitwiseCopyable, Equatable, Hashable {
    public var x: Float
    public var y: Float

    @inlinable public init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }

    @inlinable public init(repeating scalar: Float) {
        x = scalar
        y = scalar
    }

    public static let zero = CajuVec2(0, 0)
    public static let one = CajuVec2(1, 1)
    public static let unitX = CajuVec2(1, 0)
    public static let unitY = CajuVec2(0, 1)

    /// Indica se todos os componentes são finitos.
    @inlinable public var isFinite: Bool { x.isFinite && y.isFinite }

    /// Vetor perpendicular rotacionado 90° no sentido anti-horário (`(-y, x)`).
    @inlinable public var perpendicular: Self { Self(-y, x) }

    /// Componentes com valor absoluto.
    @inlinable public var abs: Self { Self(Swift.abs(x), Swift.abs(y)) }

    /// Componentes arredondados para baixo.
    @inlinable public var floor: Self { Self(x.rounded(.down), y.rounded(.down)) }

    /// Componentes arredondados para cima.
    @inlinable public var ceil: Self { Self(x.rounded(.up), y.rounded(.up)) }

    @inlinable public static func + (a: Self, b: Self) -> Self { Self(a.x + b.x, a.y + b.y) }
    @inlinable public static func - (a: Self, b: Self) -> Self { Self(a.x - b.x, a.y - b.y) }
    @inlinable public static func * (a: Self, b: Self) -> Self { Self(a.x * b.x, a.y * b.y) }
    @inlinable public static func * (v: Self, s: Float) -> Self { Self(v.x * s, v.y * s) }
    @inlinable public static func * (s: Float, v: Self) -> Self { Self(s * v.x, s * v.y) }
    @inlinable public static func / (a: Self, b: Self) -> Self { Self(a.x / b.x, a.y / b.y) }
    @inlinable public static func / (v: Self, s: Float) -> Self { Self(v.x / s, v.y / s) }
    @inlinable public static prefix func - (v: Self) -> Self { Self(-v.x, -v.y) }

    @inlinable public static func += (a: inout Self, b: Self) { a = a + b }
    @inlinable public static func -= (a: inout Self, b: Self) { a = a - b }
    @inlinable public static func *= (a: inout Self, b: Self) { a = a * b }
    @inlinable public static func *= (v: inout Self, s: Float) { v = v * s }
    @inlinable public static func /= (a: inout Self, b: Self) { a = a / b }
    @inlinable public static func /= (v: inout Self, s: Float) { v = v / s }

    @inlinable public func dot(_ o: Self) -> Float { x * o.x + y * o.y }
    @inlinable public var lengthSquared: Float { dot(self) }
    @inlinable public var length: Float { lengthSquared.squareRoot() }

    /// Vetor de comprimento 1, ou `nil` se o comprimento for zero ou não finito.
    @inlinable public func normalized() -> Self? {
        let l = length
        if l.isFinite, l > 0 {
            return self * (1 / l)
        }
        guard isFinite else { return nil }
        let m = Swift.max(Swift.abs(x), Swift.abs(y))
        guard m > 0 else { return nil }
        let scaled = self / m
        let sl = scaled.length
        guard sl.isFinite, sl > 0 else { return nil }
        return scaled * (1 / sl)
    }

    @inlinable public func distanceSquared(to other: Self) -> Float { (self - other).lengthSquared }
    @inlinable public func distance(to other: Self) -> Float { (self - other).length }

    /// Interpolação linear por componente entre `a` e `b`.
    @inlinable public static func lerp(_ a: Self, _ b: Self, t: Float) -> Self {
        a + (b - a) * t
    }

    /// Mínimo componente a componente entre `a` e `b`.
    @inlinable public static func min(_ a: Self, _ b: Self) -> Self {
        Self(Swift.min(a.x, b.x), Swift.min(a.y, b.y))
    }

    /// Máximo componente a componente entre `a` e `b`.
    @inlinable public static func max(_ a: Self, _ b: Self) -> Self {
        Self(Swift.max(a.x, b.x), Swift.max(a.y, b.y))
    }

    /// Limita cada componente ao intervalo `[min, max]`.
    @inlinable public func clamp(min minValue: Self, max maxValue: Self) -> Self {
        let low = Self.min(minValue, maxValue)
        let high = Self.max(minValue, maxValue)
        return Self.min(Self.max(self, low), high)
    }

    /// Reflete este vetor em relação a uma normal unitária `normal`.
    @inlinable public func reflect(normal: Self) -> Self {
        self - normal * (2 * dot(normal))
    }

    /// Projeta este vetor sobre `target`, ou retorna `nil` se `target` tiver comprimento zero ou não finito.
    @inlinable public func project(onto target: Self) -> Self? {
        let denom = target.lengthSquared
        if denom.isFinite, denom > 0 {
            return target * (dot(target) / denom)
        }
        guard let unit = target.normalized() else { return nil }
        return unit * dot(unit)
    }

    /// Ângulo em radianos `[0, π]` entre este vetor e `other`, ou `nil` se algum não puder ser normalizado.
    @inlinable public func angle(to other: Self) -> Float? {
        guard let a = normalized(), let b = other.normalized() else { return nil }
        return 2 * CajuLibm.atan2f((a - b).length, (a + b).length)
    }
}

/// Vetor de 3 componentes (`Float`), armazenado como `SIMD3<Float>`.
///
/// ```swift
/// let c = CajuVec3(1, 0, 0).cross(CajuVec3(0, 1, 0))  // (0, 0, 1)
/// ```
public struct CajuVec3: Sendable, BitwiseCopyable, Equatable, Hashable {
    public var storage: SIMD3<Float>

    @inlinable public init(_ x: Float, _ y: Float, _ z: Float) { storage = SIMD3(x, y, z) }
    @inlinable public init(storage: SIMD3<Float>) { self.storage = storage }
    @inlinable public init(repeating scalar: Float) { storage = SIMD3(repeating: scalar) }
    @inlinable public init(_ xy: CajuVec2, z: Float) { storage = SIMD3(xy.x, xy.y, z) }

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

    /// Os dois primeiros componentes.
    @inlinable public var xy: CajuVec2 { CajuVec2(storage.x, storage.y) }

    public static let zero = CajuVec3(0, 0, 0)
    public static let one = CajuVec3(1, 1, 1)
    public static let unitX = CajuVec3(1, 0, 0)
    public static let unitY = CajuVec3(0, 1, 0)
    public static let unitZ = CajuVec3(0, 0, 1)

    /// Indica se todos os componentes são finitos.
    @inlinable public var isFinite: Bool { storage.x.isFinite && storage.y.isFinite && storage.z.isFinite }

    /// Componentes com valor absoluto.
    @inlinable public var abs: Self { Self(Swift.abs(x), Swift.abs(y), Swift.abs(z)) }

    /// Componentes arredondados para baixo.
    @inlinable public var floor: Self { Self(x.rounded(.down), y.rounded(.down), z.rounded(.down)) }

    /// Componentes arredondados para cima.
    @inlinable public var ceil: Self { Self(x.rounded(.up), y.rounded(.up), z.rounded(.up)) }

    @inlinable public static func + (a: Self, b: Self) -> Self { Self(storage: a.storage + b.storage) }
    @inlinable public static func - (a: Self, b: Self) -> Self { Self(storage: a.storage - b.storage) }
    @inlinable public static func * (a: Self, b: Self) -> Self { Self(storage: a.storage * b.storage) }
    @inlinable public static func * (v: Self, s: Float) -> Self { Self(storage: v.storage * s) }
    @inlinable public static func * (s: Float, v: Self) -> Self { Self(storage: s * v.storage) }
    @inlinable public static func / (a: Self, b: Self) -> Self { Self(storage: a.storage / b.storage) }
    @inlinable public static func / (v: Self, s: Float) -> Self { Self(storage: v.storage / s) }
    @inlinable public static prefix func - (v: Self) -> Self { Self(storage: -v.storage) }

    @inlinable public static func += (a: inout Self, b: Self) { a.storage += b.storage }
    @inlinable public static func -= (a: inout Self, b: Self) { a.storage -= b.storage }
    @inlinable public static func *= (a: inout Self, b: Self) { a.storage *= b.storage }
    @inlinable public static func *= (v: inout Self, s: Float) { v.storage *= s }
    @inlinable public static func /= (a: inout Self, b: Self) { a.storage /= b.storage }
    @inlinable public static func /= (v: inout Self, s: Float) { v.storage /= s }

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
        if l.isFinite, l > 0 {
            return self * (1 / l)
        }
        guard isFinite else { return nil }
        let m = Swift.max(Swift.abs(x), Swift.max(Swift.abs(y), Swift.abs(z)))
        guard m > 0 else { return nil }
        let scaled = self / m
        let sl = scaled.length
        guard sl.isFinite, sl > 0 else { return nil }
        return scaled * (1 / sl)
    }

    @inlinable public func distanceSquared(to other: Self) -> Float { (self - other).lengthSquared }
    @inlinable public func distance(to other: Self) -> Float { (self - other).length }

    /// Interpolação linear por componente entre `a` e `b`.
    @inlinable public static func lerp(_ a: Self, _ b: Self, t: Float) -> Self {
        a + (b - a) * t
    }

    /// Mínimo componente a componente entre `a` e `b`.
    @inlinable public static func min(_ a: Self, _ b: Self) -> Self {
        Self(storage: pointwiseMin(a.storage, b.storage))
    }

    /// Máximo componente a componente entre `a` e `b`.
    @inlinable public static func max(_ a: Self, _ b: Self) -> Self {
        Self(storage: pointwiseMax(a.storage, b.storage))
    }

    /// Limita cada componente ao intervalo `[min, max]`.
    @inlinable public func clamp(min minValue: Self, max maxValue: Self) -> Self {
        let low = Self.min(minValue, maxValue)
        let high = Self.max(minValue, maxValue)
        return Self.min(Self.max(self, low), high)
    }

    /// Reflete este vetor em relação a uma normal unitária `normal`.
    @inlinable public func reflect(normal: Self) -> Self {
        self - normal * (2 * dot(normal))
    }

    /// Projeta este vetor sobre `target`, ou retorna `nil` se `target` tiver comprimento zero ou não finito.
    @inlinable public func project(onto target: Self) -> Self? {
        let denom = target.lengthSquared
        if denom.isFinite, denom > 0 {
            return target * (dot(target) / denom)
        }
        guard let unit = target.normalized() else { return nil }
        return unit * dot(unit)
    }

    /// Ângulo em radianos `[0, π]` entre este vetor e `other`, ou `nil` se algum não puder ser normalizado.
    @inlinable public func angle(to other: Self) -> Float? {
        guard let a = normalized(), let b = other.normalized() else { return nil }
        return 2 * CajuLibm.atan2f((a - b).length, (a + b).length)
    }

    /// Constrói uma base ortonormal direita `(tangent, bitangent)` onde `tangent × bitangent == self.normalized()`.
    ///
    /// Usa o método sem ramificação de Duff et al. (2017); retorna `nil` se este vetor não puder ser normalizado.
    @inlinable public func orthonormalBasis() -> (tangent: Self, bitangent: Self)? {
        guard let n = normalized() else { return nil }
        let sign: Float = n.z >= 0 ? 1 : -1
        let a = -1 / (sign + n.z)
        let b = n.x * n.y * a
        let tangent = Self(1 + sign * n.x * n.x * a, sign * b, -sign * n.x)
        let bitangent = Self(b, sign + n.y * n.y * a, -n.y)
        return (tangent, bitangent)
    }
}

/// Vetor de 4 componentes (`Float`), armazenado como `SIMD4<Float>`.
public struct CajuVec4: Sendable, BitwiseCopyable, Equatable, Hashable {
    public var storage: SIMD4<Float>

    @inlinable public init(_ x: Float, _ y: Float, _ z: Float, _ w: Float) {
        storage = SIMD4(x, y, z, w)
    }
    @inlinable public init(storage: SIMD4<Float>) { self.storage = storage }
    @inlinable public init(repeating scalar: Float) { storage = SIMD4(repeating: scalar) }
    @inlinable public init(_ v: CajuVec3, w: Float) { storage = SIMD4(v.storage, w) }
    @inlinable public init(_ xy: CajuVec2, z: Float, w: Float) { storage = SIMD4(xy.x, xy.y, z, w) }

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
    @inlinable public var w: Float {
        get { storage.w }
        set { storage.w = newValue }
    }

    /// Os dois primeiros componentes.
    @inlinable public var xy: CajuVec2 { CajuVec2(storage.x, storage.y) }

    /// Os três primeiros componentes.
    @inlinable public var xyz: CajuVec3 { CajuVec3(storage: storage[SIMD3(0, 1, 2)]) }

    public static let zero = CajuVec4(0, 0, 0, 0)
    public static let one = CajuVec4(1, 1, 1, 1)
    public static let unitX = CajuVec4(1, 0, 0, 0)
    public static let unitY = CajuVec4(0, 1, 0, 0)
    public static let unitZ = CajuVec4(0, 0, 1, 0)
    public static let unitW = CajuVec4(0, 0, 0, 1)

    /// Indica se todos os componentes são finitos.
    @inlinable public var isFinite: Bool {
        storage.x.isFinite && storage.y.isFinite && storage.z.isFinite && storage.w.isFinite
    }

    /// Componentes com valor absoluto.
    @inlinable public var abs: Self {
        Self(Swift.abs(x), Swift.abs(y), Swift.abs(z), Swift.abs(w))
    }

    /// Componentes arredondados para baixo.
    @inlinable public var floor: Self {
        Self(x.rounded(.down), y.rounded(.down), z.rounded(.down), w.rounded(.down))
    }

    /// Componentes arredondados para cima.
    @inlinable public var ceil: Self {
        Self(x.rounded(.up), y.rounded(.up), z.rounded(.up), w.rounded(.up))
    }

    @inlinable public static func + (a: Self, b: Self) -> Self { Self(storage: a.storage + b.storage) }
    @inlinable public static func - (a: Self, b: Self) -> Self { Self(storage: a.storage - b.storage) }
    @inlinable public static func * (a: Self, b: Self) -> Self { Self(storage: a.storage * b.storage) }
    @inlinable public static func * (v: Self, s: Float) -> Self { Self(storage: v.storage * s) }
    @inlinable public static func * (s: Float, v: Self) -> Self { Self(storage: s * v.storage) }
    @inlinable public static func / (a: Self, b: Self) -> Self { Self(storage: a.storage / b.storage) }
    @inlinable public static func / (v: Self, s: Float) -> Self { Self(storage: v.storage / s) }
    @inlinable public static prefix func - (v: Self) -> Self { Self(storage: -v.storage) }

    @inlinable public static func += (a: inout Self, b: Self) { a.storage += b.storage }
    @inlinable public static func -= (a: inout Self, b: Self) { a.storage -= b.storage }
    @inlinable public static func *= (a: inout Self, b: Self) { a.storage *= b.storage }
    @inlinable public static func *= (v: inout Self, s: Float) { v.storage *= s }
    @inlinable public static func /= (a: inout Self, b: Self) { a.storage /= b.storage }
    @inlinable public static func /= (v: inout Self, s: Float) { v.storage /= s }

    @inlinable public func dot(_ o: Self) -> Float { (storage * o.storage).sum() }
    @inlinable public var lengthSquared: Float { dot(self) }
    @inlinable public var length: Float { lengthSquared.squareRoot() }

    /// Vetor de comprimento 1, ou `nil` se o comprimento for zero ou não finito.
    @inlinable public func normalized() -> Self? {
        let l = length
        if l.isFinite, l > 0 {
            return self * (1 / l)
        }
        guard isFinite else { return nil }
        let m = Swift.max(Swift.max(Swift.abs(x), Swift.abs(y)), Swift.max(Swift.abs(z), Swift.abs(w)))
        guard m > 0 else { return nil }
        let scaled = self / m
        let sl = scaled.length
        guard sl.isFinite, sl > 0 else { return nil }
        return scaled * (1 / sl)
    }

    @inlinable public func distanceSquared(to other: Self) -> Float { (self - other).lengthSquared }
    @inlinable public func distance(to other: Self) -> Float { (self - other).length }

    /// Interpolação linear por componente entre `a` e `b`.
    @inlinable public static func lerp(_ a: Self, _ b: Self, t: Float) -> Self {
        a + (b - a) * t
    }

    /// Mínimo componente a componente entre `a` e `b`.
    @inlinable public static func min(_ a: Self, _ b: Self) -> Self {
        Self(storage: pointwiseMin(a.storage, b.storage))
    }

    /// Máximo componente a componente entre `a` e `b`.
    @inlinable public static func max(_ a: Self, _ b: Self) -> Self {
        Self(storage: pointwiseMax(a.storage, b.storage))
    }

    /// Limita cada componente ao intervalo `[min, max]`.
    @inlinable public func clamp(min minValue: Self, max maxValue: Self) -> Self {
        let low = Self.min(minValue, maxValue)
        let high = Self.max(minValue, maxValue)
        return Self.min(Self.max(self, low), high)
    }

    /// Reflete este vetor em relação a uma normal unitária `normal`.
    @inlinable public func reflect(normal: Self) -> Self {
        self - normal * (2 * dot(normal))
    }

    /// Projeta este vetor sobre `target`, ou retorna `nil` se `target` tiver comprimento zero ou não finito.
    @inlinable public func project(onto target: Self) -> Self? {
        let denom = target.lengthSquared
        if denom.isFinite, denom > 0 {
            return target * (dot(target) / denom)
        }
        guard let unit = target.normalized() else { return nil }
        return unit * dot(unit)
    }

    /// Ângulo em radianos `[0, π]` entre este vetor e `other`, ou `nil` se algum não puder ser normalizado.
    @inlinable public func angle(to other: Self) -> Float? {
        guard let a = normalized(), let b = other.normalized() else { return nil }
        return 2 * CajuLibm.atan2f((a - b).length, (a + b).length)
    }
}
