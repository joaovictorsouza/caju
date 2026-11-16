#if canImport(Metal)
    import CajuRHI
    import CajuRHIMetal
    import CajuRender
    import Foundation
    import Metal
    import Testing

    @Suite("CajuRender: golden de cena no Metal (R-1a)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
    struct CajuSceneGoldenMetalTests {
        @Test func sceneMatchesReference() throws {
            metalAllocationLock.lock()
            defer { metalAllocationLock.unlock() }
            let device = try CajuMetalDevice.makeSystemDefault()
            let bytes = try CajuSceneGolden.render(device: device) { texture throws(CajuRHIError) in
                try device.readTexture(texture)
            }
            // CAJU_GOLDEN_DUMP=<dir>: grava a imagem (PPM) e as amostras para regenerar a referência.
            if let dir = ProcessInfo.processInfo.environment["CAJU_GOLDEN_DUMP"] {
                var ppm = Array("P6 \(CajuSceneGolden.side) \(CajuSceneGolden.side) 255\n".utf8)
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    ppm += [bytes[i + 2], bytes[i + 1], bytes[i]]
                }
                try Data(ppm).write(to: URL(fileURLWithPath: dir).appendingPathComponent("scene-metal.ppm"))
                let samples = CajuSceneGolden.samples(bytes).map(String.init).joined(separator: ", ")
                try Data(samples.utf8).write(
                    to: URL(fileURLWithPath: dir).appendingPathComponent("samples.txt"))
            }
            let problems = CajuSceneGolden.check(bytes)
            #expect(problems.isEmpty, "\(problems)")
            #expect(device.transientTextureCount == 2)
        }

        /// *Skinning* rígido posado pela arena = a mesma malha sem pele transformada (R-1b).
        @Test func skinningMatchesRigidTransform() throws {
            metalAllocationLock.lock()
            defer { metalAllocationLock.unlock() }
            let device = try CajuMetalDevice.makeSystemDefault()
            let problems = try CajuSceneGolden.checkSkinningEquivalence(device: device) {
                texture throws(CajuRHIError) in
                try device.readTexture(texture)
            }
            #expect(problems.isEmpty, "\(problems)")
        }
    }
#endif
