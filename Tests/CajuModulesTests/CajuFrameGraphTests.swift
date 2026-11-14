import CajuRHI
import Testing

@Suite("CajuRHI: frame graph")
struct CajuFrameGraphTests {
    private let caps = CajuNullDevice.defaultCapabilities

    private func color(
        _ r: CajuFrameGraphResource, load: CajuLoadAction = .clear(SIMD4(0, 0, 0, 1)),
        store: CajuStoreAction = .store, resolve: CajuFrameGraphResource? = nil
    ) -> CajuColorAttachment {
        CajuColorAttachment(
            texture: .resource(r), load: load, store: store, resolveTexture: resolve.map { .resource($0) })
    }

    private func rt(_ format: CajuPixelFormat = .rgba8Unorm, samples: Int = 1, size: Int = 256)
        -> CajuTextureDescriptor
    {
        CajuTextureDescriptor(
            format: format, width: size, height: size, sampleCount: samples, usage: .renderTarget)
    }

    @Test func msaaDepthBecomeMemorylessAndUnusedPassIsCulled() throws {
        var g = CajuFrameGraphBuilder()
        let backbuffer = g.importTexture(format: .bgra8UnormSRGB, name: "backbuffer")
        let msaa = g.createTransient(rt(.bgra8UnormSRGB, samples: 4), name: "msaa")
        let depth = g.createTransient(rt(.depth32Float, samples: 4), name: "depth")
        let orphan = g.createTransient(rt(), name: "orphan")
        g.addPass(
            CajuFrameGraphPass(
                name: "unused", render: CajuRenderPassDescriptor(colorAttachments: [color(orphan)])))
        g.addPass(
            CajuFrameGraphPass(
                name: "scene",
                render: CajuRenderPassDescriptor(
                    colorAttachments: [color(msaa, store: .resolve, resolve: backbuffer)],
                    depthAttachment: CajuDepthAttachment(texture: .resource(depth), store: .dontCare))))
        let graph = try g.compile(capabilities: caps)
        #expect(graph.stats.culledPasses == 1)
        #expect(graph.livePasses.map(\.pass.name) == ["scene"])
        #expect(graph.plan[msaa.index] == .memoryless)
        #expect(graph.plan[depth.index] == .memoryless)
        #expect(graph.plan[orphan.index] == .unused)
        #expect(graph.plan[backbuffer.index] == .imported)
        #expect(graph.stats.memorylessTextures == 2)
        #expect(graph.stats.aliasedBytes == 0)
    }

    @Test func memorylessDisabledWhenDeviceLacksSupport() throws {
        var c = caps
        c.supportsMemoryless = false
        var g = CajuFrameGraphBuilder()
        let backbuffer = g.importTexture(format: .bgra8Unorm)
        let msaa = g.createTransient(rt(.bgra8Unorm, samples: 4))
        g.addPass(
            CajuFrameGraphPass(
                name: "p",
                render: CajuRenderPassDescriptor(colorAttachments: [
                    color(msaa, store: .resolve, resolve: backbuffer)
                ])))
        let graph = try g.compile(capabilities: c)
        #expect(graph.plan[msaa.index] == .aliased(slot: 0))
        #expect(graph.stats.memorylessTextures == 0)
    }

    @Test func transientsWithDisjointLifetimesShareASlot() throws {
        var g = CajuFrameGraphBuilder()
        let out = g.importTexture(format: .bgra8Unorm)
        let a = g.createTransient(rt(size: 512), name: "a")  // pass0 escreve, pass1 lê
        let b = g.createTransient(rt(size: 512), name: "b")  // pass1 escreve, pass2 lê
        let c = g.createTransient(rt(size: 512), name: "c")  // pass2 escreve, pass3 lê
        g.addPass(CajuFrameGraphPass(name: "p0", render: .init(colorAttachments: [color(a)])))
        g.addPass(CajuFrameGraphPass(name: "p1", reads: [a], render: .init(colorAttachments: [color(b)])))
        g.addPass(CajuFrameGraphPass(name: "p2", reads: [b], render: .init(colorAttachments: [color(c)])))
        g.addPass(CajuFrameGraphPass(name: "p3", reads: [c], render: .init(colorAttachments: [color(out)])))
        let graph = try g.compile(capabilities: caps)
        let slots = [a, b, c].compactMap { r -> Int? in
            if case .aliased(let s) = graph.plan[r.index] { s } else { nil }
        }
        #expect(slots.count == 3)
        // a e c nunca vivem juntos (a: 0..1, c: 2..3): compartilham; b vive de 1 a 2 e encosta nos dois.
        #expect(slots[0] == slots[2])
        #expect(slots[0] != slots[1])
        #expect(graph.stats.aliasSlots == 2)
        #expect(graph.stats.aliasedBytes < graph.stats.unaliasedBytes)
        #expect(graph.stats.unaliasedBytes == 3 * 512 * 512 * 4)
        #expect(graph.stats.aliasedBytes == 2 * 512 * 512 * 4)
    }

    @Test func readBeforeWriteIsRejected() {
        var g = CajuFrameGraphBuilder()
        let out = g.importTexture(format: .bgra8Unorm)
        let t = g.createTransient(rt())
        g.addPass(CajuFrameGraphPass(name: "p", reads: [t], render: .init(colorAttachments: [color(out)])))
        #expect(throws: CajuRHIError.invalidFrameGraph(.readBeforeWrite(resource: t.index, pass: 0))) {
            try g.compile(capabilities: caps)
        }
    }

    @Test func graphWithoutOutputsAndUnknownResourcesAreRejected() {
        var g = CajuFrameGraphBuilder()
        let t = g.createTransient(rt())
        g.addPass(CajuFrameGraphPass(name: "p", render: .init(colorAttachments: [color(t)])))
        #expect(throws: CajuRHIError.invalidFrameGraph(.noOutputs)) { try g.compile(capabilities: caps) }

        var h = CajuFrameGraphBuilder()
        h.addPass(CajuFrameGraphPass(name: "p", kind: .copy, reads: [CajuFrameGraphResource(index: 7)]))
        #expect(throws: CajuRHIError.invalidFrameGraph(.unknownResource(index: 7))) {
            try h.compile(capabilities: caps)
        }

        var k = CajuFrameGraphBuilder()
        k.addPass(CajuFrameGraphPass(name: "no-desc", kind: .render, hasSideEffects: true))
        #expect(throws: CajuRHIError.invalidFrameGraph(.invalidPass(pass: 0))) {
            try k.compile(capabilities: caps)
        }
    }

    @Test func explicitMemorylessThatPersistsIsRejected() {
        var g = CajuFrameGraphBuilder()
        let out = g.importTexture(format: .bgra8Unorm)
        var d = rt()
        d.storage = .memoryless
        let t = g.createTransient(d)
        g.addPass(CajuFrameGraphPass(name: "a", render: .init(colorAttachments: [color(t)])))
        g.addPass(CajuFrameGraphPass(name: "b", reads: [t], render: .init(colorAttachments: [color(out)])))
        #expect(throws: CajuRHIError.invalidUsage(.memorylessMustNotPersist)) {
            try g.compile(capabilities: caps)
        }
    }

    @Test func executesOnNullDeviceInOrderAndReusesTransients() throws {
        let device = CajuNullDevice()
        var g = CajuFrameGraphBuilder()
        let out = g.importTexture(format: .bgra8Unorm, name: "out")
        let offscreen = g.createTransient(rt(.bgra8Unorm, size: 64), name: "offscreen")
        let msaa = g.createTransient(rt(.bgra8Unorm, samples: 4, size: 64), name: "msaa")
        g.addPass(CajuFrameGraphPass(name: "shadow", render: .init(colorAttachments: [color(offscreen)])))
        g.addPass(
            CajuFrameGraphPass(
                name: "main", reads: [offscreen],
                render: .init(colorAttachments: [color(msaa, store: .resolve, resolve: out)])))
        let graph = try g.compile(capabilities: device.capabilities)
        let target = try device.createTexture(
            CajuTextureDescriptor(format: .bgra8Unorm, width: 64, height: 64, usage: .renderTarget))

        var executor = CajuFrameGraphExecutor()
        executor.prepare(graph)
        var order: [Int] = []
        for _ in 0..<3 {
            executor.bind(out, to: target)
            var cb = try device.queue.makeCommandBuffer(label: "frame")
            try executor.execute(graph, device: device, commandBuffer: &cb) { id, encoder in
                order.append(id.index)
                encoder.setViewport(CajuViewport(width: 64, height: 64))
            }
            try device.queue.submit(cb)
        }
        #expect(order == [0, 1, 0, 1, 0, 1])
        #expect(device.submitCount == 3)
        #expect(device.transientTextureCount == 2)  // transientes reutilizados quadro a quadro
        #expect(device.transientBytes == 64 * 64 * 4)  // só o offscreen tem memória; o MSAA é memoryless
    }

    @Test func executorRequiresPrepare() throws {
        let device = CajuNullDevice()
        var g = CajuFrameGraphBuilder()
        let out = g.importTexture(format: .bgra8Unorm)
        g.addPass(CajuFrameGraphPass(name: "p", render: .init(colorAttachments: [color(out)])))
        let graph = try g.compile(capabilities: device.capabilities)
        var executor = CajuFrameGraphExecutor()
        var cb = try device.queue.makeCommandBuffer(label: "f")
        #expect(throws: CajuRHIError.self) {
            try executor.execute(graph, device: device, commandBuffer: &cb, render: { _, _ in })
        }
    }
}
