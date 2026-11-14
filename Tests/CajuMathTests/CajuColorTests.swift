import CajuMath
import CajuTesting
import Testing

@Suite("CajuColor")
struct CajuColorTests {
    @Test func srgbLinearRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let s = rng.nextFloat(in: 0...1)
            let linear = CajuColor.srgbToLinear(s)
            let back = CajuColor.linearToSrgb(linear)
            #expect(close(back, s))

            let col = CajuColor(
                srgb: rng.nextFloat(in: 0...1),
                g: rng.nextFloat(in: 0...1),
                b: rng.nextFloat(in: 0...1),
                a: rng.nextFloat(in: 0...1)
            )
            let srgbOut = col.srgb
            let recon = CajuColor(srgb: srgbOut.r, g: srgbOut.g, b: srgbOut.b, a: srgbOut.a)
            #expect(close(recon.r, col.r))
            #expect(close(recon.g, col.g))
            #expect(close(recon.b, col.b))
            #expect(close(recon.a, col.a))
        }
    }

    @Test func hexRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let rgb = rng.nextUInt32() & 0x00FF_FFFF
            #expect(CajuColor(hex: rgb).toHex() == rgb)

            let rgba = rng.nextUInt32()
            #expect(CajuColor(hexRGBA: rgba).toHexRGBA() == rgba)
        }
    }

    @Test func hsvRoundTrip() {
        CajuFuzz.run(iterations: testIterations) { rng, _ in
            let h = rng.nextFloat(in: 0...0.9999)
            let s = rng.nextFloat(in: 0.01...1)
            let v = rng.nextFloat(in: 0.01...1)
            let c = CajuColor(hue: h, saturation: s, value: v)
            let out = c.hsv
            #expect(close(out.hue, h))
            #expect(close(out.saturation, s))
            #expect(close(out.value, v))
        }
    }

    @Test func lerpPremultipliedLuminanceAndConstants() {
        #expect(CajuColor.black == CajuColor(r: 0, g: 0, b: 0, a: 1))
        #expect(CajuColor.white == CajuColor(r: 1, g: 1, b: 1, a: 1))
        #expect(CajuColor.red.luminance == 0.2126)
        #expect(CajuColor.green.luminance == 0.7152)
        #expect(CajuColor.blue.luminance == 0.0722)
        #expect(CajuColor.clear == CajuColor(r: 0, g: 0, b: 0, a: 0))

        let c = CajuColor(r: 0.8, g: 0.4, b: 0.2, a: 0.5)
        let pm = c.premultiplied
        #expect(close(pm.r, 0.4) && close(pm.g, 0.2) && close(pm.b, 0.1) && close(pm.a, 0.5))

        let mid = CajuColor.lerp(.black, .white, t: 0.5)
        #expect(close(mid.r, 0.5) && close(mid.g, 0.5) && close(mid.b, 0.5) && close(mid.a, 1))
    }
}
