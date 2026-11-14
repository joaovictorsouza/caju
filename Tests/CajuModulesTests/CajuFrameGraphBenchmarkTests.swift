import CajuRHI
import Testing

/// Benchmark de CPU do frame graph (TB-2): mede `compile()` e `execute()` no backend null. Só imprime
/// mediana e p95; o gate de regressão exige linha de base de aparelho (docs/standards/performance.md).
@Suite("CajuRHI: benchmark do frame graph", .serialized)
struct CajuFrameGraphBenchmarkTests {
    private func makeGraph(passes: Int) -> CajuFrameGraphBuilder {
        var g = CajuFrameGraphBuilder()
        let out = g.importTexture(format: .bgra8Unorm, name: "out")
        var previous: CajuFrameGraphResource?
        for i in 0..<passes {
            let isLast = i == passes - 1
            let target =
                isLast
                ? out
                : g.createTransient(
                    CajuTextureDescriptor(
                        format: .bgra8Unorm, width: 512, height: 512, usage: [.renderTarget, .sampled]))
            g.addPass(
                CajuFrameGraphPass(
                    name: "p\(i)", reads: previous.map { [$0] } ?? [],
                    render: CajuRenderPassDescriptor(colorAttachments: [
                        CajuColorAttachment(texture: .resource(target))
                    ])))
            previous = target
        }
        return g
    }

    private func microseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
    }

    private func stats(_ samples: [Double]) -> (median: Double, p95: Double) {
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)])
    }

    @Test(arguments: [5, 50]) func compileAndExecute(passes: Int) throws {
        let device = CajuNullDevice()
        let builder = makeGraph(passes: passes)
        let clock = ContinuousClock()
        let iterations = 1000

        var compileSamples: [Double] = []
        var graph = try builder.compile(capabilities: device.capabilities)
        for _ in 0..<iterations {
            let t = clock.measure {
                if let g = try? builder.compile(capabilities: device.capabilities) { graph = g }
            }
            compileSamples.append(microseconds(t))
        }

        let target = try device.createTexture(
            CajuTextureDescriptor(format: .bgra8Unorm, width: 512, height: 512, usage: .renderTarget))
        var executor = CajuFrameGraphExecutor()
        executor.prepare(graph)
        var executeSamples: [Double] = []
        for _ in 0..<iterations {
            executor.bind(CajuFrameGraphResource(index: 0), to: target)
            var failed = false
            let t = clock.measure {
                guard var cb = try? device.queue.makeCommandBuffer(label: "f") else {
                    failed = true
                    return
                }
                do {
                    try executor.execute(graph, device: device, commandBuffer: &cb) { _, encoder in
                        encoder.setViewport(CajuViewport(width: 512, height: 512))
                    }
                } catch { failed = true }
                if (try? device.queue.submit(cb)) == nil { failed = true }
            }
            #expect(!failed)
            executeSamples.append(microseconds(t))
            device.clearRecordedCommands()
        }
        let c = stats(compileSamples)
        let e = stats(executeSamples)
        print(
            "TB-2 frame graph \(passes) passes: compile mediana \(c.median) us p95 \(c.p95) us; "
                + "execute+submit (null) mediana \(e.median) us p95 \(e.p95) us")
        #expect(graph.stats.livePasses == passes)
    }
}
