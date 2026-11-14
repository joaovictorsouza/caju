import CajuMath

/// Handle estável e geracional para um proxy registrado em `CajuBVH`.
///
/// Handles removidos ou invalidados por `clear()`/`build(from:)` passam a ser rejeitados
/// com `CajuSpatialError.invalidHandle` mesmo que o slot interno seja reutilizado.
public struct CajuBVHProxy: Sendable, Equatable, Hashable {
    /// Índice do slot na tabela de proxies da BVH.
    public let index: UInt32
    /// Geração do slot para detecção de uso após remoção.
    public let generation: UInt32

    @inlinable
    internal init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }
}

/// Resultado de um *raycast* contra `CajuBVH`.
public struct CajuBVHRayHit: Sendable, Equatable {
    /// Handle do proxy atingido.
    public let proxy: CajuBVHProxy
    /// Dado associado ao proxy (`userData`).
    public let userData: UInt32
    /// Parâmetro `t` de entrada na AABB justa do proxy.
    public let t: Float

    /// Cria um resultado de *raycast* na BVH.
    @inlinable
    public init(proxy: CajuBVHProxy, userData: UInt32, t: Float) {
        self.proxy = proxy
        self.userData = userData
        self.t = t
    }
}

/// Resultado de um *swept AABB cast* contra `CajuBVH`.
public struct CajuBVHSweptHit: Sendable, Equatable {
    /// Handle do proxy atingido.
    public let proxy: CajuBVHProxy
    /// Dado associado ao proxy (`userData`).
    public let userData: UInt32
    /// Fração normalizada do deslocamento (`0...1`) no instante do primeiro contato.
    public let t: Float

    /// Cria um resultado de *swept cast* na BVH.
    @inlinable
    public init(proxy: CajuBVHProxy, userData: UInt32, t: Float) {
        self.proxy = proxy
        self.userData = userData
        self.t = t
    }
}

/// BVH dinâmica sobre AABBs com handles estáveis, AABBs gordas e balanceamento por rotações.
///
/// Os nós residem em array contíguo com *free list* e índices `Int32`. Consultas utilizam
/// `CajuBVHTraversalStack` reutilizável e *visitors* não-escapantes, sem alocações de *heap*
/// no caminho quente (até profundidade 64; acima disso a pilha cresce apenas se necessário).
///
/// ```swift
/// var bvh = try CajuBVH()
/// let proxy = try bvh.insert(bounds: CajuAABB(min: CajuVec3(0, 0, 0), max: CajuVec3(1, 1, 1)), userData: 7)
/// let ray = try CajuRayQuery(ray: CajuRay(origin: CajuVec3(0.5, 0.5, -5), direction: CajuVec3(0, 0, 1)))
/// let hit = bvh.raycastFirst(ray)
/// ```
public struct CajuBVH: Sendable {
    @usableFromInline
    internal static let nullNode: Int32 = -1
    @usableFromInline
    internal static let sahBinCount = 16
    @usableFromInline
    internal static let displacementMultiplier: Float = 2.0
    @usableFromInline
    internal static let absoluteMaxCapacity: Int = Int(Int32.max / 2)

    @usableFromInline
    internal struct Node: Sendable {
        @usableFromInline var bounds: CajuAABB
        @usableFromInline var parent: Int32
        @usableFromInline var left: Int32
        @usableFromInline var right: Int32
        @usableFromInline var height: Int32
        @usableFromInline var proxyIndex: Int32

        @inlinable
        var isLeaf: Bool { left == CajuBVH.nullNode }
    }

    @usableFromInline
    internal struct ProxyEntry: Sendable {
        @usableFromInline var tightBounds: CajuAABB
        @usableFromInline var userData: UInt32
        @usableFromInline var generation: UInt32
        @usableFromInline var nodeIndex: Int32
        @usableFromInline var nextFree: Int32
    }

    @usableFromInline
    internal struct SAHBin: Sendable {
        var bounds: CajuAABB
        var count: Int = 0
        var occupied: Bool = false

        init() {
            bounds = CajuAABB(min: .zero, max: .zero)
        }
    }

    @usableFromInline internal var nodes: [Node] = []
    @usableFromInline internal var proxies: [ProxyEntry] = []
    @usableFromInline internal var root: Int32 = CajuBVH.nullNode
    @usableFromInline internal var nodeFreeHead: Int32 = CajuBVH.nullNode
    @usableFromInline internal var proxyFreeHead: Int32 = CajuBVH.nullNode

    /// Margem aplicada às AABBs gordas das folhas para absorver pequenos movimentos sem reinserção.
    public let fatMargin: Float

    /// Capacidade máxima de proxies ativos permitida nesta instância.
    public let maxCapacity: Int

    /// Quantidade atual de proxies ativos na BVH.
    public private(set) var count: Int = 0

    /// Indica se a BVH está vazia.
    @inlinable
    public var isEmpty: Bool { count == 0 }

    /// AABB da raiz da árvore (incluindo margem gorda), ou `nil` se a árvore estiver vazia.
    @inlinable
    public var bounds: CajuAABB? {
        root == Self.nullNode ? nil : nodes[Int(root)].bounds
    }

    /// Cria uma BVH dinâmica vazia.
    ///
    /// - Parameters:
    ///   - fatMargin: Margem positiva (ou zero) das AABBs gordas nas folhas.
    ///   - maxCapacity: Limite opcional de proxies ativos (padrão: limite seguro para índices `Int32`).
    /// - Throws: `CajuSpatialError.nonFiniteInput`, `.invalidRadius` ou `.capacityExceeded`.
    public init(fatMargin: Float = 0.05, maxCapacity: Int? = nil) throws(CajuSpatialError) {
        guard fatMargin.isFinite else {
            throw .nonFiniteInput
        }
        guard fatMargin >= 0 else {
            throw .invalidRadius
        }
        let resolvedCapacity = maxCapacity ?? Self.absoluteMaxCapacity
        guard resolvedCapacity >= 0, resolvedCapacity <= Self.absoluteMaxCapacity else {
            throw .capacityExceeded
        }
        self.fatMargin = fatMargin
        self.maxCapacity = resolvedCapacity
    }

    /// Constrói a árvore em lote via SAH *binned* (16 *bins*), substituindo o conteúdo anterior.
    ///
    /// Todos os handles anteriores são invalidados.
    ///
    /// - Parameter entries: Lista de pares `(bounds, userData)`.
    /// - Returns: Array de handles estáveis na mesma ordem de `entries`.
    /// - Throws: `CajuSpatialError.capacityExceeded` se `entries.count > maxCapacity`;
    ///   `CajuSpatialError.nonFiniteBounds` ou `.invalidBounds` se alguma AABB for inválida.
    public mutating func build(
        from entries: [(bounds: CajuAABB, userData: UInt32)]
    ) throws(CajuSpatialError) -> [CajuBVHProxy] {
        guard entries.count <= maxCapacity else {
            throw .capacityExceeded
        }
        for entry in entries {
            try validateAABB(entry.bounds)
        }

        clear()
        guard !entries.isEmpty else {
            return []
        }

        let n = entries.count
        var result: [CajuBVHProxy] = []
        result.reserveCapacity(n)

        var leafNodes: [Int32] = []
        leafNodes.reserveCapacity(n)
        nodes.reserveCapacity(Swift.max(nodes.capacity, 2 * n - 1))

        for entry in entries {
            let proxyIdx = allocateProxySlot(tightBounds: entry.bounds, userData: entry.userData)
            let fatBounds = aabbEnlargedClamped(entry.bounds, margin: fatMargin)
            let leafIdx = allocateNode(
                bounds: fatBounds,
                parent: Self.nullNode,
                left: Self.nullNode,
                right: Self.nullNode,
                height: 0,
                proxyIndex: proxyIdx
            )
            proxies[Int(proxyIdx)].nodeIndex = leafIdx
            leafNodes.append(leafIdx)
            let gen = proxies[Int(proxyIdx)].generation
            result.append(CajuBVHProxy(index: UInt32(proxyIdx), generation: gen))
        }

        count = n
        var bins = [SAHBin](repeating: SAHBin(), count: Self.sahBinCount)
        var leftBounds = [CajuAABB](
            repeating: CajuAABB(min: .zero, max: .zero),
            count: Self.sahBinCount - 1
        )
        var leftCounts = [Int](repeating: 0, count: Self.sahBinCount - 1)

        root = buildSAH(
            start: 0,
            end: n,
            leafNodes: &leafNodes,
            bins: &bins,
            leftBounds: &leftBounds,
            leftCounts: &leftCounts
        )
        nodes[Int(root)].parent = Self.nullNode
        return result
    }

    /// Insere um novo elemento na BVH de forma incremental (custo por área + rotações AVL).
    ///
    /// - Throws: `CajuSpatialError.capacityExceeded` se atingir `maxCapacity`;
    ///   `CajuSpatialError.nonFiniteBounds` ou `.invalidBounds` se `bounds` for inválida.
    public mutating func insert(
        bounds: CajuAABB,
        userData: UInt32 = 0
    ) throws(CajuSpatialError) -> CajuBVHProxy {
        try validateAABB(bounds)
        guard count < maxCapacity else {
            throw .capacityExceeded
        }

        let proxyIdx = allocateProxySlot(tightBounds: bounds, userData: userData)
        let fatBounds = aabbEnlargedClamped(bounds, margin: fatMargin)
        let leafIdx = allocateNode(
            bounds: fatBounds,
            parent: Self.nullNode,
            left: Self.nullNode,
            right: Self.nullNode,
            height: 0,
            proxyIndex: proxyIdx
        )
        proxies[Int(proxyIdx)].nodeIndex = leafIdx
        insertLeaf(leafIdx)
        count += 1
        return CajuBVHProxy(index: UInt32(proxyIdx), generation: proxies[Int(proxyIdx)].generation)
    }

    /// Remove um proxy existente da BVH, devolvendo seus slots para as *free lists*.
    ///
    /// - Throws: `CajuSpatialError.invalidHandle` se o handle for inválido ou já tiver sido removido.
    public mutating func remove(_ proxy: CajuBVHProxy) throws(CajuSpatialError) {
        let proxyIdx = try validatedProxyIndex(proxy)
        let leafIdx = proxies[proxyIdx].nodeIndex
        removeLeaf(leafIdx)
        freeNode(leafIdx)
        freeProxySlot(Int32(proxyIdx))
        count -= 1
    }

    /// Atualiza a AABB de um proxy existente.
    ///
    /// Só remove e reinsere a folha na árvore se a nova `bounds` escapar da AABB gorda atual;
    /// caso contrário atualiza apenas `tightBounds` em $O(1)$.
    ///
    /// - Parameters:
    ///   - proxy: Handle válido do proxy.
    ///   - bounds: Nova AABB justa.
    ///   - displacement: Deslocamento recente opcional para expandir a AABB gorda na direção do movimento.
    /// - Returns: `true` se a folha precisou ser reinserida na árvore; `false` se permaneceu dentro da AABB gorda.
    /// - Throws: `CajuSpatialError.invalidHandle`, `.nonFiniteBounds`, `.invalidBounds` ou `.nonFiniteInput`.
    @discardableResult
    public mutating func update(
        _ proxy: CajuBVHProxy,
        bounds: CajuAABB,
        displacement: SIMD3<Float> = .zero
    ) throws(CajuSpatialError) -> Bool {
        try validateAABB(bounds)
        guard allFinite(displacement) else {
            throw .nonFiniteInput
        }
        let proxyIdx = try validatedProxyIndex(proxy)
        let leafIdx = proxies[proxyIdx].nodeIndex
        proxies[proxyIdx].tightBounds = bounds

        if aabbContains(nodes[Int(leafIdx)].bounds, bounds) {
            return false
        }

        removeLeaf(leafIdx)
        let predictedDisplacement = displacement * Self.displacementMultiplier
        nodes[Int(leafIdx)].bounds = aabbEnlargedClamped(
            bounds,
            margin: fatMargin,
            displacement: predictedDisplacement
        )
        insertLeaf(leafIdx)
        return true
    }

    /// Atualiza todas as AABBs da árvore *bottom-up* a partir das `tightBounds` atuais sem alterar a topologia.
    ///
    /// Útil para ajustar folgas de AABBs gordas inchadas por deslocamentos grandes ou após atualizações em massa.
    public mutating func refit() {
        guard root != Self.nullNode else { return }
        var stack = CajuBVHTraversalStack()
        stack.push(root, tNear: 0)

        while let (nodeIdx, state) = stack.pop() {
            let i = Int(nodeIdx)
            if nodes[i].isLeaf {
                let pIdx = Int(nodes[i].proxyIndex)
                nodes[i].bounds = aabbEnlargedClamped(proxies[pIdx].tightBounds, margin: fatMargin)
            } else if state == 0 {
                stack.push(nodeIdx, tNear: 1)
                stack.push(nodes[i].right, tNear: 0)
                stack.push(nodes[i].left, tNear: 0)
            } else {
                let l = Int(nodes[i].left)
                let r = Int(nodes[i].right)
                nodes[i].bounds = nodes[l].bounds.union(nodes[r].bounds)
                nodes[i].height = 1 + Swift.max(nodes[l].height, nodes[r].height)
            }
        }
    }

    /// Remove todos os proxies e nós ativos, invalidando handles antigos e preservando capacidade alocada.
    public mutating func clear() {
        for idx in proxies.indices where proxies[idx].nodeIndex != Self.nullNode {
            proxies[idx].nodeIndex = Self.nullNode
            proxies[idx].generation = nextGeneration(proxies[idx].generation)
            proxies[idx].nextFree = proxyFreeHead
            proxyFreeHead = Int32(idx)
        }
        nodes.removeAll(keepingCapacity: true)
        nodeFreeHead = Self.nullNode
        root = Self.nullNode
        count = 0
    }

    /// Indica se `proxy` ainda é válido e ativo nesta BVH.
    @inlinable
    public func isValid(_ proxy: CajuBVHProxy) -> Bool {
        guard let idx = Int(exactly: proxy.index), idx >= 0, idx < proxies.count else {
            return false
        }
        let entry = proxies[idx]
        return entry.nodeIndex != Self.nullNode && entry.generation == proxy.generation
    }

    /// Retorna a AABB justa atual do proxy.
    ///
    /// - Throws: `CajuSpatialError.invalidHandle` se o handle for inválido ou removido.
    @inlinable
    public func bounds(for proxy: CajuBVHProxy) throws(CajuSpatialError) -> CajuAABB {
        let idx = try validatedProxyIndex(proxy)
        return proxies[idx].tightBounds
    }

    /// Retorna o `userData` associado ao proxy.
    ///
    /// - Throws: `CajuSpatialError.invalidHandle` se o handle for inválido ou removido.
    @inlinable
    public func userData(for proxy: CajuBVHProxy) throws(CajuSpatialError) -> UInt32 {
        let idx = try validatedProxyIndex(proxy)
        return proxies[idx].userData
    }

    // MARK: - Consultas

    /// Retorna o primeiro impacto ao longo de `ray` (menor `t` em `[ray.tMin, ray.tMax]`), ou `nil`.
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    @inlinable
    public func raycastFirst(_ ray: CajuRayQuery, stack: inout CajuBVHTraversalStack) -> CajuBVHRayHit? {
        stack.reset()
        defer { stack.reset() }
        guard root != Self.nullNode else { return nil }
        guard
            let rootT = ray.intersectSlabs(
                nodes[Int(root)].bounds,
                tEnterInit: ray.tMin,
                tExitInit: ray.tMax,
                exitSlack: 0
            )
        else { return nil }

        var bestT = ray.tMax
        var bestHit: CajuBVHRayHit?
        stack.push(root, tNear: rootT)

        while let (nodeIdx, tNear) = stack.pop() {
            if bestHit != nil ? (tNear > bestT) : (tNear > ray.tMax) {
                continue
            }
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let pIdx = Int(node.proxyIndex)
                let entry = proxies[pIdx]
                if let t = ray.intersectSlabs(
                    entry.tightBounds,
                    tEnterInit: ray.tMin,
                    tExitInit: bestT,
                    exitSlack: 0
                ) {
                    if bestHit == nil || t < bestT {
                        bestT = t
                        bestHit = CajuBVHRayHit(
                            proxy: CajuBVHProxy(index: UInt32(pIdx), generation: entry.generation),
                            userData: entry.userData,
                            t: t
                        )
                    }
                }
            } else {
                let left = node.left
                let right = node.right
                let tLeft = ray.intersectSlabs(
                    nodes[Int(left)].bounds,
                    tEnterInit: ray.tMin,
                    tExitInit: bestT,
                    exitSlack: 0
                )
                let tRight = ray.intersectSlabs(
                    nodes[Int(right)].bounds,
                    tEnterInit: ray.tMin,
                    tExitInit: bestT,
                    exitSlack: 0
                )

                switch (tLeft, tRight) {
                case (let .some(tl), let .some(tr)):
                    if tl <= tr {
                        stack.push(right, tNear: tr)
                        stack.push(left, tNear: tl)
                    } else {
                        stack.push(left, tNear: tl)
                        stack.push(right, tNear: tr)
                    }
                case (let .some(tl), .none):
                    stack.push(left, tNear: tl)
                case (.none, let .some(tr)):
                    stack.push(right, tNear: tr)
                case (.none, .none):
                    break
                }
            }
        }
        return bestHit
    }

    /// Conveniência de `raycastFirst` sem pilha explícita.
    ///
    /// - Important: Aloca uma `CajuBVHTraversalStack` local a cada chamada (alocando em *heap*
    ///   se a profundidade ultrapassar 64 níveis). No caminho quente, use ``raycastFirst(_:stack:)``.
    @inlinable
    public func raycastFirst(_ ray: CajuRayQuery) -> CajuBVHRayHit? {
        var stack = CajuBVHTraversalStack()
        return raycastFirst(ray, stack: &stack)
    }

    /// Visita todas as AABBs atingidas por `ray` (em ordem não especificada).
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    /// O *visitor* retorna `true` para continuar a travessia ou `false` para interromper imediatamente.
    @inlinable
    public func raycastAll(
        _ ray: CajuRayQuery,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuBVHRayHit) -> Bool
    ) {
        stack.reset()
        defer { stack.reset() }
        guard root != Self.nullNode else { return }
        guard
            ray.intersectSlabs(
                nodes[Int(root)].bounds,
                tEnterInit: ray.tMin,
                tExitInit: ray.tMax,
                exitSlack: 0
            ) != nil
        else { return }

        stack.push(root)
        while let (nodeIdx, _) = stack.pop() {
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let pIdx = Int(node.proxyIndex)
                let entry = proxies[pIdx]
                if let t = ray.intersectSlabs(
                    entry.tightBounds,
                    tEnterInit: ray.tMin,
                    tExitInit: ray.tMax,
                    exitSlack: 0
                ) {
                    let hit = CajuBVHRayHit(
                        proxy: CajuBVHProxy(index: UInt32(pIdx), generation: entry.generation),
                        userData: entry.userData,
                        t: t
                    )
                    if !visitor(hit) { return }
                }
            } else {
                if ray.intersectSlabs(
                    nodes[Int(node.left)].bounds,
                    tEnterInit: ray.tMin,
                    tExitInit: ray.tMax,
                    exitSlack: 0
                ) != nil {
                    stack.push(node.left)
                }
                if ray.intersectSlabs(
                    nodes[Int(node.right)].bounds,
                    tEnterInit: ray.tMin,
                    tExitInit: ray.tMax,
                    exitSlack: 0
                ) != nil {
                    stack.push(node.right)
                }
            }
        }
    }

    /// Conveniência de `raycastAll` sem pilha explícita.
    ///
    /// - Important: Aloca uma `CajuBVHTraversalStack` local a cada chamada (alocando em *heap*
    ///   se a profundidade ultrapassar 64 níveis). No caminho quente, use ``raycastAll(_:stack:visitor:)``.
    @inlinable
    public func raycastAll(_ ray: CajuRayQuery, visitor: (CajuBVHRayHit) -> Bool) {
        var stack = CajuBVHTraversalStack()
        raycastAll(ray, stack: &stack, visitor: visitor)
    }

    /// Acrescenta todos os hits do raio em `results` (sem limpar o array antes).
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` e a capacidade de `results`
    /// sem alocações por consulta.
    @inlinable
    public func raycastAll(
        _ ray: CajuRayQuery,
        into results: inout [CajuBVHRayHit],
        stack: inout CajuBVHTraversalStack
    ) {
        raycastAll(ray, stack: &stack) { hit in
            results.append(hit)
            return true
        }
    }

    /// Visita todos os proxies cuja AABB justa sobrepõe `aabb`.
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    /// O *visitor* retorna `true` para continuar ou `false` para interromper.
    ///
    /// - Throws: `CajuSpatialError.nonFiniteBounds` ou `.invalidBounds` se `aabb` for inválida.
    @inlinable
    public func query(
        overlapping aabb: CajuAABB,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuBVHProxy, UInt32) -> Bool
    ) throws(CajuSpatialError) {
        try validateAABB(aabb)

        stack.reset()
        defer { stack.reset() }
        guard root != Self.nullNode else { return }
        guard nodes[Int(root)].bounds.intersects(aabb) else { return }

        stack.push(root)
        while let (nodeIdx, _) = stack.pop() {
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let pIdx = Int(node.proxyIndex)
                let entry = proxies[pIdx]
                if entry.tightBounds.intersects(aabb) {
                    let proxy = CajuBVHProxy(index: UInt32(pIdx), generation: entry.generation)
                    if !visitor(proxy, entry.userData) { return }
                }
            } else {
                if nodes[Int(node.left)].bounds.intersects(aabb) {
                    stack.push(node.left)
                }
                if nodes[Int(node.right)].bounds.intersects(aabb) {
                    stack.push(node.right)
                }
            }
        }
    }

    /// Conveniência de `query(overlapping:)` sem pilha explícita.
    ///
    /// - Important: Aloca uma `CajuBVHTraversalStack` local a cada chamada (alocando em *heap*
    ///   se a profundidade ultrapassar 64 níveis). No caminho quente, use
    ///   ``query(overlapping:stack:visitor:)``.
    /// - Throws: `CajuSpatialError.nonFiniteBounds` ou `.invalidBounds` se `aabb` for inválida.
    @inlinable
    public func query(
        overlapping aabb: CajuAABB,
        visitor: (CajuBVHProxy, UInt32) -> Bool
    ) throws(CajuSpatialError) {
        var stack = CajuBVHTraversalStack()
        try query(overlapping: aabb, stack: &stack, visitor: visitor)
    }

    /// Acrescenta em `results` os proxies cuja AABB justa sobrepõe `aabb`.
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` e a capacidade de `results`
    /// sem alocações por consulta.
    ///
    /// - Throws: `CajuSpatialError.nonFiniteBounds` ou `.invalidBounds` se `aabb` for inválida.
    @inlinable
    public func query(
        overlapping aabb: CajuAABB,
        into results: inout [CajuBVHProxy],
        stack: inout CajuBVHTraversalStack
    ) throws(CajuSpatialError) {
        try query(overlapping: aabb, stack: &stack) { proxy, _ in
            results.append(proxy)
            return true
        }
    }

    /// Consulta de *shapecast* por esfera `CajuSphere` sobre as AABBs justas dos proxies.
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    ///
    /// - Throws: `CajuSpatialError.nonFiniteInput` se `sphere.center` ou `sphere.radius` não forem finitos;
    ///   `CajuSpatialError.invalidRadius` se `sphere.radius < 0`.
    @inlinable
    public func shapecast(
        sphere: CajuSphere,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuBVHProxy, UInt32) -> Bool
    ) throws(CajuSpatialError) {
        try validateSphere(sphere)
        let center = sphere.center.storage
        let radius = sphere.radius

        stack.reset()
        defer { stack.reset() }
        guard root != Self.nullNode else { return }
        guard aabbOverlapsSphere(nodes[Int(root)].bounds, center: center, radius: radius) else { return }

        stack.push(root)
        while let (nodeIdx, _) = stack.pop() {
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let pIdx = Int(node.proxyIndex)
                let entry = proxies[pIdx]
                if aabbOverlapsSphere(entry.tightBounds, center: center, radius: radius) {
                    let proxy = CajuBVHProxy(index: UInt32(pIdx), generation: entry.generation)
                    if !visitor(proxy, entry.userData) { return }
                }
            } else {
                if aabbOverlapsSphere(nodes[Int(node.left)].bounds, center: center, radius: radius) {
                    stack.push(node.left)
                }
                if aabbOverlapsSphere(nodes[Int(node.right)].bounds, center: center, radius: radius) {
                    stack.push(node.right)
                }
            }
        }
    }

    /// Conveniência de *shapecast* por esfera sem pilha explícita.
    ///
    /// - Important: Aloca uma `CajuBVHTraversalStack` local a cada chamada (alocando em *heap*
    ///   se a profundidade ultrapassar 64 níveis). No caminho quente, use
    ///   ``shapecast(sphere:stack:visitor:)``.
    @inlinable
    public func shapecast(
        sphere: CajuSphere,
        visitor: (CajuBVHProxy, UInt32) -> Bool
    ) throws(CajuSpatialError) {
        var stack = CajuBVHTraversalStack()
        try shapecast(sphere: sphere, stack: &stack, visitor: visitor)
    }

    /// Consulta de *shapecast* por AABB varrida (*swept AABB*): testa `aabb` movendo-se
    /// linearmente por `displacement` (`t` em `0...1`) contra as AABBs justas da BVH.
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    ///
    /// - Throws: `CajuSpatialError.nonFiniteBounds` ou `.invalidBounds` se `aabb` for inválida;
    ///   `CajuSpatialError.nonFiniteInput` se `displacement` não for finito.
    @inlinable
    public func shapecast(
        swept aabb: CajuAABB,
        displacement: SIMD3<Float>,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuBVHSweptHit) -> Bool
    ) throws(CajuSpatialError) {
        try validateAABB(aabb)
        guard allFinite(displacement) else {
            throw .nonFiniteInput
        }
        if displacement == .zero {
            try query(overlapping: aabb, stack: &stack) { proxy, userData in
                visitor(CajuBVHSweptHit(proxy: proxy, userData: userData, t: 0))
            }
            return
        }

        let ray = try CajuRayQuery(origin: .zero, direction: displacement, tMin: 0, tMax: 1)

        stack.reset()
        defer { stack.reset() }
        guard root != Self.nullNode else { return }
        guard
            ray.intersectSlabs(
                minkowskiExpand(nodes[Int(root)].bounds, by: aabb),
                tEnterInit: 0,
                tExitInit: 1,
                exitSlack: 0
            ) != nil
        else { return }

        stack.push(root)
        while let (nodeIdx, _) = stack.pop() {
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let pIdx = Int(node.proxyIndex)
                let entry = proxies[pIdx]
                if let t = ray.intersectSlabs(
                    minkowskiExpand(entry.tightBounds, by: aabb),
                    tEnterInit: 0,
                    tExitInit: 1,
                    exitSlack: 0
                ) {
                    let hit = CajuBVHSweptHit(
                        proxy: CajuBVHProxy(index: UInt32(pIdx), generation: entry.generation),
                        userData: entry.userData,
                        t: t
                    )
                    if !visitor(hit) { return }
                }
            } else {
                if ray.intersectSlabs(
                    minkowskiExpand(nodes[Int(node.left)].bounds, by: aabb),
                    tEnterInit: 0,
                    tExitInit: 1,
                    exitSlack: 0
                ) != nil {
                    stack.push(node.left)
                }
                if ray.intersectSlabs(
                    minkowskiExpand(nodes[Int(node.right)].bounds, by: aabb),
                    tEnterInit: 0,
                    tExitInit: 1,
                    exitSlack: 0
                ) != nil {
                    stack.push(node.right)
                }
            }
        }
    }

    /// Conveniência de *swept AABB cast* sem pilha explícita.
    ///
    /// - Important: Aloca uma `CajuBVHTraversalStack` local a cada chamada (alocando em *heap*
    ///   se a profundidade ultrapassar 64 níveis). No caminho quente, use
    ///   ``shapecast(swept:displacement:stack:visitor:)``.
    @inlinable
    public func shapecast(
        swept aabb: CajuAABB,
        displacement: SIMD3<Float>,
        visitor: (CajuBVHSweptHit) -> Bool
    ) throws(CajuSpatialError) {
        var stack = CajuBVHTraversalStack()
        try shapecast(swept: aabb, displacement: displacement, stack: &stack, visitor: visitor)
    }

    // MARK: - Validação de invariantes

    /// Verifica todos os invariantes estruturais da BVH.
    ///
    /// Checa: ausência de ciclos, ligação pai/filho, `height == 1 + max(left.height, right.height)`,
    /// `parent.bounds == left.bounds.union(right.bounds)`, contenção das `tightBounds` nas folhas,
    /// consistência das *free lists* e contagem exata de nós e proxies ativos.
    public func validate() -> Bool {
        var freeNodes = 0
        var freeCursor = nodeFreeHead
        while freeCursor != Self.nullNode {
            if freeNodes > nodes.count { return false }
            let idx = Int(freeCursor)
            if idx < 0 || idx >= nodes.count { return false }
            if nodes[idx].height != -1 { return false }
            freeNodes += 1
            freeCursor = nodes[idx].parent
        }

        var freeProxies = 0
        var freeProxyCursor = proxyFreeHead
        while freeProxyCursor != Self.nullNode {
            if freeProxies > proxies.count { return false }
            let idx = Int(freeProxyCursor)
            if idx < 0 || idx >= proxies.count { return false }
            if proxies[idx].nodeIndex != Self.nullNode { return false }
            freeProxies += 1
            freeProxyCursor = proxies[idx].nextFree
        }

        if root == Self.nullNode {
            return count == 0 && freeNodes == nodes.count && freeProxies == proxies.count
        }

        let rootIdx = Int(root)
        if rootIdx < 0 || rootIdx >= nodes.count { return false }
        if nodes[rootIdx].parent != Self.nullNode { return false }

        var visitedNodes = 0
        var visitedLeaves = 0
        var stack = CajuBVHTraversalStack()
        stack.push(root)

        while let (nodeIdx, _) = stack.pop() {
            visitedNodes += 1
            if visitedNodes > nodes.count { return false }

            let i = Int(nodeIdx)
            if i < 0 || i >= nodes.count { return false }
            let node = nodes[i]

            if node.isLeaf {
                if node.right != Self.nullNode || node.height != 0 { return false }
                let pIdx = Int(node.proxyIndex)
                if pIdx < 0 || pIdx >= proxies.count { return false }
                if proxies[pIdx].nodeIndex != nodeIdx { return false }
                if !isValidAABB(proxies[pIdx].tightBounds) || !isValidAABB(node.bounds) {
                    return false
                }
                if !aabbContains(node.bounds, proxies[pIdx].tightBounds) { return false }
                visitedLeaves += 1
            } else {
                let l = Int(node.left)
                let r = Int(node.right)
                if l < 0 || l >= nodes.count || r < 0 || r >= nodes.count || l == r { return false }
                if nodes[l].parent != nodeIdx || nodes[r].parent != nodeIdx { return false }
                if node.height != 1 + Swift.max(nodes[l].height, nodes[r].height) { return false }
                let expectedBounds = nodes[l].bounds.union(nodes[r].bounds)
                if node.bounds != expectedBounds { return false }
                if !aabbContains(node.bounds, nodes[l].bounds)
                    || !aabbContains(node.bounds, nodes[r].bounds)
                {
                    return false
                }
                stack.push(node.left)
                stack.push(node.right)
            }
        }

        return visitedLeaves == count
            && visitedNodes + freeNodes == nodes.count
            && count + freeProxies == proxies.count
    }

    // MARK: - Helpers internos

    @inlinable
    internal func minkowskiExpand(_ target: CajuAABB, by moving: CajuAABB) -> CajuAABB {
        let minP = clampToFinite(target.min.storage - moving.max.storage)
        let maxP = clampToFinite(target.max.storage - moving.min.storage)
        return CajuAABB(min: CajuVec3(storage: minP), max: CajuVec3(storage: maxP))
    }

    @inlinable
    internal func validatedProxyIndex(_ proxy: CajuBVHProxy) throws(CajuSpatialError) -> Int {
        guard let idx = Int(exactly: proxy.index), idx >= 0, idx < proxies.count else {
            throw .invalidHandle
        }
        let entry = proxies[idx]
        guard entry.nodeIndex != Self.nullNode, entry.generation == proxy.generation else {
            throw .invalidHandle
        }
        return idx
    }

    private func nextGeneration(_ current: UInt32) -> UInt32 {
        let next = current &+ 1
        return next == 0 ? 1 : next
    }

    private mutating func allocateProxySlot(tightBounds: CajuAABB, userData: UInt32) -> Int32 {
        if proxyFreeHead != Self.nullNode {
            let idx = proxyFreeHead
            let i = Int(idx)
            proxyFreeHead = proxies[i].nextFree
            proxies[i].tightBounds = tightBounds
            proxies[i].userData = userData
            proxies[i].nodeIndex = Self.nullNode
            proxies[i].nextFree = Self.nullNode
            return idx
        }
        let idx = Int32(proxies.count)
        proxies.append(
            ProxyEntry(
                tightBounds: tightBounds,
                userData: userData,
                generation: 1,
                nodeIndex: Self.nullNode,
                nextFree: Self.nullNode
            )
        )
        return idx
    }

    private mutating func freeProxySlot(_ proxyIdx: Int32) {
        let i = Int(proxyIdx)
        proxies[i].nodeIndex = Self.nullNode
        proxies[i].generation = nextGeneration(proxies[i].generation)
        proxies[i].nextFree = proxyFreeHead
        proxyFreeHead = proxyIdx
    }

    private mutating func allocateNode(
        bounds: CajuAABB,
        parent: Int32,
        left: Int32,
        right: Int32,
        height: Int32,
        proxyIndex: Int32
    ) -> Int32 {
        if nodeFreeHead != Self.nullNode {
            let idx = nodeFreeHead
            let i = Int(idx)
            nodeFreeHead = nodes[i].parent
            nodes[i] = Node(
                bounds: bounds,
                parent: parent,
                left: left,
                right: right,
                height: height,
                proxyIndex: proxyIndex
            )
            return idx
        }
        let idx = Int32(nodes.count)
        nodes.append(
            Node(
                bounds: bounds,
                parent: parent,
                left: left,
                right: right,
                height: height,
                proxyIndex: proxyIndex
            )
        )
        return idx
    }

    private mutating func freeNode(_ nodeIdx: Int32) {
        let i = Int(nodeIdx)
        nodes[i].parent = nodeFreeHead
        nodes[i].left = Self.nullNode
        nodes[i].right = Self.nullNode
        nodes[i].height = -1
        nodes[i].proxyIndex = Self.nullNode
        nodeFreeHead = nodeIdx
    }

    private mutating func buildSAH(
        start: Int,
        end: Int,
        leafNodes: inout [Int32],
        bins: inout [SAHBin],
        leftBounds: inout [CajuAABB],
        leftCounts: inout [Int]
    ) -> Int32 {
        let span = end - start
        if span == 1 {
            return leafNodes[start]
        }
        if span == 2 {
            let l = leafNodes[start]
            let r = leafNodes[start + 1]
            let parent = allocateNode(
                bounds: nodes[Int(l)].bounds.union(nodes[Int(r)].bounds),
                parent: Self.nullNode,
                left: l,
                right: r,
                height: 1,
                proxyIndex: Self.nullNode
            )
            nodes[Int(l)].parent = parent
            nodes[Int(r)].parent = parent
            return parent
        }

        var cMin = aabbCenter(nodes[Int(leafNodes[start])].bounds)
        var cMax = cMin
        for idx in (start + 1)..<end {
            let c = aabbCenter(nodes[Int(leafNodes[idx])].bounds)
            cMin = SIMD3<Float>(
                Swift.min(cMin.x, c.x),
                Swift.min(cMin.y, c.y),
                Swift.min(cMin.z, c.z)
            )
            cMax = SIMD3<Float>(
                Swift.max(cMax.x, c.x),
                Swift.max(cMax.y, c.y),
                Swift.max(cMax.z, c.z)
            )
        }

        var bestAxis = -1
        var bestSplitBin = -1
        var bestCost = Float.greatestFiniteMagnitude
        var bestAxisScale: Float = 0
        var bestAxisMin: Float = 0

        for axis in 0..<3 {
            let extent = cMax[axis] - cMin[axis]
            guard extent > 0, extent.isFinite else { continue }
            let scale = Float(Self.sahBinCount) / extent
            guard scale.isFinite, scale > 0 else { continue }

            for b in 0..<Self.sahBinCount {
                bins[b].count = 0
                bins[b].occupied = false
            }

            let minVal = cMin[axis]
            for idx in start..<end {
                let nodeIdx = Int(leafNodes[idx])
                let c = aabbCenter(nodes[nodeIdx].bounds)[axis]
                let rawBin = Int((c - minVal) * scale)
                let b = Swift.min(Self.sahBinCount - 1, Swift.max(0, rawBin))
                let nodeBounds = nodes[nodeIdx].bounds
                if bins[b].occupied {
                    bins[b].bounds = bins[b].bounds.union(nodeBounds)
                } else {
                    bins[b].bounds = nodeBounds
                    bins[b].occupied = true
                }
                bins[b].count += 1
            }

            // Varredura prefixa (esquerda -> direita)
            var accCount = 0
            var accOccupied = false
            var accBounds = CajuAABB(min: .zero, max: .zero)
            for i in 0..<(Self.sahBinCount - 1) {
                if bins[i].occupied {
                    accBounds = accOccupied ? accBounds.union(bins[i].bounds) : bins[i].bounds
                    accOccupied = true
                }
                accCount += bins[i].count
                leftCounts[i] = accCount
                leftBounds[i] = accBounds
            }

            // Varredura sufixa (direita -> esquerda) avaliando custo SAH
            var rightCount = 0
            var rightOccupied = false
            var rightBounds = CajuAABB(min: .zero, max: .zero)
            for i in stride(from: Self.sahBinCount - 1, through: 1, by: -1) {
                if bins[i].occupied {
                    rightBounds = rightOccupied ? rightBounds.union(bins[i].bounds) : bins[i].bounds
                    rightOccupied = true
                }
                rightCount += bins[i].count
                let leftCount = leftCounts[i - 1]
                if leftCount > 0 && rightCount > 0 {
                    let cost =
                        Float(leftCount) * aabbSurfaceArea(leftBounds[i - 1])
                        + Float(rightCount) * aabbSurfaceArea(rightBounds)
                    if cost < bestCost {
                        bestCost = cost
                        bestAxis = axis
                        bestSplitBin = i - 1
                        bestAxisScale = scale
                        bestAxisMin = minVal
                    }
                }
            }
        }

        var mid = start + span / 2
        if bestAxis != -1 {
            var left = start
            var right = end - 1
            while left <= right {
                let c = aabbCenter(nodes[Int(leafNodes[left])].bounds)[bestAxis]
                let b = Swift.min(
                    Self.sahBinCount - 1,
                    Swift.max(0, Int((c - bestAxisMin) * bestAxisScale))
                )
                if b <= bestSplitBin {
                    left += 1
                } else {
                    leafNodes.swapAt(left, right)
                    right -= 1
                }
            }
            if left > start && left < end {
                mid = left
            }
        }

        let leftChild = buildSAH(
            start: start,
            end: mid,
            leafNodes: &leafNodes,
            bins: &bins,
            leftBounds: &leftBounds,
            leftCounts: &leftCounts
        )
        let rightChild = buildSAH(
            start: mid,
            end: end,
            leafNodes: &leafNodes,
            bins: &bins,
            leftBounds: &leftBounds,
            leftCounts: &leftCounts
        )
        let h = 1 + Swift.max(nodes[Int(leftChild)].height, nodes[Int(rightChild)].height)
        let parent = allocateNode(
            bounds: nodes[Int(leftChild)].bounds.union(nodes[Int(rightChild)].bounds),
            parent: Self.nullNode,
            left: leftChild,
            right: rightChild,
            height: h,
            proxyIndex: Self.nullNode
        )
        nodes[Int(leftChild)].parent = parent
        nodes[Int(rightChild)].parent = parent
        return parent
    }

    private mutating func insertLeaf(_ leaf: Int32) {
        if root == Self.nullNode {
            root = leaf
            nodes[Int(leaf)].parent = Self.nullNode
            return
        }

        let leafAABB = nodes[Int(leaf)].bounds
        var index = root
        while !nodes[Int(index)].isLeaf {
            let child1 = nodes[Int(index)].left
            let child2 = nodes[Int(index)].right
            let area = aabbSurfaceArea(nodes[Int(index)].bounds)
            let combinedAABB = nodes[Int(index)].bounds.union(leafAABB)
            let combinedArea = aabbSurfaceArea(combinedAABB)

            let cost = 2.0 * combinedArea
            let inheritanceCost = 2.0 * (combinedArea - area)

            let cost1: Float
            if nodes[Int(child1)].isLeaf {
                cost1 = aabbSurfaceArea(leafAABB.union(nodes[Int(child1)].bounds)) + inheritanceCost
            } else {
                let oldArea = aabbSurfaceArea(nodes[Int(child1)].bounds)
                let newArea = aabbSurfaceArea(leafAABB.union(nodes[Int(child1)].bounds))
                cost1 = (newArea - oldArea) + inheritanceCost
            }

            let cost2: Float
            if nodes[Int(child2)].isLeaf {
                cost2 = aabbSurfaceArea(leafAABB.union(nodes[Int(child2)].bounds)) + inheritanceCost
            } else {
                let oldArea = aabbSurfaceArea(nodes[Int(child2)].bounds)
                let newArea = aabbSurfaceArea(leafAABB.union(nodes[Int(child2)].bounds))
                cost2 = (newArea - oldArea) + inheritanceCost
            }

            if cost < cost1 && cost < cost2 {
                break
            }
            index = cost1 < cost2 ? child1 : child2
        }

        let sibling = index
        let oldParent = nodes[Int(sibling)].parent
        let newParent = allocateNode(
            bounds: leafAABB.union(nodes[Int(sibling)].bounds),
            parent: oldParent,
            left: sibling,
            right: leaf,
            height: nodes[Int(sibling)].height + 1,
            proxyIndex: Self.nullNode
        )
        nodes[Int(sibling)].parent = newParent
        nodes[Int(leaf)].parent = newParent

        if oldParent != Self.nullNode {
            if nodes[Int(oldParent)].left == sibling {
                nodes[Int(oldParent)].left = newParent
            } else {
                nodes[Int(oldParent)].right = newParent
            }
        } else {
            root = newParent
        }

        fixUpwards(startingAt: newParent)
    }

    private mutating func removeLeaf(_ leaf: Int32) {
        if leaf == root {
            root = Self.nullNode
            return
        }

        let parent = nodes[Int(leaf)].parent
        let grandParent = nodes[Int(parent)].parent
        let sibling = nodes[Int(parent)].left == leaf ? nodes[Int(parent)].right : nodes[Int(parent)].left

        if grandParent != Self.nullNode {
            if nodes[Int(grandParent)].left == parent {
                nodes[Int(grandParent)].left = sibling
            } else {
                nodes[Int(grandParent)].right = sibling
            }
            nodes[Int(sibling)].parent = grandParent
            freeNode(parent)
            fixUpwards(startingAt: grandParent)
        } else {
            root = sibling
            nodes[Int(sibling)].parent = Self.nullNode
            freeNode(parent)
        }
    }

    private mutating func fixUpwards(startingAt startNode: Int32) {
        var index = startNode
        while index != Self.nullNode {
            index = balance(index)
            let child1 = nodes[Int(index)].left
            let child2 = nodes[Int(index)].right
            nodes[Int(index)].height = 1 + Swift.max(nodes[Int(child1)].height, nodes[Int(child2)].height)
            nodes[Int(index)].bounds = nodes[Int(child1)].bounds.union(nodes[Int(child2)].bounds)
            index = nodes[Int(index)].parent
        }
    }

    private mutating func balance(_ iA: Int32) -> Int32 {
        let a = Int(iA)
        if nodes[a].isLeaf || nodes[a].height < 2 {
            return iA
        }

        let iB = nodes[a].left
        let iC = nodes[a].right
        let b = Int(iB)
        let c = Int(iC)

        let balance = nodes[c].height - nodes[b].height

        // Rotação para a direita (sobe C)
        if balance > 1 {
            let iF = nodes[c].left
            let iG = nodes[c].right
            let f = Int(iF)
            let g = Int(iG)

            nodes[c].left = iA
            nodes[c].parent = nodes[a].parent
            nodes[a].parent = iC

            let cParent = nodes[c].parent
            if cParent != Self.nullNode {
                if nodes[Int(cParent)].left == iA {
                    nodes[Int(cParent)].left = iC
                } else {
                    nodes[Int(cParent)].right = iC
                }
            } else {
                root = iC
            }

            if nodes[f].height > nodes[g].height {
                nodes[c].right = iF
                nodes[a].right = iG
                nodes[g].parent = iA
                nodes[a].bounds = nodes[b].bounds.union(nodes[g].bounds)
                nodes[c].bounds = nodes[a].bounds.union(nodes[f].bounds)
                nodes[a].height = 1 + Swift.max(nodes[b].height, nodes[g].height)
                nodes[c].height = 1 + Swift.max(nodes[a].height, nodes[f].height)
            } else {
                nodes[c].right = iG
                nodes[a].right = iF
                nodes[f].parent = iA
                nodes[a].bounds = nodes[b].bounds.union(nodes[f].bounds)
                nodes[c].bounds = nodes[a].bounds.union(nodes[g].bounds)
                nodes[a].height = 1 + Swift.max(nodes[b].height, nodes[f].height)
                nodes[c].height = 1 + Swift.max(nodes[a].height, nodes[g].height)
            }
            return iC
        }

        // Rotação para a esquerda (sobe B)
        if balance < -1 {
            let iD = nodes[b].left
            let iE = nodes[b].right
            let d = Int(iD)
            let e = Int(iE)

            nodes[b].left = iA
            nodes[b].parent = nodes[a].parent
            nodes[a].parent = iB

            let bParent = nodes[b].parent
            if bParent != Self.nullNode {
                if nodes[Int(bParent)].left == iA {
                    nodes[Int(bParent)].left = iB
                } else {
                    nodes[Int(bParent)].right = iB
                }
            } else {
                root = iB
            }

            if nodes[d].height > nodes[e].height {
                nodes[b].right = iD
                nodes[a].left = iE
                nodes[e].parent = iA
                nodes[a].bounds = nodes[c].bounds.union(nodes[e].bounds)
                nodes[b].bounds = nodes[a].bounds.union(nodes[d].bounds)
                nodes[a].height = 1 + Swift.max(nodes[c].height, nodes[e].height)
                nodes[b].height = 1 + Swift.max(nodes[a].height, nodes[d].height)
            } else {
                nodes[b].right = iE
                nodes[a].left = iD
                nodes[d].parent = iA
                nodes[a].bounds = nodes[c].bounds.union(nodes[d].bounds)
                nodes[b].bounds = nodes[a].bounds.union(nodes[e].bounds)
                nodes[a].height = 1 + Swift.max(nodes[c].height, nodes[d].height)
                nodes[b].height = 1 + Swift.max(nodes[a].height, nodes[e].height)
            }
            return iB
        }

        return iA
    }
}
