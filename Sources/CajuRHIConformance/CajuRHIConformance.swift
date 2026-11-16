import CajuMath
import CajuRHI

// Suíte de conformidade do RHI (ADR 0015, ADR 0024): os mesmos casos e os mesmos valores esperados rodam em
// todo backend. O Metal a executa nos testes (`CajuMetalTests`); o Vulkan, num executável no aparelho
// (`Hosts/Android`, sem janela). Sem `Testing`/XCTest: o resultado é um relatório, então roda em qualquer lugar.

/// O que um backend fornece à suíte: o dispositivo, os shaders do triângulo e a leitura de pixels.
public protocol CajuConformanceBackend {
    associatedtype Device: CajuRenderDevice
    var device: Device { get }

    /// Shaders do triângulo de conformidade: vértices (-0.6,-0.6), (0.6,-0.6), (0.0,0.7) em NDC com y para
    /// cima (sentido anti-horário) e fragmento vermelho opaco `(1, 0, 0, 1)`, sem atributos de vértice.
    func makeTriangleShaders() throws(CajuRHIError) -> (
        vertex: CajuShaderFunction, fragment: CajuShaderFunction
    )

    /// Bytes do mip 0 de uma textura `shared` de 1 amostra, linha a linha, sem preenchimento. O chamador já
    /// esperou `queue.waitUntilIdle()`.
    func readTexture(_ texture: CajuTextureHandle) throws(CajuRHIError) -> [UInt8]
}

/// Resultado da suíte: nomes dos casos que passaram e falhas com detalhe.
public struct CajuConformanceReport: Sendable, Equatable {
    public var passed: [String] = []
    public var failures: [Failure] = []

    public struct Failure: Sendable, Equatable {
        public var caseName: String
        public var detail: String
    }

    public var isClean: Bool { failures.isEmpty }
}

/// Acumula as verificações de um caso.
public struct CajuConformanceChecker {
    fileprivate(set) var details: [String] = []

    public mutating func expect(_ condition: Bool, _ detail: @autoclosure () -> String) {
        if !condition { details.append(detail()) }
    }
}

public enum CajuRHIConformance {
    /// Tamanho do alvo dos goldens, em pixels.
    static let side = 64
    /// Cor de fundo (azul-escuro) e cor do triângulo (vermelho) esperadas, em BGRA.
    static let clear = SIMD4<Float>(0, 0, 0.5, 1)

    /// Executa todos os casos. Um caso que lança erro inesperado conta como falha, não interrompe a suíte.
    public static func run<B: CajuConformanceBackend>(_ backend: B) -> CajuConformanceReport {
        var report = CajuConformanceReport()
        func record(_ name: String, _ body: (inout CajuConformanceChecker) throws -> Void) {
            var checker = CajuConformanceChecker()
            do { try body(&checker) } catch {
                checker.details.append("erro inesperado: \(error)")
            }
            if checker.details.isEmpty {
                report.passed.append(name)
            } else {
                for detail in checker.details {
                    report.failures.append(.init(caseName: name, detail: detail))
                }
            }
        }
        record("singleSampleTriangleGolden") { try singleSampleTriangle(backend, &$0) }
        record("msaaResolveGolden") { try msaaResolve(backend, &$0) }
        record("cullAndWindingFollowYUpNDC") { try cullAndWinding(backend, &$0) }
        record("textureUploadRoundTrip") { try textureUpload(backend, &$0) }
        record("renderPassValidationMatchesNull") { try validationMatchesNull(backend, &$0) }
        record("destroyedHandlesAreRejected") { try destroyedHandles(backend, &$0) }
        return report
    }

    // MARK: Auxiliares

    private struct BGRA: Equatable {
        var b: UInt8
        var g: UInt8
        var r: UInt8
        var a: UInt8
    }

    private static func pixel(_ bytes: [UInt8], x: Int, y: Int) -> BGRA {
        let i = (y * side + x) * 4
        return BGRA(b: bytes[i], g: bytes[i + 1], r: bytes[i + 2], a: bytes[i + 3])
    }

    private static func makePipeline<B: CajuConformanceBackend>(
        _ backend: B, sampleCount: Int, cull: CajuCullMode, frontFace: CajuWinding
    ) throws(CajuRHIError) -> CajuRenderPipelineHandle {
        let shaders = try backend.makeTriangleShaders()
        return try backend.device.createRenderPipeline(
            CajuRenderPipelineDescriptor(
                vertex: shaders.vertex, fragment: shaders.fragment,
                colorTargets: [CajuColorTargetState(format: .bgra8Unorm)], cullMode: cull,
                frontFace: frontFace, sampleCount: sampleCount))
    }

    private static func makeTarget<D: CajuRenderDevice>(_ device: D) throws(CajuRHIError) -> CajuTextureHandle
    {
        try device.createTexture(
            CajuTextureDescriptor(
                format: .bgra8Unorm, width: side, height: side,
                usage: [.renderTarget, .sampled, .copySource],
                storage: .shared))
    }

    /// Desenha o triângulo num alvo 64x64 e devolve os pixels. `msaa` liga MSAA 4x resolvido para o alvo.
    private static func renderTriangle<B: CajuConformanceBackend>(
        _ backend: B, msaa: Bool, cull: CajuCullMode = .none, frontFace: CajuWinding = .counterClockwise
    ) throws(CajuRHIError) -> [UInt8] {
        let device = backend.device
        let pipeline = try makePipeline(backend, sampleCount: msaa ? 4 : 1, cull: cull, frontFace: frontFace)
        let out = try makeTarget(device)
        var color = CajuColorAttachment(texture: .texture(out), load: .clear(clear), store: .store)
        if msaa {
            let storage: CajuStorageMode = device.capabilities.supportsMemoryless ? .memoryless : .privateGPU
            let multisampled = try device.createTexture(
                CajuTextureDescriptor(
                    format: .bgra8Unorm, width: side, height: side, sampleCount: 4, usage: .renderTarget,
                    storage: storage))
            color = CajuColorAttachment(
                texture: .texture(multisampled), load: .clear(clear), store: .resolve,
                resolveTexture: .texture(out))
        }
        var commands = try device.queue.makeCommandBuffer(label: "conformance")
        try commands.withRenderPass(CajuRenderPassDescriptor(colorAttachments: [color])) { encoder in
            encoder.setPipeline(pipeline)
            encoder.draw(vertexCount: 3)
        }
        try device.queue.submit(commands)
        try device.queue.waitUntilIdle()
        let bytes = try backend.readTexture(out)
        device.destroy(out)
        device.destroy(pipeline)
        return bytes
    }

    // MARK: Casos

    /// Triângulo vermelho sobre fundo azul-escuro: fundo e centro exatos, borda sem pixels misturados
    /// e cobertura dentro de ±5 % da área geométrica (799 de 4096 pixels).
    private static func singleSampleTriangle<B: CajuConformanceBackend>(
        _ backend: B, _ check: inout CajuConformanceChecker
    ) throws(CajuRHIError) {
        let bytes = try renderTriangle(backend, msaa: false)
        let background = BGRA(b: 128, g: 0, r: 0, a: 255)
        let red = BGRA(b: 0, g: 0, r: 255, a: 255)
        check.expect(pixel(bytes, x: 2, y: 2) == background, "fundo em (2,2): \(pixel(bytes, x: 2, y: 2))")
        check.expect(pixel(bytes, x: 32, y: 36) == red, "centro em (32,36): \(pixel(bytes, x: 32, y: 36))")
        // Origem no canto superior esquerdo e NDC com y para cima: o vértice (0, 0.7) fica no topo.
        check.expect(pixel(bytes, x: 32, y: 14) == red, "ápice em (32,14): \(pixel(bytes, x: 32, y: 14))")
        check.expect(pixel(bytes, x: 32, y: 60) == background, "abaixo da base em (32,60)")
        var covered = 0
        var mixed = 0
        for y in 0..<side {
            for x in 0..<side {
                let p = pixel(bytes, x: x, y: y)
                if p == red { covered += 1 } else if p != background { mixed += 1 }
            }
        }
        check.expect(mixed == 0, "pixels misturados sem MSAA: \(mixed)")
        check.expect(abs(covered - 799) <= 40, "cobertura \(covered) fora de 799 ± 40")
    }

    /// MSAA 4x resolvido: mesmo fundo e centro, e a borda tem pixels misturados (amostras diferentes).
    private static func msaaResolve<B: CajuConformanceBackend>(
        _ backend: B, _ check: inout CajuConformanceChecker
    ) throws(CajuRHIError) {
        guard backend.device.capabilities.sampleCounts.supports(4) else { return }
        let bytes = try renderTriangle(backend, msaa: true)
        check.expect(
            pixel(bytes, x: 2, y: 2) == BGRA(b: 128, g: 0, r: 0, a: 255), "fundo em (2,2)")
        check.expect(
            pixel(bytes, x: 32, y: 36) == BGRA(b: 0, g: 0, r: 255, a: 255), "centro em (32,36)")
        var blended = 0
        for y in 0..<side {
            for x in 0..<side {
                let p = pixel(bytes, x: x, y: y)
                if p.r > 10, p.r < 245 { blended += 1 }
            }
        }
        check.expect(blended > 20, "pixels misturados com MSAA: \(blended) (esperado > 20)")
    }

    /// O triângulo é anti-horário no NDC com y para cima: `cullMode: .back` + `frontFace: .counterClockwise`
    /// o desenha; com `frontFace: .clockwise` ele é descartado. Vale igual em Metal e Vulkan.
    private static func cullAndWinding<B: CajuConformanceBackend>(
        _ backend: B, _ check: inout CajuConformanceChecker
    ) throws(CajuRHIError) {
        let red = BGRA(b: 0, g: 0, r: 255, a: 255)
        let drawn = try renderTriangle(backend, msaa: false, cull: .back, frontFace: .counterClockwise)
        check.expect(pixel(drawn, x: 32, y: 36) == red, "anti-horário com cull back deveria desenhar")
        let culled = try renderTriangle(backend, msaa: false, cull: .back, frontFace: .clockwise)
        check.expect(pixel(culled, x: 32, y: 36) != red, "horário com cull back deveria descartar")
        let front = try renderTriangle(backend, msaa: false, cull: .front, frontFace: .clockwise)
        check.expect(pixel(front, x: 32, y: 36) == red, "cull front com frente horária deveria desenhar")
    }

    /// `writeTexture` seguido de leitura devolve os mesmos bytes (caminho de upload síncrono).
    private static func textureUpload<B: CajuConformanceBackend>(
        _ backend: B, _ check: inout CajuConformanceChecker
    ) throws(CajuRHIError) {
        let device = backend.device
        let texture = try device.createTexture(
            CajuTextureDescriptor(
                format: .bgra8Unorm, width: side, height: side, usage: [.sampled, .copySource],
                storage: .shared))
        var source = [UInt8](repeating: 0, count: side * side * 4)
        for i in source.indices { source[i] = UInt8(truncatingIfNeeded: i &* 7 &+ i >> 8) }
        var uploadError: CajuRHIError?
        source.withUnsafeBytes { raw in
            do throws(CajuRHIError) {
                try device.writeTexture(
                    texture, mipLevel: 0, slice: 0, width: side, height: side, bytesPerRow: side * 4,
                    bytes: raw)
            } catch { uploadError = error }
        }
        if let uploadError { throw uploadError }
        try device.queue.waitUntilIdle()
        let back = try backend.readTexture(texture)
        check.expect(back == source, "bytes lidos diferem dos enviados")
        device.destroy(texture)
    }

    /// As violações de memoryless/resolve do contrato dão os mesmos erros que o `CajuNullDevice`.
    private static func validationMatchesNull<B: CajuConformanceBackend>(
        _ backend: B, _ check: inout CajuConformanceChecker
    ) throws(CajuRHIError) {
        guard backend.device.capabilities.supportsMemoryless,
            backend.device.capabilities.sampleCounts.supports(4)
        else { return }
        func run<D: CajuRenderDevice>(_ device: D) throws(CajuRHIError) -> [CajuRHIError?] {
            let msaa = try device.createTexture(
                CajuTextureDescriptor(
                    format: .bgra8Unorm, width: 32, height: 32, sampleCount: 4, usage: .renderTarget,
                    storage: .memoryless))
            let resolve = try device.createTexture(
                CajuTextureDescriptor(format: .bgra8Unorm, width: 32, height: 32, usage: .renderTarget))
            let cases: [CajuColorAttachment] = [
                CajuColorAttachment(texture: .texture(msaa), load: .dontCare, store: .store),
                CajuColorAttachment(texture: .texture(msaa), load: .load, store: .dontCare),
                CajuColorAttachment(texture: .texture(msaa), load: .dontCare, store: .resolve),
                CajuColorAttachment(
                    texture: .texture(msaa), load: .dontCare, store: .resolve,
                    resolveTexture: .texture(resolve)),
            ]
            var results: [CajuRHIError?] = []
            for attachment in cases {
                var commands = try device.queue.makeCommandBuffer(label: "validation")
                do throws(CajuRHIError) {
                    try commands.withRenderPass(CajuRenderPassDescriptor(colorAttachments: [attachment])) {
                        _ in
                    }
                    results.append(nil)
                } catch { results.append(error) }
                try device.queue.submit(commands)
            }
            return results
        }
        let actual = try run(backend.device)
        let expected = try run(CajuNullDevice())
        check.expect(actual == expected, "erros \(actual) ≠ null \(expected)")
        check.expect(
            actual.first == .invalidUsage(.memorylessMustNotPersist),
            "caso 0: \(String(describing: actual.first))")
        check.expect(actual.last == .some(nil), "caso 3 deveria passar: \(String(describing: actual.last))")
    }

    /// Usar um recurso destruído falha com `.invalidHandle`, nunca corrompe memória.
    private static func destroyedHandles<B: CajuConformanceBackend>(
        _ backend: B, _ check: inout CajuConformanceChecker
    ) throws(CajuRHIError) {
        let device = backend.device
        let buffer = try device.createBuffer(CajuBufferDescriptor(size: 64, usage: .uniform))
        device.destroy(buffer)
        var failure: CajuRHIError?
        [UInt8](repeating: 0, count: 4).withUnsafeBytes { raw in
            do throws(CajuRHIError) { try device.writeBuffer(buffer, offset: 0, bytes: raw) } catch {
                failure = error
            }
        }
        check.expect(
            failure == .invalidHandle(index: buffer.index, generation: buffer.generation),
            "escrita em buffer destruído: \(String(describing: failure))")
    }
}
