/// Estágios fixos de um quadro, na ordem de execução.
public enum CajuStage: Int, Sendable, CaseIterable {
    case first, fixedUpdate, preUpdate, update, postUpdate, last
}

/// Violação de acesso: sistema usou componente que não declarou.
public struct CajuAccessError: Error, Equatable, Sendable {
    public let component: CajuComponentID
    public let isWrite: Bool
    @inlinable public init(_ component: CajuComponentID, isWrite: Bool) {
        self.component = component
        self.isWrite = isWrite
    }
}

public enum CajuSchedulerError: Error, Equatable, Sendable {
    case duplicateSystemName(String)
    case unknownDependency(system: String, after: String)
    /// Dependências explícitas formam um ciclo (envolve os sistemas listados).
    case dependencyCycle([String])
    /// `after` aponta para sistema de outro estágio.
    case crossStageDependency(system: String, after: String)
    case accessViolation(system: String, component: CajuComponentID, isWrite: Bool)
    case notBuilt
    case alreadyBuilt
}

/// Visão do mundo entregue a um sistema: toda consulta é validada contra o acesso declarado.
public struct CajuSystemContext {
    @usableFromInline let world: CajuWorld
    @usableFromInline let reads: CajuComponentMask
    @usableFromInline let writes: CajuComponentMask
    public let time: CajuTime
    public let commands: CajuCommandBuffer

    // As consultas validadas `forEach` (aridade 1..8) ficam em `CajuQueryArity.swift` (gerado).

    @inlinable
    public func get<C: CajuComponent>(_ type: C.Type, of entity: CajuEntity) throws(CajuAccessError) -> C? {
        guard reads.contains(C.componentID) || writes.contains(C.componentID) else {
            throw CajuAccessError(C.componentID, isWrite: false)
        }
        return world.get(type, of: entity)
    }

    @inlinable @discardableResult
    public func set<C: CajuComponent>(_ value: C, on entity: CajuEntity) throws(CajuAccessError) -> Bool {
        guard writes.contains(C.componentID) else {
            throw CajuAccessError(C.componentID, isWrite: true)
        }
        return world.set(value, on: entity)
    }

    @inlinable func check(reads r: CajuComponentMask, writes w: CajuComponentMask) throws(CajuAccessError) {
        let declared = reads.union(writes)
        if !writes.isSuperset(of: w) {
            throw CajuAccessError(firstMissing(w, in: writes), isWrite: true)
        }
        if !declared.isSuperset(of: r) {
            throw CajuAccessError(firstMissing(r, in: declared), isWrite: false)
        }
    }

    @usableFromInline func firstMissing(_ wanted: CajuComponentMask, in have: CajuComponentMask)
        -> CajuComponentID
    {
        let missing = wanted.bits & ~have.bits
        return CajuComponentID(UInt8(truncatingIfNeeded: missing.trailingZeroBitCount))
    }
}

/// Descrição de um sistema: estágio, acesso declarado e dependências explícitas.
public struct CajuSystemDescriptor {
    public var name: String
    public var stage: CajuStage
    public var reads: CajuComponentMask
    public var writes: CajuComponentMask
    /// Nomes de sistemas do mesmo estágio que devem rodar antes deste.
    public var after: [String]
    public var run: (inout CajuSystemContext) throws(CajuAccessError) -> Void

    public init(
        name: String, stage: CajuStage = .update, reads: CajuComponentMask = .none,
        writes: CajuComponentMask = .none, after: [String] = [],
        run: @escaping (inout CajuSystemContext) throws(CajuAccessError) -> Void
    ) {
        self.name = name
        self.stage = stage
        self.reads = reads
        self.writes = writes
        self.after = after
        self.run = run
    }
}

/// Agendador single-thread (ADR 0003).
///
/// `build()` valida o grafo e ordena cada estágio: sistemas com conflito de acesso (escrita×escrita ou
/// escrita×leitura) mantêm a ordem de registro; `after` adiciona arestas explícitas. A ordem é
/// determinística (Kahn com prioridade de registro). `batches(of:)` expõe os níveis independentes,
/// que são a base de uma paralelização futura sem mudar a API.
public final class CajuScheduler {
    public let world: CajuWorld
    public let commands: CajuCommandBuffer
    private var systems: [CajuSystemDescriptor] = []
    private var order: [[Int]] = Array(repeating: [], count: CajuStage.allCases.count)
    private var levels: [[[Int]]] = Array(repeating: [], count: CajuStage.allCases.count)
    private var built = false
    private var fixed: CajuFixedTimestep
    public private(set) var time = CajuTime()

    public init(
        world: CajuWorld, commandCapacity: Int = 1024, fixedStep: Double = 1.0 / 60.0, maxFixedSteps: Int = 8
    ) {
        self.world = world
        self.commands = CajuCommandBuffer(capacity: commandCapacity)
        self.fixed = CajuFixedTimestep(step: fixedStep, maxSteps: maxFixedSteps)
    }

    public func add(_ system: CajuSystemDescriptor) throws(CajuSchedulerError) {
        guard !built else { throw .alreadyBuilt }
        guard !systems.contains(where: { $0.name == system.name }) else {
            throw .duplicateSystemName(system.name)
        }
        systems.append(system)
    }

    /// Valida nomes/dependências e calcula a ordem. Obrigatório antes de `tick`.
    public func build() throws(CajuSchedulerError) {
        guard !built else { throw .alreadyBuilt }
        for stage in CajuStage.allCases {
            let ids = systems.indices.filter { systems[$0].stage == stage }
            var preds: [Int: Set<Int>] = [:]
            for i in ids { preds[i] = [] }
            for (pos, j) in ids.enumerated() {
                for name in systems[j].after {
                    guard let dep = systems.firstIndex(where: { $0.name == name }) else {
                        throw .unknownDependency(system: systems[j].name, after: name)
                    }
                    guard systems[dep].stage == stage else {
                        throw .crossStageDependency(system: systems[j].name, after: name)
                    }
                    preds[j, default: []].insert(dep)
                }
                for i in ids[..<pos] where Self.conflict(systems[i], systems[j]) {
                    preds[j, default: []].insert(i)
                }
            }
            // Kahn por níveis; dentro do nível, ordem de registro.
            var remaining = Set(ids)
            var done = Set<Int>()
            var stageOrder: [Int] = []
            var stageLevels: [[Int]] = []
            while !remaining.isEmpty {
                let ready = ids.filter { remaining.contains($0) && (preds[$0] ?? []).isSubset(of: done) }
                if ready.isEmpty {
                    throw .dependencyCycle(ids.filter { remaining.contains($0) }.map { systems[$0].name })
                }
                stageLevels.append(ready)
                stageOrder.append(contentsOf: ready)
                for r in ready { remaining.remove(r) }
                done.formUnion(ready)
            }
            order[stage.rawValue] = stageOrder
            levels[stage.rawValue] = stageLevels
        }
        built = true
    }

    /// Níveis independentes (podem rodar em paralelo no futuro) do estágio, como nomes.
    public func batches(of stage: CajuStage) -> [[String]] {
        levels[stage.rawValue].map { $0.map { systems[$0].name } }
    }

    /// Nomes na ordem de execução do estágio.
    public func executionOrder(of stage: CajuStage) -> [String] {
        order[stage.rawValue].map { systems[$0].name }
    }

    static func conflict(_ a: CajuSystemDescriptor, _ b: CajuSystemDescriptor) -> Bool {
        a.writes.intersects(b.writes) || a.writes.intersects(b.reads) || a.reads.intersects(b.writes)
    }

    /// Roda um quadro com `delta` segundos: `first`, `fixedUpdate` (0..N passos), `preUpdate`,
    /// `update`, `postUpdate`, `last`; comandos aplicados após cada estágio/passo.
    public func tick(delta: Double) throws(CajuSchedulerError) {
        guard built else { throw .notBuilt }
        let d = (delta > 0 && delta.isFinite) ? delta : 0
        let steps = fixed.advance(by: d)
        time.delta = d
        try runStage(.first)
        time.delta = fixed.step
        for _ in 0..<steps { try runStage(.fixedUpdate) }
        time.delta = d
        try runStage(.preUpdate)
        try runStage(.update)
        try runStage(.postUpdate)
        try runStage(.last)
        time.elapsed += d
        time.frame += 1
    }

    private func runStage(_ stage: CajuStage) throws(CajuSchedulerError) {
        for i in order[stage.rawValue] {
            var ctx = CajuSystemContext(
                world: world, reads: systems[i].reads, writes: systems[i].writes, time: time,
                commands: commands)
            do {
                try systems[i].run(&ctx)
            } catch {
                throw .accessViolation(
                    system: systems[i].name, component: error.component, isWrite: error.isWrite)
            }
        }
        commands.apply(to: world)
    }
}
