#if canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    import Android
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    import Musl
#endif

/// Encapsula funções matemáticas da `libc` usadas por `CajuMath` sem expor `Foundation`.
@usableFromInline
enum CajuLibm {
    #if canImport(Glibc)
        @inlinable static func sinf(_ x: Float) -> Float { Glibc.sinf(x) }
        @inlinable static func cosf(_ x: Float) -> Float { Glibc.cosf(x) }
        @inlinable static func tanf(_ x: Float) -> Float { Glibc.tanf(x) }
        @inlinable static func asinf(_ x: Float) -> Float { Glibc.asinf(x) }
        @inlinable static func acosf(_ x: Float) -> Float { Glibc.acosf(x) }
        @inlinable static func atan2f(_ y: Float, _ x: Float) -> Float { Glibc.atan2f(y, x) }
        @inlinable static func powf(_ x: Float, _ y: Float) -> Float { Glibc.powf(x, y) }
        @inlinable static func expf(_ x: Float) -> Float { Glibc.expf(x) }
        @inlinable static func floorf(_ x: Float) -> Float { Glibc.floorf(x) }
        @inlinable static func ceilf(_ x: Float) -> Float { Glibc.ceilf(x) }
        @inlinable static func fmodf(_ x: Float, _ y: Float) -> Float { Glibc.fmodf(x, y) }
    #elseif canImport(Android)
        @inlinable static func sinf(_ x: Float) -> Float { Android.sinf(x) }
        @inlinable static func cosf(_ x: Float) -> Float { Android.cosf(x) }
        @inlinable static func tanf(_ x: Float) -> Float { Android.tanf(x) }
        @inlinable static func asinf(_ x: Float) -> Float { Android.asinf(x) }
        @inlinable static func acosf(_ x: Float) -> Float { Android.acosf(x) }
        @inlinable static func atan2f(_ y: Float, _ x: Float) -> Float { Android.atan2f(y, x) }
        @inlinable static func powf(_ x: Float, _ y: Float) -> Float { Android.powf(x, y) }
        @inlinable static func expf(_ x: Float) -> Float { Android.expf(x) }
        @inlinable static func floorf(_ x: Float) -> Float { Android.floorf(x) }
        @inlinable static func ceilf(_ x: Float) -> Float { Android.ceilf(x) }
        @inlinable static func fmodf(_ x: Float, _ y: Float) -> Float { Android.fmodf(x, y) }
    #elseif canImport(Darwin)
        @inlinable static func sinf(_ x: Float) -> Float { Darwin.sinf(x) }
        @inlinable static func cosf(_ x: Float) -> Float { Darwin.cosf(x) }
        @inlinable static func tanf(_ x: Float) -> Float { Darwin.tanf(x) }
        @inlinable static func asinf(_ x: Float) -> Float { Darwin.asinf(x) }
        @inlinable static func acosf(_ x: Float) -> Float { Darwin.acosf(x) }
        @inlinable static func atan2f(_ y: Float, _ x: Float) -> Float { Darwin.atan2f(y, x) }
        @inlinable static func powf(_ x: Float, _ y: Float) -> Float { Darwin.powf(x, y) }
        @inlinable static func expf(_ x: Float) -> Float { Darwin.expf(x) }
        @inlinable static func floorf(_ x: Float) -> Float { Darwin.floorf(x) }
        @inlinable static func ceilf(_ x: Float) -> Float { Darwin.ceilf(x) }
        @inlinable static func fmodf(_ x: Float, _ y: Float) -> Float { Darwin.fmodf(x, y) }
    #elseif canImport(Musl)
        @inlinable static func sinf(_ x: Float) -> Float { Musl.sinf(x) }
        @inlinable static func cosf(_ x: Float) -> Float { Musl.cosf(x) }
        @inlinable static func tanf(_ x: Float) -> Float { Musl.tanf(x) }
        @inlinable static func asinf(_ x: Float) -> Float { Musl.asinf(x) }
        @inlinable static func acosf(_ x: Float) -> Float { Musl.acosf(x) }
        @inlinable static func atan2f(_ y: Float, _ x: Float) -> Float { Musl.atan2f(y, x) }
        @inlinable static func powf(_ x: Float, _ y: Float) -> Float { Musl.powf(x, y) }
        @inlinable static func expf(_ x: Float) -> Float { Musl.expf(x) }
        @inlinable static func floorf(_ x: Float) -> Float { Musl.floorf(x) }
        @inlinable static func ceilf(_ x: Float) -> Float { Musl.ceilf(x) }
        @inlinable static func fmodf(_ x: Float, _ y: Float) -> Float { Musl.fmodf(x, y) }
    #endif
}
