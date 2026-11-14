// Frame graph: declaração de passes e recursos, compilação (corte, lifetimes, aliasing, memoryless)
// e execução. A declaração e a compilação são puras (sem GPU): rodam em Linux e em testes headless.

/// Recurso do grafo (textura transitória ou importada). Índice opaco, válido só no grafo que o criou.
public struct CajuFrameGraphResource: Sendable, Hashable {
    public let index: Int
    @inlinable public init(index: Int) { self.index = index }
}

/// Identificador de um passe (posição na declaração).
public struct CajuFrameGraphPassID: Sendable, Hashable {
    public let index: Int
    @inlinable public init(index: Int) { self.index = index }
}

public enum CajuFrameGraphPassKind: UInt8, Sendable, Hashable {
    case render
    case compute
    case copy
}

/// Declaração de um passe.
public struct CajuFrameGraphPass: Sendable, Equatable {
    public var name: String
    public var kind: CajuFrameGraphPassKind
    /// Recursos lidos como textura amostrada ou cópia (além de attachments com `load`).
    public var reads: [CajuFrameGraphResource]
    /// Recursos escritos fora de attachments (compute `storage`, destino de cópia).
    public var writes: [CajuFrameGraphResource]
    /// Descrição do passe de render (só para `kind == .render`); attachments referenciam recursos do grafo.
    public var render: CajuRenderPassDescriptor?
    /// Passes com efeito colateral nunca são cortados (ex.: readback, captura).
    public var hasSideEffects: Bool

    public init(
        name: String, kind: CajuFrameGraphPassKind = .render, reads: [CajuFrameGraphResource] = [],
        writes: [CajuFrameGraphResource] = [], render: CajuRenderPassDescriptor? = nil,
        hasSideEffects: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.reads = reads
        self.writes = writes
        self.render = render
        self.hasSideEffects = hasSideEffects
    }
}

/// Origem de um recurso do grafo.
public enum CajuFrameGraphResourceKind: Sendable, Equatable {
    /// Existe fora do grafo (imagem do *swapchain*, textura persistente). É sempre uma saída visível.
    case imported(CajuPixelFormat)
    /// Vive só dentro do quadro; o grafo decide `memoryless` ou *slot* de aliasing.
    case transient(CajuTextureDescriptor)
}

/// Construtor do grafo de um quadro. Compile uma vez e reuse enquanto a topologia não mudar.
public struct CajuFrameGraphBuilder: Sendable {
    public static let maxPasses = 256
    public static let maxResources = 256

    public private(set) var resources: [CajuFrameGraphResourceKind] = []
    public private(set) var resourceNames: [String] = []
    public private(set) var passes: [CajuFrameGraphPass] = []

    public init() {}

    /// Declara um recurso externo (a textura real é ligada na execução).
    public mutating func importTexture(format: CajuPixelFormat, name: String = "") -> CajuFrameGraphResource {
        resources.append(.imported(format))
        resourceNames.append(name)
        return CajuFrameGraphResource(index: resources.count - 1)
    }

    /// Declara uma textura transitória (`TransientAttachment` quando usada só como attachment de um passe).
    public mutating func createTransient(_ descriptor: CajuTextureDescriptor, name: String = "")
        -> CajuFrameGraphResource
    {
        resources.append(.transient(descriptor))
        resourceNames.append(name)
        return CajuFrameGraphResource(index: resources.count - 1)
    }

    @discardableResult
    public mutating func addPass(_ pass: CajuFrameGraphPass) -> CajuFrameGraphPassID {
        passes.append(pass)
        return CajuFrameGraphPassID(index: passes.count - 1)
    }

    /// Valida e compila. `capabilities` decide se `memoryless` é usado.
    public func compile(capabilities: CajuDeviceCapabilities) throws(CajuRHIError) -> CajuCompiledFrameGraph {
        try CajuCompiledFrameGraph.compile(self, capabilities: capabilities)
    }
}

/// Plano de memória de um recurso.
public enum CajuResourcePlan: Sendable, Equatable {
    case imported
    /// Usado só como attachment de um passe e descartado: sem memória (tile memory).
    case memoryless
    /// Textura com memória; texturas no mesmo `slot` têm lifetimes disjuntos e compartilham memória.
    case aliased(slot: Int)
    /// Nunca usado por passe vivo: não é criado.
    case unused
}

/// Estatísticas do plano de memória (bytes estimados pelo descritor).
public struct CajuFrameGraphStats: Sendable, Equatable {
    public var totalPasses = 0
    public var livePasses = 0
    public var culledPasses = 0
    public var memorylessTextures = 0
    public var aliasSlots = 0
    /// Memória se cada transiente tivesse textura própria.
    public var unaliasedBytes = 0
    /// Memória com aliasing e `memoryless` (soma do maior tamanho de cada slot).
    public var aliasedBytes = 0
}

/// Grafo compilado: passes vivos em ordem de declaração, plano de memória e estatísticas.
public struct CajuCompiledFrameGraph: Sendable {
    public struct LivePass: Sendable {
        public var id: CajuFrameGraphPassID
        public var pass: CajuFrameGraphPass
    }

    public let resources: [CajuFrameGraphResourceKind]
    public let livePasses: [LivePass]
    public let plan: [CajuResourcePlan]
    /// Primeiro e último passe vivo (posição em `livePasses`) que usa cada recurso; `-1` se não usado.
    public let firstUse: [Int]
    public let lastUse: [Int]
    public let stats: CajuFrameGraphStats
    /// Descritor efetivo de cada transiente (com `storage` ajustado ao plano).
    public let effectiveDescriptors: [CajuTextureDescriptor?]

    /// Quantidade de recursos importados, em ordem de declaração.
    public var importedCount: Int {
        resources.reduce(0) { if case .imported = $1 { $0 + 1 } else { $0 } }
    }

    // MARK: Compilação

    private struct Use {
        var asAttachmentWithoutPersist = true
        var passes = 0
        var written = false
    }

    static func compile(_ b: CajuFrameGraphBuilder, capabilities: CajuDeviceCapabilities)
        throws(CajuRHIError) -> CajuCompiledFrameGraph
    {
        guard b.passes.count <= CajuFrameGraphBuilder.maxPasses else {
            throw .invalidFrameGraph(.tooManyPasses)
        }
        guard b.resources.count <= CajuFrameGraphBuilder.maxResources else {
            throw .invalidFrameGraph(.tooManyResources)
        }
        let n = b.resources.count
        let passCount = b.passes.count

        // 1. Leituras e escritas efetivas por passe (declaradas + derivadas dos attachments).
        var reads = [[Int]](repeating: [], count: passCount)
        var writes = [[Int]](repeating: [], count: passCount)
        for (p, pass) in b.passes.enumerated() {
            if pass.kind == .render, pass.render == nil { throw .invalidFrameGraph(.invalidPass(pass: p)) }
            for r in pass.reads {
                guard r.index >= 0, r.index < n else {
                    throw .invalidFrameGraph(.unknownResource(index: r.index))
                }
                reads[p].append(r.index)
            }
            for r in pass.writes {
                guard r.index >= 0, r.index < n else {
                    throw .invalidFrameGraph(.unknownResource(index: r.index))
                }
                writes[p].append(r.index)
            }
            if let render = pass.render {
                for c in render.colorAttachments {
                    try noteAttachment(c.texture, load: c.load, p, n, &reads, &writes)
                    if let r = c.resolveTexture {
                        try noteAttachment(r, load: .dontCare, p, n, &reads, &writes)
                    }
                }
                if let d = render.depthAttachment {
                    try noteAttachment(d.texture, load: d.load, p, n, &reads, &writes)
                }
            }
        }

        // 2. Corte: viva = com efeito colateral, escreve recurso importado ou alimenta passe vivo.
        var live = [Bool](repeating: false, count: passCount)
        var needed = [Bool](repeating: false, count: n)
        for p in stride(from: passCount - 1, through: 0, by: -1) {
            var isLive = b.passes[p].hasSideEffects
            for w in writes[p] {
                if case .imported = b.resources[w] { isLive = true }
                if needed[w] { isLive = true }
            }
            if isLive {
                live[p] = true
                for r in reads[p] { needed[r] = true }
            }
        }
        if !live.contains(true) { throw .invalidFrameGraph(.noOutputs) }

        // 3. Ordem de declaração; leitura exige escrita anterior (de passe vivo) em transientes.
        var written = [Bool](repeating: false, count: n)
        for (i, r) in b.resources.enumerated() { if case .imported = r { written[i] = true } }
        var livePasses: [LivePass] = []
        var first = [Int](repeating: -1, count: n)
        var last = [Int](repeating: -1, count: n)
        var uses = [Use](repeating: Use(), count: n)
        for p in 0..<passCount where live[p] {
            let pos = livePasses.count
            for r in reads[p] {
                guard written[r] else { throw .invalidFrameGraph(.readBeforeWrite(resource: r, pass: p)) }
            }
            for r in reads[p] + writes[p] {
                if first[r] < 0 { first[r] = pos }
                last[r] = pos
                uses[r].passes += 1
            }
            for w in writes[p] { written[w] = true }
            // Uso como attachment que persiste, ou leitura/escrita fora de attachment, impede memoryless.
            let attachmentResources = attachmentUsage(b.passes[p])
            for r in reads[p] where !attachmentResources.nonPersisting.contains(r) {
                uses[r].asAttachmentWithoutPersist = false
            }
            for r in writes[p] where !attachmentResources.nonPersisting.contains(r) {
                uses[r].asAttachmentWithoutPersist = false
            }
            livePasses.append(LivePass(id: CajuFrameGraphPassID(index: p), pass: b.passes[p]))
        }

        // 4. Plano de memória: memoryless, depois aliasing guloso por lifetime.
        var plan = [CajuResourcePlan](repeating: .unused, count: n)
        var effective = [CajuTextureDescriptor?](repeating: nil, count: n)
        var stats = CajuFrameGraphStats()
        stats.totalPasses = passCount
        stats.livePasses = livePasses.count
        stats.culledPasses = passCount - livePasses.count
        var candidates: [Int] = []
        for i in 0..<n {
            switch b.resources[i] {
            case .imported: plan[i] = .imported
            case .transient(var d):
                guard first[i] >= 0 else { continue }
                stats.unaliasedBytes += d.storage == .memoryless ? 0 : sizeIfBacked(d)
                let singlePass = first[i] == last[i]
                let canBeMemoryless =
                    singlePass && uses[i].asAttachmentWithoutPersist && d.usage == .renderTarget
                    && capabilities.supportsMemoryless
                if d.storage == .memoryless {
                    guard capabilities.supportsMemoryless else {
                        throw .unsupported(.memorylessAttachments)
                    }
                    guard singlePass, uses[i].asAttachmentWithoutPersist else {
                        throw .invalidUsage(.memorylessMustNotPersist)
                    }
                    plan[i] = .memoryless
                } else if canBeMemoryless {
                    d.storage = .memoryless
                    plan[i] = .memoryless
                } else {
                    candidates.append(i)
                }
                effective[i] = d
                if plan[i] == .memoryless { stats.memorylessTextures += 1 }
            }
        }
        candidates.sort { first[$0] != first[$1] ? first[$0] < first[$1] : $0 < $1 }
        var slotFreeAfter: [Int] = []  // último uso do ocupante atual de cada slot
        var slotBytes: [Int] = []
        for i in candidates {
            guard let d = effective[i] else { continue }
            let bytes = sizeIfBacked(d)
            var chosen = -1
            for s in 0..<slotFreeAfter.count where slotFreeAfter[s] < first[i] {
                chosen = s
                break
            }
            if chosen < 0 {
                slotFreeAfter.append(last[i])
                slotBytes.append(bytes)
                chosen = slotFreeAfter.count - 1
            } else {
                slotFreeAfter[chosen] = last[i]
                slotBytes[chosen] = max(slotBytes[chosen], bytes)
            }
            plan[i] = .aliased(slot: chosen)
        }
        stats.aliasSlots = slotBytes.count
        stats.aliasedBytes = slotBytes.reduce(0, +)

        return CajuCompiledFrameGraph(
            resources: b.resources, livePasses: livePasses, plan: plan, firstUse: first, lastUse: last,
            stats: stats, effectiveDescriptors: effective)
    }

    private static func sizeIfBacked(_ d: CajuTextureDescriptor) -> Int {
        var copy = d
        if copy.storage == .memoryless { copy.storage = .privateGPU }
        return copy.estimatedByteSize
    }

    private static func noteAttachment(
        _ t: CajuAttachmentTexture, load: CajuLoadAction, _ p: Int, _ n: Int, _ reads: inout [[Int]],
        _ writes: inout [[Int]]
    ) throws(CajuRHIError) {
        guard case .resource(let r) = t else { return }
        guard r.index >= 0, r.index < n else { throw .invalidFrameGraph(.unknownResource(index: r.index)) }
        if case .load = load { reads[p].append(r.index) }
        writes[p].append(r.index)
    }

    /// Recursos usados em attachments cujo resultado não persiste (clear/dontCare + store dontCare/resolve).
    private static func attachmentUsage(_ pass: CajuFrameGraphPass) -> (nonPersisting: Set<Int>, Void) {
        var set = Set<Int>()
        guard let render = pass.render else { return (set, ()) }
        func consider(_ t: CajuAttachmentTexture, _ load: CajuLoadAction, _ store: CajuStoreAction) {
            guard case .resource(let r) = t else { return }
            if case .load = load { return }
            switch store {
            case .dontCare, .resolve: set.insert(r.index)
            case .store, .storeAndResolve: break
            }
        }
        for c in render.colorAttachments { consider(c.texture, c.load, c.store) }
        if let d = render.depthAttachment { consider(d.texture, d.load, d.store) }
        return (set, ())
    }

    private init(
        resources: [CajuFrameGraphResourceKind], livePasses: [LivePass], plan: [CajuResourcePlan],
        firstUse: [Int], lastUse: [Int], stats: CajuFrameGraphStats,
        effectiveDescriptors: [CajuTextureDescriptor?]
    ) {
        self.resources = resources
        self.livePasses = livePasses
        self.plan = plan
        self.firstUse = firstUse
        self.lastUse = lastUse
        self.stats = stats
        self.effectiveDescriptors = effectiveDescriptors
    }
}

// MARK: - Execução

/// Executa um grafo compilado num command buffer. Reutilize a mesma instância entre quadros: depois de
/// `prepare` (na compilação), `execute` não aloca memória no estado estável.
public struct CajuFrameGraphExecutor {
    private var handles: [CajuTextureHandle] = []
    private var resolvedPasses: [CajuRenderPassDescriptor?] = []
    private var preparedResourceCount = -1
    private var preparedPassCount = -1

    public init() {}

    /// Dimensiona os buffers internos para o grafo; chame de novo quando o grafo for recompilado.
    public mutating func prepare(_ graph: CajuCompiledFrameGraph) {
        handles = [CajuTextureHandle](repeating: .null, count: graph.resources.count)
        resolvedPasses = graph.livePasses.map { $0.pass.render }
        preparedResourceCount = graph.resources.count
        preparedPassCount = graph.livePasses.count
    }

    /// Liga um recurso importado à textura real do quadro (ex.: imagem do *swapchain*).
    public mutating func bind(_ resource: CajuFrameGraphResource, to texture: CajuTextureHandle) {
        guard resource.index >= 0, resource.index < handles.count else { return }
        handles[resource.index] = texture
    }

    /// Grava todos os passes vivos. `render` recebe o encoder de cada passe de render (o id diz qual).
    public mutating func execute<Device: CajuRenderDevice>(
        _ graph: CajuCompiledFrameGraph,
        device: Device,
        commandBuffer: inout Device.Queue.CommandBuffer,
        render: (CajuFrameGraphPassID, inout Device.Queue.CommandBuffer.RenderEncoder) -> Void,
        compute: (CajuFrameGraphPassID, inout Device.Queue.CommandBuffer.ComputeEncoder) -> Void = { _, _ in
        },
        copy: (CajuFrameGraphPassID, inout Device.Queue.CommandBuffer.CopyEncoder) -> Void = { _, _ in }
    ) throws(CajuRHIError) {
        guard preparedResourceCount == graph.resources.count, preparedPassCount == graph.livePasses.count
        else { throw .invalidFrameGraph(.invalidPass(pass: -1)) }

        // Texturas transitórias com memória: um handle por slot (compartilhado via aliasing no device).
        for i in 0..<graph.resources.count {
            switch graph.plan[i] {
            case .aliased(let slot):
                guard let d = graph.effectiveDescriptors[i] else { continue }
                handles[i] = try device.transientTexture(d, slot: slot)
            case .memoryless:
                guard let d = graph.effectiveDescriptors[i] else { continue }
                handles[i] = try device.transientTexture(d, slot: -1 - i)
            case .imported, .unused: break
            }
        }

        for (position, live) in graph.livePasses.enumerated() {
            switch live.pass.kind {
            case .render:
                // Retira o descritor do array para que seja referenciado só por esta variável: a
                // reescrita abaixo é no lugar (copy-on-write não copia nem aloca).
                guard var descriptor = resolvedPasses[position], let template = live.pass.render else {
                    throw .invalidFrameGraph(.invalidPass(pass: live.id.index))
                }
                resolvedPasses[position] = nil
                // Reescreve os handles no lugar (sem alocar): o descritor resolvido é de uso exclusivo.
                for j in 0..<template.colorAttachments.count {
                    descriptor.colorAttachments[j].texture = resolve(template.colorAttachments[j].texture)
                    if let r = template.colorAttachments[j].resolveTexture {
                        descriptor.colorAttachments[j].resolveTexture = resolve(r)
                    }
                }
                if let d = template.depthAttachment {
                    descriptor.depthAttachment?.texture = resolve(d.texture)
                }
                resolvedPasses[position] = descriptor
                try commandBuffer.withRenderPass(descriptor) { encoder in render(live.id, &encoder) }
            case .compute:
                try commandBuffer.withComputePass(label: live.pass.name) { encoder in
                    compute(live.id, &encoder)
                }
            case .copy:
                try commandBuffer.withCopyPass(label: live.pass.name) { encoder in
                    copy(live.id, &encoder)
                }
            }
        }
    }

    private func resolve(_ t: CajuAttachmentTexture) -> CajuAttachmentTexture {
        guard case .resource(let r) = t, r.index >= 0, r.index < handles.count else { return t }
        return .texture(handles[r.index])
    }
}
