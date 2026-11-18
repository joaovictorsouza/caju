// Executável da suíte de conformidade do RHI no backend Vulkan (ADR 0015, ADR 0024).
//
// Roda sem janela por `adb shell` (Android) e imprime um relatório; sai com código 1 se algum caso falhar.
// Os mesmos casos e valores esperados rodam no Metal em `CajuMetalTests`.
#if os(Android)
    import CajuRHI
    import CajuRHIConformance
    import CajuRHIVulkan
    import CajuRender

    #if canImport(Glibc)
        import Glibc
    #elseif canImport(Android)
        import Android
    #endif

    struct VulkanConformanceBackend: CajuConformanceBackend {
        let device: CajuVulkanDevice

        func makeTriangleShaders() throws(CajuRHIError) -> (
            vertex: CajuShaderFunction, fragment: CajuShaderFunction
        ) {
            let vertex = try device.createShaderModule(
                CajuShaderModuleDescriptor(format: .spirv, code: bytes(ConformanceShaders.vertex)))
            let fragment = try device.createShaderModule(
                CajuShaderModuleDescriptor(format: .spirv, code: bytes(ConformanceShaders.fragment)))
            return (
                CajuShaderFunction(module: vertex, entryPoint: "main"),
                CajuShaderFunction(module: fragment, entryPoint: "main")
            )
        }

        func readTexture(_ texture: CajuTextureHandle) throws(CajuRHIError) -> [UInt8] {
            try device.readTexture(texture)
        }

        private func bytes(_ words: [UInt32]) -> [UInt8] {
            words.withUnsafeBytes { [UInt8]($0) }
        }
    }

    /// Escreve direto no descritor 1 (sem o buffer do `print`): o relatório sai mesmo se o processo abortar.
    func emit(_ text: String) {
        var line = text + "\n"
        line.withUTF8 { bytes in _ = write(1, bytes.baseAddress, bytes.count) }
    }

    func runConformance() -> Int32 {
        let device: CajuVulkanDevice
        do { device = try CajuVulkanDevice() } catch {
            emit("FALHA ao criar o dispositivo Vulkan: \(error)")
            return 2
        }
        let caps = device.capabilities
        emit("dispositivo: \(caps.deviceName) (\(caps.backendName))")
        emit(
            "memoryless=\(caps.supportsMemoryless) amostras=\(caps.sampleCounts.rawValue) "
                + "astc=\(caps.supportsASTC) maxTex=\(caps.maxTextureDimension2D)")
        let report = CajuRHIConformance.run(VulkanConformanceBackend(device: device))
        for name in report.passed { emit("PASSOU \(name)") }
        for failure in report.failures { emit("FALHOU \(failure.caseName): \(failure.detail)") }
        // Golden de cena da R-1a (o mesmo do Metal): cubo unlit + esfera PBR, MSAA 4x.
        var sceneClean = true
        do {
            let bytes = try CajuSceneGolden.render(device: device) { texture throws(CajuRHIError) in
                try device.readTexture(texture)
            }
            let problems = CajuSceneGolden.check(bytes)
            sceneClean = problems.isEmpty
            emit(problems.isEmpty ? "PASSOU sceneGoldenR1a" : "FALHOU sceneGoldenR1a: \(problems)")
            let samples = CajuSceneGolden.samples(bytes).map(String.init).joined(separator: ",")
            emit("amostras sceneGoldenR1a: \(samples)")
        } catch {
            sceneClean = false
            emit("FALHOU sceneGoldenR1a: erro \(error)")
        }
        // Skinning da R-1b: pele rígida posada = mesma malha transformada.
        do {
            let problems = try CajuSceneGolden.checkSkinningEquivalence(device: device) {
                texture throws(CajuRHIError) in try device.readTexture(texture)
            }
            if !problems.isEmpty { sceneClean = false }
            emit(problems.isEmpty ? "PASSOU skinningR1b" : "FALHOU skinningR1b: \(problems)")
        } catch {
            sceneClean = false
            emit("FALHOU skinningR1b: erro \(error)")
        }
        emit(
            "recursos vivos=\(device.liveResourceCount) destruição pendente=\(device.pendingDestructionCount) "
                + "bytes VMA=\(device.allocatedBytes)")
        emit("resultado: \(report.passed.count) passaram, \(report.failures.count) falhas")
        return report.isClean && sceneClean ? 0 : 1
    }

    exit(runConformance())
#else
    print("caju-conformance roda só no Android (backend Vulkan).")
#endif
