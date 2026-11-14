/// Quaternion unitário de rotação (`x, y, z, w`).
///
/// ```swift
/// let q = CajuQuat(axis: .unitZ, radians: .pi / 2) ?? .identity
/// let v = q.rotate(.unitX)  // ~(0, 1, 0)
/// ```
public struct CajuQuat: Sendable, Equatable, Hashable {
    public var storage: SIMD4<Float>

    @inlinable public init(x: Float, y: Float, z: Float, w: Float) { storage = SIMD4(x, y, z, w) }

    public static let identity = CajuQuat(x: 0, y: 0, z: 0, w: 1)

    @inlinable public var x: Float { storage.x }
    @inlinable public var y: Float { storage.y }
    @inlinable public var z: Float { storage.z }
    @inlinable public var w: Float { storage.w }

    /// Indica se todos os componentes são finitos.
    @inlinable public var isFinite: Bool {
        storage.x.isFinite && storage.y.isFinite && storage.z.isFinite && storage.w.isFinite
    }

    /// Rotação de `radians` em torno de `axis`; `nil` se o eixo não puder ser normalizado ou `radians` não for finito.
    @inlinable public init?(axis: CajuVec3, radians: Float) {
        guard radians.isFinite, let n = axis.normalized() else { return nil }
        let half = radians * 0.5
        let s = CajuLibm.sinf(half)
        self.init(x: n.x * s, y: n.y * s, z: n.z * s, w: CajuLibm.cosf(half))
    }

    /// Constrói quaternion a partir da matriz de rotação 3×3 superior de `matrix` (ramo pela maior diagonal).
    ///
    /// Retorna `nil` se `matrix` não for finita ou se não puder ser normalizado.
    @inlinable public init?(matrix m: CajuMat4) {
        guard m.isFinite else { return nil }
        let m00 = m.c0.x
        let m10 = m.c0.y
        let m20 = m.c0.z
        let m01 = m.c1.x
        let m11 = m.c1.y
        let m21 = m.c1.z
        let m02 = m.c2.x
        let m12 = m.c2.y
        let m22 = m.c2.z

        let trace = m00 + m11 + m22
        let raw: Self
        if trace > 0 {
            let rad = trace + 1
            guard rad > 0 else { return nil }
            let s = 2 * rad.squareRoot()
            let invS = 1 / s
            raw = Self(
                x: (m21 - m12) * invS,
                y: (m02 - m20) * invS,
                z: (m10 - m01) * invS,
                w: 0.25 * s
            )
        } else if m00 >= m11 && m00 >= m22 {
            let rad = 1 + m00 - m11 - m22
            guard rad > 0 else { return nil }
            let s = 2 * rad.squareRoot()
            let invS = 1 / s
            raw = Self(
                x: 0.25 * s,
                y: (m01 + m10) * invS,
                z: (m02 + m20) * invS,
                w: (m21 - m12) * invS
            )
        } else if m11 >= m22 {
            let rad = 1 + m11 - m00 - m22
            guard rad > 0 else { return nil }
            let s = 2 * rad.squareRoot()
            let invS = 1 / s
            raw = Self(
                x: (m01 + m10) * invS,
                y: 0.25 * s,
                z: (m12 + m21) * invS,
                w: (m02 - m20) * invS
            )
        } else {
            let rad = 1 + m22 - m00 - m11
            guard rad > 0 else { return nil }
            let s = 2 * rad.squareRoot()
            let invS = 1 / s
            raw = Self(
                x: (m02 + m20) * invS,
                y: (m12 + m21) * invS,
                z: 0.25 * s,
                w: (m10 - m01) * invS
            )
        }
        guard let normalized = raw.normalized() else { return nil }
        self = normalized
    }

    /// Constrói quaternion na convenção intrínseca Y-X-Z (`Ry(yaw) * Rx(pitch) * Rz(roll)`), em radianos.
    @inlinable public init(yaw: Float, pitch: Float, roll: Float) {
        let hy = yaw * 0.5
        let hp = pitch * 0.5
        let hr = roll * 0.5
        let sy = CajuLibm.sinf(hy)
        let cy = CajuLibm.cosf(hy)
        let sp = CajuLibm.sinf(hp)
        let cp = CajuLibm.cosf(hp)
        let sr = CajuLibm.sinf(hr)
        let cr = CajuLibm.cosf(hr)

        self.init(
            x: cy * sp * cr + sy * cp * sr,
            y: sy * cp * cr - cy * sp * sr,
            z: cy * cp * sr - sy * sp * cr,
            w: cy * cp * cr + sy * sp * sr
        )
    }

    /// Rotação mínima que leva a direção `from` até `to` (trata vetores antiparalelos).
    ///
    /// Retorna `nil` se algum vetor tiver comprimento zero ou não for finito.
    @inlinable public init?(from: CajuVec3, to: CajuVec3) {
        guard let a = from.normalized(), let b = to.normalized() else { return nil }
        let d = a.dot(b)
        if d >= 0 {
            let c = a.cross(b)
            guard let q = Self(x: c.x, y: c.y, z: c.z, w: 1 + d).normalized() else { return nil }
            self = q
            return
        }
        let c = a.cross(b)
        let sinTheta = c.length
        if sinTheta <= 1e-6 {
            var ortho = CajuVec3.unitX.cross(a)
            if ortho.lengthSquared < 1e-6 {
                ortho = CajuVec3.unitY.cross(a)
            }
            guard let axis = ortho.normalized() else { return nil }
            self.init(x: axis.x, y: axis.y, z: axis.z, w: 0)
            return
        }
        let halfSin = ((1 - d) * 0.5).squareRoot()
        let halfCos = sinTheta / (2 * halfSin)
        let axis = c * (1 / sinTheta)
        guard
            let q = Self(
                x: axis.x * halfSin,
                y: axis.y * halfSin,
                z: axis.z * halfSin,
                w: halfCos
            ).normalized()
        else { return nil }
        self = q
    }

    @inlinable public var conjugate: Self { Self(x: -x, y: -y, z: -z, w: w) }

    /// Inverso multiplicativo do quaternion, ou `nil` se a norma quadrada for zero ou não finita.
    @inlinable public var inverse: Self? {
        let normSq = (storage * storage).sum()
        guard normSq.isFinite, normSq > 0 else { return nil }
        let invNormSq = 1 / normSq
        return Self(x: -x * invNormSq, y: -y * invNormSq, z: -z * invNormSq, w: w * invNormSq)
    }

    /// Produto escalar entre dois quaternions.
    @inlinable public func dot(_ other: Self) -> Float {
        (storage * other.storage).sum()
    }

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

    /// Converte para representação eixo-ângulo `(axis, radians)` no intervalo `[0, π]`.
    ///
    /// A identidade retorna `(.unitX, 0)`.
    @inlinable public func toAxisAngle() -> (axis: CajuVec3, radians: Float) {
        guard let unit = normalized() else { return (.unitX, 0) }
        let q = unit.w < 0 ? Self(x: -unit.x, y: -unit.y, z: -unit.z, w: -unit.w) : unit
        let imag = CajuVec3(q.x, q.y, q.z)
        let sinHalf = imag.length
        guard sinHalf > 1e-7, let axis = imag.normalized() else {
            return (.unitX, 0)
        }
        let angle = 2 * CajuLibm.atan2f(sinHalf, q.w)
        return (axis, angle)
    }

    /// Ângulos de Euler `(yaw, pitch, roll)` em radianos na convenção intrínseca Y-X-Z.
    @inlinable public var eulerAngles: (yaw: Float, pitch: Float, roll: Float) {
        let q = normalized() ?? .identity
        let sinP = 2 * (q.x * q.w - q.y * q.z)
        if abs(sinP) >= 0.999999 {
            let pitch = Float(signOf: sinP, magnitudeOf: .pi * 0.5)
            let yaw = CajuLibm.atan2f(2 * (q.y * q.w - q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
            return (yaw, pitch, 0)
        }
        let pitch = CajuLibm.asinf(CajuScalar.clamp(sinP, min: -1, max: 1))
        let yaw = CajuLibm.atan2f(2 * (q.x * q.z + q.y * q.w), 1 - 2 * (q.x * q.x + q.y * q.y))
        let roll = CajuLibm.atan2f(2 * (q.x * q.y + q.z * q.w), 1 - 2 * (q.x * q.x + q.z * q.z))
        return (yaw, pitch, roll)
    }

    /// Interpolação linear normalizada pelo menor arco entre `a` e `b`.
    @inlinable public static func nlerp(_ a: Self, _ b: Self, t: Float) -> Self {
        let qa = a.normalized() ?? .identity
        let qb0 = b.normalized() ?? .identity
        let qb = qa.dot(qb0) < 0 ? Self(x: -qb0.x, y: -qb0.y, z: -qb0.z, w: -qb0.w) : qb0
        let blended = qa.storage + (qb.storage - qa.storage) * t
        return Self(x: blended.x, y: blended.y, z: blended.z, w: blended.w).normalized() ?? qa
    }

    /// Interpolação esférica pelo menor arco entre `a` e `b`, com fallback para `nlerp` em ângulos muito pequenos.
    @inlinable public static func slerp(_ a: Self, _ b: Self, t: Float) -> Self {
        let qa = a.normalized() ?? .identity
        let qb0 = b.normalized() ?? .identity
        var d = qa.dot(qb0)
        let qb: Self
        if d < 0 {
            qb = Self(x: -qb0.x, y: -qb0.y, z: -qb0.z, w: -qb0.w)
            d = -d
        } else {
            qb = qb0
        }
        if t == 0 { return qa }
        if t == 1 { return qb }
        if d > 0.99995 {
            return nlerp(qa, qb, t: t)
        }
        let clampedDot = CajuScalar.clamp(d, min: -1, max: 1)
        let theta = CajuLibm.acosf(clampedDot)
        let sinTheta = CajuLibm.sinf(theta)
        let w0 = CajuLibm.sinf((1 - t) * theta) / sinTheta
        let w1 = CajuLibm.sinf(t * theta) / sinTheta
        let combined = qa.storage * w0 + qb.storage * w1
        return Self(x: combined.x, y: combined.y, z: combined.z, w: combined.w).normalized() ?? qa
    }

    /// Orientação que alinha `-unitZ` com `forward` e `+unitY` próximo de `up` (convenção direita, consistente com `CajuMat4.lookAt`).
    ///
    /// Retorna `nil` se `forward` ou `up` forem nulos, colineares ou não finitos.
    @inlinable public static func lookRotation(forward: CajuVec3, up: CajuVec3 = .unitY) -> Self? {
        guard up.isFinite,
            let f = forward.normalized(),
            let right = f.cross(up).normalized()
        else { return nil }
        let camUp = right.cross(f)
        let back = -f
        let m = CajuMat4(
            columns: SIMD4(right.x, right.y, right.z, 0),
            SIMD4(camUp.x, camUp.y, camUp.z, 0),
            SIMD4(back.x, back.y, back.z, 0),
            SIMD4(0, 0, 0, 1)
        )
        return Self(matrix: m)
    }

    /// Ângulo de rotação em radianos `[0, π]` entre este quaternion e `other`, ou `nil` se algum não puder ser normalizado.
    @inlinable public func angle(to other: Self) -> Float? {
        guard let a = normalized(), let b0 = other.normalized() else { return nil }
        let b = a.dot(b0) < 0 ? Self(x: -b0.x, y: -b0.y, z: -b0.z, w: -b0.w) : b0
        let diff = (a.storage - b.storage)
        let sum = (a.storage + b.storage)
        let diffLen = (diff * diff).sum().squareRoot()
        let sumLen = (sum * sum).sum().squareRoot()
        return 4 * CajuLibm.atan2f(diffLen, sumLen)
    }
}
