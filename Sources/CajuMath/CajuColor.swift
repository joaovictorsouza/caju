/// Cor RGBA em **espaço linear** (`Float`), sem alocação.
///
/// ```swift
/// let linear = CajuColor(srgb: 0.5, g: 0.5, b: 0.5)
/// let hex = CajuColor(hex: 0x3A7BD5)
/// ```
public struct CajuColor: Sendable, Equatable, Hashable {
    /// Componente vermelho no espaço linear.
    public var r: Float
    /// Componente verde no espaço linear.
    public var g: Float
    /// Componente azul no espaço linear.
    public var b: Float
    /// Canal alfa linear (`0` transparente, `1` opaco).
    public var a: Float

    @inlinable public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Constrói a partir de componentes sRGB `[0, 1]`, convertendo RGB pela curva IEC 61966-2-1 para espaço linear.
    @inlinable public init(srgb r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = Self.srgbToLinear(r)
        self.g = Self.srgbToLinear(g)
        self.b = Self.srgbToLinear(b)
        self.a = a
    }

    /// Constrói a partir de inteiro hexadecimal `0xRRGGBB` (componentes interpretados em sRGB).
    @inlinable public init(hex: UInt32, alpha: Float = 1) {
        let sr = Float((hex >> 16) & 0xFF) / 255
        let sg = Float((hex >> 8) & 0xFF) / 255
        let sb = Float(hex & 0xFF) / 255
        self.init(srgb: sr, g: sg, b: sb, a: alpha)
    }

    /// Constrói a partir de inteiro hexadecimal `0xRRGGBBAA` (RGB em sRGB, alfa linear).
    @inlinable public init(hexRGBA: UInt32) {
        let sr = Float((hexRGBA >> 24) & 0xFF) / 255
        let sg = Float((hexRGBA >> 16) & 0xFF) / 255
        let sb = Float((hexRGBA >> 8) & 0xFF) / 255
        let alpha = Float(hexRGBA & 0xFF) / 255
        self.init(srgb: sr, g: sg, b: sb, a: alpha)
    }

    /// Constrói no espaço linear a partir de HSV (`hue` envolvido em `[0, 1)`, `saturation` e `value` limitados a `[0, 1]`).
    @inlinable public init(hue: Float, saturation: Float, value: Float, alpha: Float = 1) {
        let s = CajuScalar.saturate(saturation)
        let v = CajuScalar.saturate(value)
        let hWrapped = hue - hue.rounded(.down)
        let h6 = hWrapped * 6
        let sector = Int(h6) % 6
        let f = h6 - Float(sector)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch sector {
        case 0: self.init(r: v, g: t, b: p, a: alpha)
        case 1: self.init(r: q, g: v, b: p, a: alpha)
        case 2: self.init(r: p, g: v, b: t, a: alpha)
        case 3: self.init(r: p, g: q, b: v, a: alpha)
        case 4: self.init(r: t, g: p, b: v, a: alpha)
        default: self.init(r: v, g: p, b: q, a: alpha)
        }
    }

    public static let black = CajuColor(r: 0, g: 0, b: 0, a: 1)
    public static let white = CajuColor(r: 1, g: 1, b: 1, a: 1)
    public static let red = CajuColor(r: 1, g: 0, b: 0, a: 1)
    public static let green = CajuColor(r: 0, g: 1, b: 0, a: 1)
    public static let blue = CajuColor(r: 0, g: 0, b: 1, a: 1)
    public static let clear = CajuColor(r: 0, g: 0, b: 0, a: 0)

    /// Converte um canal escalar sRGB para linear usando a curva exata IEC 61966-2-1.
    @inlinable public static func srgbToLinear(_ c: Float) -> Float {
        if c <= 0.04045 {
            return c / 12.92
        }
        return CajuLibm.powf((c + 0.055) / 1.055, 2.4)
    }

    /// Converte um canal escalar linear para sRGB usando a curva exata IEC 61966-2-1.
    @inlinable public static func linearToSrgb(_ c: Float) -> Float {
        if c <= 0.0031308 {
            return c * 12.92
        }
        return 1.055 * CajuLibm.powf(c, 1 / 2.4) - 0.055
    }

    /// Componentes convertidos para sRGB `(r, g, b, a)`.
    @inlinable public var srgb: (r: Float, g: Float, b: Float, a: Float) {
        (Self.linearToSrgb(r), Self.linearToSrgb(g), Self.linearToSrgb(b), a)
    }

    /// Converte para inteiro `0xRRGGBB` em sRGB (componentes limitados a `[0, 1]`).
    @inlinable public func toHex() -> UInt32 {
        let sr = UInt32(CajuScalar.saturate(Self.linearToSrgb(r)) * 255 + 0.5)
        let sg = UInt32(CajuScalar.saturate(Self.linearToSrgb(g)) * 255 + 0.5)
        let sb = UInt32(CajuScalar.saturate(Self.linearToSrgb(b)) * 255 + 0.5)
        return (sr << 16) | (sg << 8) | sb
    }

    /// Converte para inteiro `0xRRGGBBAA` (RGB em sRGB, alfa linear, limitados a `[0, 1]`).
    @inlinable public func toHexRGBA() -> UInt32 {
        let sa = UInt32(CajuScalar.saturate(a) * 255 + 0.5)
        return (toHex() << 8) | sa
    }

    /// Representação HSV `(hue, saturation, value)` com `hue` em `[0, 1)`.
    @inlinable public var hsv: (hue: Float, saturation: Float, value: Float) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        let v = maxC
        let s = maxC > 0 ? delta / maxC : 0
        guard delta > 0 else { return (0, s, v) }

        var h: Float
        if maxC == r {
            h = (g - b) / delta
            if h < 0 { h += 6 }
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h /= 6
        return (h - h.rounded(.down), s, v)
    }

    /// Cor com RGB pré-multiplicado pelo canal alfa.
    @inlinable public var premultiplied: Self {
        Self(r: r * a, g: g * a, b: b * a, a: a)
    }

    /// Luminância relativa linear (Rec. 709 / sRGB).
    @inlinable public var luminance: Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Interpolação linear entre `a` e `b` no espaço linear.
    @inlinable public static func lerp(_ a: Self, _ b: Self, t: Float) -> Self {
        Self(
            r: CajuScalar.lerp(a.r, b.r, t: t),
            g: CajuScalar.lerp(a.g, b.g, t: t),
            b: CajuScalar.lerp(a.b, b.b, t: t),
            a: CajuScalar.lerp(a.a, b.a, t: t)
        )
    }
}
