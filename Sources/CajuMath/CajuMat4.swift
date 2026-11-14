/// Matriz 4×4 em ordem de colunas (convenção de coluna: `M * v`).
///
/// ```swift
/// let m = CajuMat4(translation: CajuVec3(1, 2, 3), rotation: .identity, scale: .one)
/// let p = m.transformPoint(.zero)  // (1, 2, 3)
/// ```
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

    /// Constrói matriz TRS (`T * R * S`) a partir de translação, rotação e escala.
    @inlinable public init(translation: CajuVec3, rotation: CajuQuat, scale: CajuVec3) {
        let r = Self.rotation(rotation)
        self.init(
            columns: r.c0 * scale.x,
            r.c1 * scale.y,
            r.c2 * scale.z,
            SIMD4(translation.x, translation.y, translation.z, 1)
        )
    }

    public static let identity = CajuMat4(
        columns: SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))

    /// Indica se todos os 16 elementos são finitos.
    @inlinable public var isFinite: Bool {
        c0.x.isFinite && c0.y.isFinite && c0.z.isFinite && c0.w.isFinite
            && c1.x.isFinite && c1.y.isFinite && c1.z.isFinite && c1.w.isFinite
            && c2.x.isFinite && c2.y.isFinite && c2.z.isFinite && c2.w.isFinite
            && c3.x.isFinite && c3.y.isFinite && c3.z.isFinite && c3.w.isFinite
    }

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

    /// Matriz de câmera direita (`-Z` para frente, `+Y` para cima), ou `nil` se os parâmetros forem inválidos.
    @inlinable public static func lookAt(eye: CajuVec3, target: CajuVec3, up: CajuVec3) -> Self? {
        guard eye.isFinite, target.isFinite, up.isFinite,
            let forward = (target - eye).normalized(),
            let right = forward.cross(up).normalized()
        else { return nil }
        let camUp = right.cross(forward)
        return Self(
            columns: SIMD4(right.x, camUp.x, -forward.x, 0),
            SIMD4(right.y, camUp.y, -forward.y, 0),
            SIMD4(right.z, camUp.z, -forward.z, 0),
            SIMD4(-right.dot(eye), -camUp.dot(eye), forward.dot(eye), 1)
        )
    }

    /// Matriz de projeção perspectiva direita com profundidade `[0, 1]` (Metal/Vulkan).
    ///
    /// Retorna `nil` se `fovY` não estiver em `(0, π)`, `aspect <= 0`, `near <= 0`, `far <= near`, ou houver valores não finitos.
    @inlinable public static func perspective(
        fovY: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> Self? {
        guard fovY.isFinite, aspect.isFinite, near.isFinite, far.isFinite,
            fovY > 0, fovY < .pi, aspect > 0, near > 0, far > near
        else { return nil }
        let tanHalf = CajuLibm.tanf(fovY * 0.5)
        guard tanHalf.isFinite, tanHalf > 0 else { return nil }
        let f = 1 / tanHalf
        let invDepth = 1 / (near - far)
        let result = Self(
            columns: SIMD4(f / aspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, far * invDepth, -1),
            SIMD4(0, 0, near * far * invDepth, 0)
        )
        return result.isFinite ? result : nil
    }

    /// Matriz de projeção ortográfica direita com profundidade `[0, 1]` (Metal/Vulkan).
    ///
    /// Retorna `nil` se `right <= left`, `top <= bottom`, `far <= near` ou houver valores não finitos.
    @inlinable public static func orthographic(
        left: Float,
        right: Float,
        bottom: Float,
        top: Float,
        near: Float,
        far: Float
    ) -> Self? {
        guard left.isFinite, right.isFinite, bottom.isFinite, top.isFinite, near.isFinite, far.isFinite,
            right > left, top > bottom, far > near
        else { return nil }
        let invW = 1 / (right - left)
        let invH = 1 / (top - bottom)
        let invD = 1 / (near - far)
        let result = Self(
            columns: SIMD4(2 * invW, 0, 0, 0),
            SIMD4(0, 2 * invH, 0, 0),
            SIMD4(0, 0, invD, 0),
            SIMD4(-(right + left) * invW, -(top + bottom) * invH, near * invD, 1)
        )
        return result.isFinite ? result : nil
    }

    @inlinable public static func * (a: Self, b: Self) -> Self {
        Self(columns: a * b.c0, a * b.c1, a * b.c2, a * b.c3)
    }

    @inlinable public static func * (m: Self, v: SIMD4<Float>) -> SIMD4<Float> {
        m.c0 * v.x + m.c1 * v.y + m.c2 * v.z + m.c3 * v.w
    }

    @inlinable public static func * (m: Self, v: CajuVec4) -> CajuVec4 {
        CajuVec4(storage: m * v.storage)
    }

    /// Transforma um ponto (w = 1).
    @inlinable public func transformPoint(_ p: CajuVec3) -> CajuVec3 {
        let r = self * SIMD4(p.x, p.y, p.z, 1)
        return CajuVec3(r.x, r.y, r.z)
    }

    /// Transforma uma direção (w = 0).
    @inlinable public func transformDirection(_ d: CajuVec3) -> CajuVec3 {
        let r = self * SIMD4(d.x, d.y, d.z, 0)
        return CajuVec3(r.x, r.y, r.z)
    }

    @inlinable public var transposed: Self {
        Self(
            columns: SIMD4(c0.x, c1.x, c2.x, c3.x), SIMD4(c0.y, c1.y, c2.y, c3.y),
            SIMD4(c0.z, c1.z, c2.z, c3.z), SIMD4(c0.w, c1.w, c2.w, c3.w))
    }

    /// Determinante 4×4 da matriz.
    @inlinable public var determinant: Float {
        let s0 = c0.x * c1.y - c1.x * c0.y
        let s1 = c0.x * c1.z - c1.x * c0.z
        let s2 = c0.x * c1.w - c1.x * c0.w
        let s3 = c0.y * c1.z - c1.y * c0.z
        let s4 = c0.y * c1.w - c1.y * c0.w
        let s5 = c0.z * c1.w - c1.z * c0.w

        let k5 = c2.z * c3.w - c3.z * c2.w
        let k4 = c2.y * c3.w - c3.y * c2.w
        let k3 = c2.y * c3.z - c3.y * c2.z
        let k2 = c2.x * c3.w - c3.x * c2.w
        let k1 = c2.x * c3.z - c3.x * c2.z
        let k0 = c2.x * c3.y - c3.x * c2.y

        return s0 * k5 - s1 * k4 + s2 * k3 + s3 * k2 - s4 * k1 + s5 * k0
    }

    /// Inversa geral 4×4, ou `nil` se a matriz for singular (`|det| <= 1e-12`) ou não finita.
    @inlinable public var inverse: Self? {
        guard isFinite else { return nil }
        let s0 = c0.x * c1.y - c1.x * c0.y
        let s1 = c0.x * c1.z - c1.x * c0.z
        let s2 = c0.x * c1.w - c1.x * c0.w
        let s3 = c0.y * c1.z - c1.y * c0.z
        let s4 = c0.y * c1.w - c1.y * c0.w
        let s5 = c0.z * c1.w - c1.z * c0.w

        let k5 = c2.z * c3.w - c3.z * c2.w
        let k4 = c2.y * c3.w - c3.y * c2.w
        let k3 = c2.y * c3.z - c3.y * c2.z
        let k2 = c2.x * c3.w - c3.x * c2.w
        let k1 = c2.x * c3.z - c3.x * c2.z
        let k0 = c2.x * c3.y - c3.x * c2.y

        let det = s0 * k5 - s1 * k4 + s2 * k3 + s3 * k2 - s4 * k1 + s5 * k0
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        let invDet = 1 / det
        guard invDet.isFinite else { return nil }

        let ic0 =
            SIMD4<Float>(
                c1.y * k5 - c1.z * k4 + c1.w * k3,
                -c0.y * k5 + c0.z * k4 - c0.w * k3,
                c3.y * s5 - c3.z * s4 + c3.w * s3,
                -c2.y * s5 + c2.z * s4 - c2.w * s3
            ) * invDet

        let ic1 =
            SIMD4<Float>(
                -c1.x * k5 + c1.z * k2 - c1.w * k1,
                c0.x * k5 - c0.z * k2 + c0.w * k1,
                -c3.x * s5 + c3.z * s2 - c3.w * s1,
                c2.x * s5 - c2.z * s2 + c2.w * s1
            ) * invDet

        let ic2 =
            SIMD4<Float>(
                c1.x * k4 - c1.y * k2 + c1.w * k0,
                -c0.x * k4 + c0.y * k2 - c0.w * k0,
                c3.x * s4 - c3.y * s2 + c3.w * s0,
                -c2.x * s4 + c2.y * s2 - c2.w * s0
            ) * invDet

        let ic3 =
            SIMD4<Float>(
                -c1.x * k3 + c1.y * k1 - c1.z * k0,
                c0.x * k3 - c0.y * k1 + c0.z * k0,
                -c3.x * s3 + c3.y * s1 - c3.z * s0,
                c2.x * s3 - c2.y * s1 + c2.z * s0
            ) * invDet

        let result = Self(columns: ic0, ic1, ic2, ic3)
        return result.isFinite ? result : nil
    }

    /// Inversa rápida para matrizes afins (última linha `(0, 0, 0, 1)`), ou `nil` se singular, não afim ou não finita.
    @inlinable public var inverseAffine: Self? {
        guard isFinite,
            abs(c0.w) <= 1e-6, abs(c1.w) <= 1e-6, abs(c2.w) <= 1e-6, abs(c3.w - 1) <= 1e-6
        else { return nil }
        let a = CajuVec3(c0.x, c0.y, c0.z)
        let b = CajuVec3(c1.x, c1.y, c1.z)
        let c = CajuVec3(c2.x, c2.y, c2.z)
        let r0 = b.cross(c)
        let r1 = c.cross(a)
        let r2 = a.cross(b)
        let det3 = a.dot(r0)
        guard det3.isFinite, abs(det3) > 1e-12 else { return nil }
        let invDet = 1 / det3
        guard invDet.isFinite else { return nil }

        let ic0 = SIMD4<Float>(r0.x * invDet, r1.x * invDet, r2.x * invDet, 0)
        let ic1 = SIMD4<Float>(r0.y * invDet, r1.y * invDet, r2.y * invDet, 0)
        let ic2 = SIMD4<Float>(r0.z * invDet, r1.z * invDet, r2.z * invDet, 0)
        let it = -(ic0 * c3.x + ic1 * c3.y + ic2 * c3.z)
        let ic3 = SIMD4<Float>(it.x, it.y, it.z, 1)

        let result = Self(columns: ic0, ic1, ic2, ic3)
        return result.isFinite ? result : nil
    }

    /// Decompõe matriz TRS em `(translation, rotation, scale)`, ou `nil` se escala for zero/não finita ou não afim.
    ///
    /// Se o determinante 3×3 for negativo, o sinal é atribuído ao eixo X (`scale.x < 0`).
    @inlinable public func decompose() -> (translation: CajuVec3, rotation: CajuQuat, scale: CajuVec3)? {
        guard isFinite,
            abs(c0.w) <= 1e-6, abs(c1.w) <= 1e-6, abs(c2.w) <= 1e-6, abs(c3.w - 1) <= 1e-6
        else { return nil }

        let translation = CajuVec3(c3.x, c3.y, c3.z)
        let col0 = CajuVec3(c0.x, c0.y, c0.z)
        let col1 = CajuVec3(c1.x, c1.y, c1.z)
        let col2 = CajuVec3(c2.x, c2.y, c2.z)

        var sx = col0.length
        let sy = col1.length
        let sz = col2.length
        guard sx.isFinite, sy.isFinite, sz.isFinite, sx > 0, sy > 0, sz > 0 else { return nil }

        let det3 = col0.dot(col1.cross(col2))
        guard det3.isFinite, det3 != 0 else { return nil }
        if det3 < 0 {
            sx = -sx
        }

        let nx = col0 * (1 / sx)
        let ny = col1 * (1 / sy)
        let nz = col2 * (1 / sz)
        let rotMatrix = Self(
            columns: SIMD4(nx.x, nx.y, nx.z, 0),
            SIMD4(ny.x, ny.y, ny.z, 0),
            SIMD4(nz.x, nz.y, nz.z, 0),
            SIMD4(0, 0, 0, 1)
        )
        guard let rotation = CajuQuat(matrix: rotMatrix) else { return nil }
        return (translation, rotation, CajuVec3(sx, sy, sz))
    }
}
