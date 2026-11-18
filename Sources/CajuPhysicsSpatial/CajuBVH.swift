import CajuMath

/// Construtor SAH com 16 bins compartilhado entre `CajuBVH` e `CajuTriangleBVH`.
internal enum CajuSAHBuilder {
    private static let binCount = 16

    private struct Bin {
        var bounds: CajuAABB?
        var count: Int = 0
    }

    static func partition(
        bounds: [CajuAABB],
        centers: [SIMD3<Float>],
        indices: inout [Int],
        range: Range<Int>
    ) -> (mid: Int, totalBounds: CajuAABB) {
        let firstIdx = indices[range.lowerBound]
        var totalBounds = bounds[firstIdx]
        var centroidMin = centers[firstIdx]
        var centroidMax = centroidMin

        for i in (range.lowerBound + 1)..<range.upperBound {
            let idx = indices[i]
            totalBounds = totalBounds.union(bounds[idx])
            let c = centers[idx]
            centroidMin = SIMD3(
                Swift.min(centroidMin.x, c.x),
                Swift.min(centroidMin.y, c.y),
                Swift.min(centroidMin.z, c.z)
            )
            centroidMax = SIMD3(
                Swift.max(centroidMax.x, c.x),
                Swift.max(centroidMax.y, c.y),
                Swift.max(centroidMax.z, c.z)
            )
        }

        let parentArea = totalBounds.surfaceArea
        var bestAxis = -1
        var bestSplit = -1
        var bestCost = Float.greatestFiniteMagnitude
        var bestAxisMin: Float = 0
        var bestAxisScale: Float = 0

        if parentArea > 0 {
            var bins = [Bin](repeating: Bin(), count: binCount)
            var leftAreas = [Float](repeating: 0, count: binCount - 1)
            var leftCounts = [Int](repeating: 0, count: binCount - 1)

            for axis in 0..<3 {
                let extent = centroidMax[axis] - centroidMin[axis]
                guard extent > 1e-6 else { continue }

                for b in 0..<binCount {
                    bins[b].bounds = nil
                    bins[b].count = 0
                }

                let cMin = centroidMin[axis]
                let scale = Float(binCount) / extent

                for i in range {
                    let idx = indices[i]
                    let rawBin = Int((centers[idx][axis] - cMin) * scale)
                    let bin = Swift.min(Swift.max(rawBin, 0), binCount - 1)
                    bins[bin].count += 1
                    if let existing = bins[bin].bounds {
                        bins[bin].bounds = existing.union(bounds[idx])
                    } else {
                        bins[bin].bounds = bounds[idx]
                    }
                }

                var runBounds: CajuAABB?
                var runCount = 0
                for i in 0..<(binCount - 1) {
                    if let bBounds = bins[i].bounds {
                        runBounds = runBounds.map { $0.union(bBounds) } ?? bBounds
                    }
                    runCount += bins[i].count
                    leftAreas[i] = runBounds?.surfaceArea ?? 0
                    leftCounts[i] = runCount
                }

                runBounds = nil
                runCount = 0
                for i in stride(from: binCount - 1, through: 1, by: -1) {
                    if let bBounds = bins[i].bounds {
                        runBounds = runBounds.map { $0.union(bBounds) } ?? bBounds
                    }
                    runCount += bins[i].count
                    let rightArea = runBounds?.surfaceArea ?? 0
                    let leftCount = leftCounts[i - 1]
                    guard leftCount > 0, runCount > 0 else { continue }
                    let cost = leftAreas[i - 1] * Float(leftCount) + rightArea * Float(runCount)
                    if cost < bestCost {
                        bestCost = cost
                        bestAxis = axis
                        bestSplit = i
                        bestAxisMin = cMin
                        bestAxisScale = scale
                    }
                }
            }
        }

        if bestAxis != -1 {
            var left = range.lowerBound
            var right = range.upperBound - 1
            while left <= right {
                let idx = indices[left]
                let rawBin = Int((centers[idx][bestAxis] - bestAxisMin) * bestAxisScale)
                let bin = Swift.min(Swift.max(rawBin, 0), binCount - 1)
                if bin < bestSplit {
                    left += 1
                } else {
                    indices.swapAt(left, right)
                    right -= 1
                }
            }
            if left > range.lowerBound && left < range.upperBound {
                return (left, totalBounds)
            }
        }

        let mid = range.lowerBound + range.count / 2
        return (mid, totalBounds)
    }
}

/// Handle estável para uma folha inserida em `CajuBVH`.
///
/// Inclui geração interna para detectar handles desatualizados ou já removidos.
public struct CajuBVHProxy: Sendable, Equatable, Hashable {
    @usableFromInline
    internal let index: UInt32
    @usableFromInline
    internal let generation: UInt32

    @usableFromInline
    internal init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }
}

/// Resultado de consulta por raio ou varredura em `CajuBVH`.
public struct CajuBVHHit<UserData: Sendable>: Sendable {
    /// Handle da folha atingida.
    public let proxy: CajuBVHProxy
    /// Dado associado à folha atingida.
    public let userData: UserData
    /// Parâmetro de entrada ao longo do raio ou fração `[0, 1]` da varredura.
    public let t: Float

    /// Cria um resultado de consulta.
    public init(proxy: CajuBVHProxy, userData: UserData, t: Float) {
        self.proxy = proxy
        self.userData = userData
        self.t = t
    }
}

extension CajuBVHHit: Equatable where UserData: Equatable {}
extension CajuBVHHit: Hashable where UserData: Hashable {}

/// Árvore de volumes delimitadores (BVH) dinâmica sobre AABBs.
///
/// Suporta construção em lote via SAH com 16 bins (`build(from:)`), inserção/remoção/atualização
/// incremental estilo árvore dinâmica com rotações de balanceamento, AABBs gordas com margem
/// configurável, free list de nós com reuso de slots e consultas sem alocação no caminho quente.
///
/// ```swift
/// var bvh = CajuBVH<UInt32>()
/// let p = try bvh.insert(aabb: CajuAABB(min: .zero, max: SIMD3(1, 1, 1)), userData: 7)
/// let hit = bvh.raycastFirst(ray: try CajuRay(origin: SIMD3(0.5, 0.5, -2), direction: SIMD3(0, 0, 1)))
/// ```
public struct CajuBVH<UserData: Sendable>: Sendable {
    private struct Node: Sendable {
        var aabb: CajuAABB
        var parentOrNextFree: Int32
        var left: Int32
        var right: Int32
        var height: Int32
        var generation: UInt32
        var userData: UserData?
    }

    private struct BuildTask {
        var range: Range<Int>
        var parent: Int32
        var isLeft: Bool
    }

    private static var zeroBox: CajuAABB {
        CajuAABB(uncheckedMin: .zero, max: .zero)
    }

    /// Margem aplicada às AABBs gordas das folhas para absorver pequenos movimentos.
    public let fatMargin: Float
    /// Capacidade máxima opcional de folhas ativas.
    public let maxCapacity: Int?

    private var nodes: [Node] = []
    private var tightBounds: [CajuAABB] = []
    private var root: Int32 = -1
    private var freeListHead: Int32 = -1
    private var freeCount: Int = 0
    private var leafCount: Int = 0
    private var minGeneration: UInt32 = 1

    /// Cria uma BVH dinâmica vazia com `fatMargin = 0.1`.
    public init() {
        self.fatMargin = 0.1
        self.maxCapacity = nil
    }

    /// Cria uma BVH dinâmica vazia validando `fatMargin` e `maxCapacity`.
    public init(fatMargin: Float = 0.1, maxCapacity: Int? = nil) throws(CajuSpatialError) {
        guard fatMargin.isFinite, fatMargin >= 0 else {
            throw .invalidBounds
        }
        if let maxCapacity, maxCapacity < 0 {
            throw .capacityExceeded
        }
        self.fatMargin = fatMargin
        self.maxCapacity = maxCapacity
    }

    /// Número de folhas ativas na árvore.
    public var count: Int { leafCount }

    /// `true` quando não há folhas ativas na árvore.
    public var isEmpty: Bool { leafCount == 0 }

    /// Limites combinados da raiz, ou `nil` se a árvore estiver vazia.
    public var bounds: CajuAABB? {
        guard root != -1 else { return nil }
        return nodes[Int(root)].aabb
    }

    /// Constrói a árvore em lote usando SAH com 16 bins, substituindo o conteúdo anterior.
    ///
    /// Todos os handles anteriores são invalidados. Retorna os handles na mesma ordem de `items`.
    @discardableResult
    public mutating func build(
        from items: [(aabb: CajuAABB, userData: UserData)]
    ) throws(CajuSpatialError) -> [CajuBVHProxy] {
        if let maxCapacity, items.count > maxCapacity {
            throw .capacityExceeded
        }
        if !items.isEmpty {
            let neededNodes = 2 * items.count - 1
            if neededNodes > Int(Int32.max) {
                throw .capacityExceeded
            }
        }

        for n in nodes {
            if n.generation >= minGeneration {
                minGeneration = n.generation &+ 1
            }
        }
        if minGeneration == 0 { minGeneration = 1 }

        nodes.removeAll(keepingCapacity: true)
        tightBounds.removeAll(keepingCapacity: true)
        root = -1
        freeListHead = -1
        freeCount = 0
        leafCount = 0

        guard !items.isEmpty else { return [] }

        let itemCount = items.count
        let totalNodes = 2 * itemCount - 1
        nodes.reserveCapacity(totalNodes)
        tightBounds.reserveCapacity(totalNodes)

        var itemBounds: [CajuAABB] = []
        var itemCenters: [SIMD3<Float>] = []
        itemBounds.reserveCapacity(itemCount)
        itemCenters.reserveCapacity(itemCount)
        for item in items {
            itemBounds.append(item.aabb)
            itemCenters.append(item.aabb.center)
        }

        var indices = Array(0..<itemCount)
        let placeholder = Node(
            aabb: Self.zeroBox,
            parentOrNextFree: -1,
            left: -1,
            right: -1,
            height: 0,
            generation: minGeneration,
            userData: nil
        )
        var proxies = [CajuBVHProxy](
            repeating: CajuBVHProxy(index: 0, generation: 0),
            count: itemCount
        )

        var tasks: [BuildTask] = [BuildTask(range: 0..<itemCount, parent: -1, isLeft: true)]
        var internalOrder: [Int32] = []
        internalOrder.reserveCapacity(Swift.max(0, itemCount - 1))

        while let task = tasks.popLast() {
            let nodeIdx = Int32(nodes.count)
            nodes.append(placeholder)
            tightBounds.append(Self.zeroBox)

            if task.parent == -1 {
                root = nodeIdx
            } else if task.isLeft {
                nodes[Int(task.parent)].left = nodeIdx
            } else {
                nodes[Int(task.parent)].right = nodeIdx
            }

            if task.range.count == 1 {
                let itemIdx = indices[task.range.lowerBound]
                let item = items[itemIdx]
                tightBounds[Int(nodeIdx)] = item.aabb
                nodes[Int(nodeIdx)].aabb = item.aabb.enlarged(margin: fatMargin)
                nodes[Int(nodeIdx)].parentOrNextFree = task.parent
                nodes[Int(nodeIdx)].height = 0
                nodes[Int(nodeIdx)].userData = item.userData
                proxies[itemIdx] = CajuBVHProxy(index: UInt32(nodeIdx), generation: minGeneration)
            } else {
                let (mid, _) = CajuSAHBuilder.partition(
                    bounds: itemBounds,
                    centers: itemCenters,
                    indices: &indices,
                    range: task.range
                )
                nodes[Int(nodeIdx)].parentOrNextFree = task.parent
                internalOrder.append(nodeIdx)
                tasks.append(BuildTask(range: mid..<task.range.upperBound, parent: nodeIdx, isLeft: false))
                tasks.append(BuildTask(range: task.range.lowerBound..<mid, parent: nodeIdx, isLeft: true))
            }
        }

        for idx in internalOrder.reversed() {
            let i = Int(idx)
            let l = Int(nodes[i].left)
            let r = Int(nodes[i].right)
            nodes[i].aabb = nodes[l].aabb.union(nodes[r].aabb)
            nodes[i].height = 1 + Swift.max(nodes[l].height, nodes[r].height)
        }

        leafCount = itemCount
        return proxies
    }

    /// Insere uma nova folha na árvore e retorna seu handle estável.
    public mutating func insert(
        aabb: CajuAABB,
        userData: UserData
    ) throws(CajuSpatialError) -> CajuBVHProxy {
        if let maxCapacity, leafCount >= maxCapacity {
            throw .capacityExceeded
        }
        let neededNewNodes = root == -1 ? 1 : 2
        let availableSlots = freeCount + (Int(Int32.max) - nodes.count)
        guard availableSlots >= neededNewNodes else {
            throw .capacityExceeded
        }

        let leafIdx = allocateNode()
        let i = Int(leafIdx)
        tightBounds[i] = aabb
        nodes[i].aabb = aabb.enlarged(margin: fatMargin)
        nodes[i].left = -1
        nodes[i].right = -1
        nodes[i].height = 0
        nodes[i].userData = userData

        insertLeaf(leafIdx)
        leafCount += 1
        return CajuBVHProxy(index: UInt32(leafIdx), generation: nodes[i].generation)
    }

    /// Remove a folha associada a `proxy`, liberando seu slot para reuso.
    @discardableResult
    public mutating func remove(_ proxy: CajuBVHProxy) throws(CajuSpatialError) -> UserData {
        let leafIdx = try resolveLeaf(proxy)
        let i = Int(leafIdx)
        guard let data = nodes[i].userData else {
            throw .invalidHandle
        }
        removeLeaf(leafIdx)
        freeNode(leafIdx)
        leafCount -= 1
        return data
    }

    /// Atualiza a AABB de uma folha, reinserindo-a na árvore apenas se escapar da AABB gorda.
    ///
    /// Retorna `true` se houve reinserção na árvore ou `false` se a folha permaneceu contida
    /// na AABB gorda atual.
    @discardableResult
    public mutating func update(
        _ proxy: CajuBVHProxy,
        aabb: CajuAABB,
        displacement: SIMD3<Float> = .zero
    ) throws(CajuSpatialError) -> Bool {
        guard CajuAABB.isFinite(displacement) else {
            throw .nonFiniteVector
        }
        let leafIdx = try resolveLeaf(proxy)
        let i = Int(leafIdx)
        tightBounds[i] = aabb

        if nodes[i].aabb.contains(aabb) {
            return false
        }

        removeLeaf(leafIdx)

        var fat = aabb.enlarged(margin: fatMargin)
        let d = displacement * 2
        if d.x != 0 || d.y != 0 || d.z != 0 {
            let newMin = SIMD3(
                d.x < 0 ? fat.min.x + d.x : fat.min.x,
                d.y < 0 ? fat.min.y + d.y : fat.min.y,
                d.z < 0 ? fat.min.z + d.z : fat.min.z
            )
            let newMax = SIMD3(
                d.x > 0 ? fat.max.x + d.x : fat.max.x,
                d.y > 0 ? fat.max.y + d.y : fat.max.y,
                d.z > 0 ? fat.max.z + d.z : fat.max.z
            )
            if CajuAABB.isFinite(newMin), CajuAABB.isFinite(newMax) {
                fat = CajuAABB(uncheckedMin: newMin, max: newMax)
            }
        }
        nodes[i].aabb = fat
        insertLeaf(leafIdx)
        return true
    }

    /// Recalcula todas as AABBs e alturas dos nós internos a partir das folhas atuais.
    public mutating func refit() {
        guard root != -1 else { return }
        var visitStack = CajuBVHTraversalStack()
        var postOrder = CajuBVHTraversalStack()
        visitStack.push(root)

        while let idx = visitStack.pop() {
            let i = Int(idx)
            if nodes[i].height == 0 {
                nodes[i].aabb = tightBounds[i].enlarged(margin: fatMargin)
            } else {
                postOrder.push(idx)
                visitStack.push(nodes[i].left)
                visitStack.push(nodes[i].right)
            }
        }

        while let idx = postOrder.pop() {
            let i = Int(idx)
            let l = Int(nodes[i].left)
            let r = Int(nodes[i].right)
            nodes[i].aabb = nodes[l].aabb.union(nodes[r].aabb)
            nodes[i].height = 1 + Swift.max(nodes[l].height, nodes[r].height)
        }
    }

    /// Retorna `true` se `proxy` ainda estiver ativo na árvore.
    public func contains(_ proxy: CajuBVHProxy) -> Bool {
        let idx = Int(proxy.index)
        guard idx < nodes.count else { return false }
        let node = nodes[idx]
        return node.height == 0 && node.generation == proxy.generation
    }

    /// Retorna os limites exatos da folha associada a `proxy`.
    public func bounds(of proxy: CajuBVHProxy) throws(CajuSpatialError) -> CajuAABB {
        let leafIdx = try resolveLeaf(proxy)
        return tightBounds[Int(leafIdx)]
    }

    /// Retorna o dado associado à folha de `proxy`.
    public func userData(for proxy: CajuBVHProxy) throws(CajuSpatialError) -> UserData {
        let leafIdx = try resolveLeaf(proxy)
        guard let data = nodes[Int(leafIdx)].userData else {
            throw .invalidHandle
        }
        return data
    }

    /// Verifica invariantes estruturais da árvore (contenção pai/filhos, alturas, contagem e free list).
    public func validate() -> Bool {
        if root == -1 {
            return leafCount == 0 && validateFreeList(expectedCount: nodes.count)
        }
        let rootIdx = Int(root)
        guard rootIdx >= 0, rootIdx < nodes.count else { return false }
        guard nodes[rootIdx].parentOrNextFree == -1, nodes[rootIdx].height >= 0 else { return false }

        var stack = CajuBVHTraversalStack()
        stack.push(root)
        var visitedNodes = 0
        var visitedLeaves = 0

        while let idx = stack.pop() {
            visitedNodes += 1
            if visitedNodes > nodes.count { return false }
            let i = Int(idx)
            let node = nodes[i]

            if node.height == 0 {
                guard node.left == -1, node.right == -1, node.userData != nil else { return false }
                guard node.aabb.contains(tightBounds[i]) else { return false }
                visitedLeaves += 1
            } else if node.height > 0 {
                let l = Int(node.left)
                let r = Int(node.right)
                guard l >= 0, l < nodes.count, r >= 0, r < nodes.count, l != r else { return false }
                guard node.userData == nil else { return false }
                guard nodes[l].parentOrNextFree == idx, nodes[r].parentOrNextFree == idx else {
                    return false
                }
                guard nodes[l].height >= 0, nodes[r].height >= 0 else { return false }
                guard node.height == 1 + Swift.max(nodes[l].height, nodes[r].height) else { return false }
                guard node.aabb.contains(nodes[l].aabb), node.aabb.contains(nodes[r].aabb) else {
                    return false
                }
                stack.push(node.left)
                stack.push(node.right)
            } else {
                return false
            }
        }

        guard visitedLeaves == leafCount else { return false }
        let expectedFree = nodes.count - visitedNodes
        guard expectedFree == freeCount else { return false }
        return validateFreeList(expectedCount: expectedFree)
    }

    /// Retorna o primeiro impacto ao longo de `ray` usando uma pilha de travessia reutilizável.
    public func raycastFirst(
        ray: CajuRay,
        stack: inout CajuBVHTraversalStack
    ) -> CajuBVHHit<UserData>? {
        guard root != -1 else { return nil }
        guard nodes[Int(root)].aabb.intersectRange(ray: ray, maxT: ray.tMax) != nil else {
            return nil
        }

        var bestT = ray.tMax
        var bestHit: CajuBVHHit<UserData>?
        stack.clear()
        stack.push(root)

        while let idx = stack.pop() {
            let i = Int(idx)
            let node = nodes[i]
            guard node.aabb.intersectRange(ray: ray, maxT: bestT) != nil else {
                continue
            }

            if node.height == 0 {
                if let (tEnter, _) = tightBounds[i].intersectRange(ray: ray, maxT: bestT) {
                    if bestHit == nil || tEnter < bestT {
                        if let data = node.userData {
                            bestT = tEnter
                            bestHit = CajuBVHHit(
                                proxy: CajuBVHProxy(index: UInt32(idx), generation: node.generation),
                                userData: data,
                                t: tEnter
                            )
                        }
                    }
                }
            } else {
                let leftHit = nodes[Int(node.left)].aabb.intersectRange(ray: ray, maxT: bestT)
                let rightHit = nodes[Int(node.right)].aabb.intersectRange(ray: ray, maxT: bestT)
                switch (leftHit, rightHit) {
                case (.some(let l), .some(let r)):
                    if l.tEnter < r.tEnter {
                        stack.push(node.right)
                        stack.push(node.left)
                    } else {
                        stack.push(node.left)
                        stack.push(node.right)
                    }
                case (.some, .none):
                    stack.push(node.left)
                case (.none, .some):
                    stack.push(node.right)
                case (.none, .none):
                    break
                }
            }
        }
        return bestHit
    }

    /// Retorna o primeiro impacto ao longo de `ray` com pilha local sem alocação em árvores até profundidade 64.
    public func raycastFirst(ray: CajuRay) -> CajuBVHHit<UserData>? {
        var stack = CajuBVHTraversalStack()
        return raycastFirst(ray: ray, stack: &stack)
    }

    /// Visita todos os impactos ao longo de `ray` (em ordem não especificada).
    ///
    /// Retorne `false` de `visitor` para interromper a travessia antecipadamente.
    public func raycastAll(
        ray: CajuRay,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuBVHHit<UserData>) -> Bool
    ) {
        guard root != -1 else { return }
        stack.clear()
        stack.push(root)

        while let idx = stack.pop() {
            let i = Int(idx)
            let node = nodes[i]
            guard node.aabb.intersectRange(ray: ray, maxT: ray.tMax) != nil else {
                continue
            }

            if node.height == 0 {
                if let (tEnter, _) = tightBounds[i].intersectRange(ray: ray, maxT: ray.tMax),
                    let data = node.userData
                {
                    let hit = CajuBVHHit(
                        proxy: CajuBVHProxy(index: UInt32(idx), generation: node.generation),
                        userData: data,
                        t: tEnter
                    )
                    if !visitor(hit) { return }
                }
            } else {
                stack.push(node.left)
                stack.push(node.right)
            }
        }
    }

    /// Visita todos os impactos ao longo de `ray` com pilha local sem alocação em árvores até profundidade 64.
    public func raycastAll(ray: CajuRay, visitor: (CajuBVHHit<UserData>) -> Bool) {
        var stack = CajuBVHTraversalStack()
        raycastAll(ray: ray, stack: &stack, visitor: visitor)
    }

    /// Consulta todas as folhas que sobrepõem `aabb`.
    ///
    /// Retorne `false` de `visitor` para interromper a travessia antecipadamente.
    public func query(
        overlapping aabb: CajuAABB,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuBVHProxy, UserData) -> Bool
    ) {
        guard root != -1 else { return }
        stack.clear()
        stack.push(root)

        while let idx = stack.pop() {
            let i = Int(idx)
            let node = nodes[i]
            guard node.aabb.overlaps(aabb) else { continue }

            if node.height == 0 {
                if tightBounds[i].overlaps(aabb), let data = node.userData {
                    let proxy = CajuBVHProxy(index: UInt32(idx), generation: node.generation)
                    if !visitor(proxy, data) { return }
                }
            } else {
                stack.push(node.left)
                stack.push(node.right)
            }
        }
    }

    /// Consulta todas as folhas que sobrepõem `aabb` com pilha local sem alocação até profundidade 64.
    public func query(overlapping aabb: CajuAABB, visitor: (CajuBVHProxy, UserData) -> Bool) {
        var stack = CajuBVHTraversalStack()
        query(overlapping: aabb, stack: &stack, visitor: visitor)
    }

    /// Consulta todas as folhas que intersectam a esfera `(center, radius)`.
    ///
    /// Retorne `false` de `visitor` para interromper a travessia antecipadamente.
    public func query(
        sphereCenter center: SIMD3<Float>,
        radius: Float,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuBVHProxy, UserData) -> Bool
    ) throws(CajuSpatialError) {
        guard CajuAABB.isFinite(center), radius.isFinite else {
            throw .nonFiniteSphere
        }
        guard radius >= 0 else {
            throw .invalidRadius
        }
        guard root != -1 else { return }
        stack.clear()
        stack.push(root)

        while let idx = stack.pop() {
            let i = Int(idx)
            let node = nodes[i]
            guard node.aabb.intersects(sphereCenter: center, radius: radius) else { continue }

            if node.height == 0 {
                if tightBounds[i].intersects(sphereCenter: center, radius: radius),
                    let data = node.userData
                {
                    let proxy = CajuBVHProxy(index: UInt32(idx), generation: node.generation)
                    if !visitor(proxy, data) { return }
                }
            } else {
                stack.push(node.left)
                stack.push(node.right)
            }
        }
    }

    /// Consulta todas as folhas que intersectam a esfera `(center, radius)` com pilha local.
    public func query(
        sphereCenter center: SIMD3<Float>,
        radius: Float,
        visitor: (CajuBVHProxy, UserData) -> Bool
    ) throws(CajuSpatialError) {
        var stack = CajuBVHTraversalStack()
        try query(sphereCenter: center, radius: radius, stack: &stack, visitor: visitor)
    }

    /// Consulta todas as folhas atingidas por uma AABB varrida ao longo de `displacement` (`t` em `[0, 1]`).
    ///
    /// Retorne `false` de `visitor` para interromper a travessia antecipadamente.
    public func query(
        sweptAABB box: CajuAABB,
        displacement: SIMD3<Float>,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuBVHHit<UserData>) -> Bool
    ) throws(CajuSpatialError) {
        guard CajuAABB.isFinite(displacement) else {
            throw .nonFiniteVector
        }
        guard root != -1 else { return }
        let ray = CajuRay(uncheckedOrigin: .zero, direction: displacement, tMin: 0, tMax: 1)
        stack.clear()
        stack.push(root)

        while let idx = stack.pop() {
            let i = Int(idx)
            let node = nodes[i]
            let expandedNode = CajuAABB(
                uncheckedMin: node.aabb.min - box.max,
                max: node.aabb.max - box.min
            )
            guard expandedNode.intersectRange(ray: ray, maxT: 1) != nil else { continue }

            if node.height == 0 {
                let tight = tightBounds[i]
                let expandedTight = CajuAABB(
                    uncheckedMin: tight.min - box.max,
                    max: tight.max - box.min
                )
                if let (tEnter, _) = expandedTight.intersectRange(ray: ray, maxT: 1),
                    let data = node.userData
                {
                    let hit = CajuBVHHit(
                        proxy: CajuBVHProxy(index: UInt32(idx), generation: node.generation),
                        userData: data,
                        t: tEnter
                    )
                    if !visitor(hit) { return }
                }
            } else {
                stack.push(node.left)
                stack.push(node.right)
            }
        }
    }

    /// Consulta todas as folhas atingidas por uma AABB varrida ao longo de `displacement` com pilha local.
    public func query(
        sweptAABB box: CajuAABB,
        displacement: SIMD3<Float>,
        visitor: (CajuBVHHit<UserData>) -> Bool
    ) throws(CajuSpatialError) {
        var stack = CajuBVHTraversalStack()
        try query(sweptAABB: box, displacement: displacement, stack: &stack, visitor: visitor)
    }

    // MARK: - Helpers internos da árvore dinâmica

    private func resolveLeaf(_ proxy: CajuBVHProxy) throws(CajuSpatialError) -> Int32 {
        let idx = Int(proxy.index)
        guard idx < nodes.count else {
            throw .invalidHandle
        }
        let node = nodes[idx]
        guard node.height == 0, node.generation == proxy.generation else {
            throw .invalidHandle
        }
        return Int32(idx)
    }

    private mutating func allocateNode() -> Int32 {
        if freeListHead != -1 {
            let idx = freeListHead
            let i = Int(idx)
            freeListHead = nodes[i].parentOrNextFree
            nodes[i].parentOrNextFree = -1
            nodes[i].left = -1
            nodes[i].right = -1
            nodes[i].height = 0
            nodes[i].userData = nil
            freeCount -= 1
            return idx
        }
        let idx = Int32(nodes.count)
        nodes.append(
            Node(
                aabb: Self.zeroBox,
                parentOrNextFree: -1,
                left: -1,
                right: -1,
                height: 0,
                generation: minGeneration,
                userData: nil
            )
        )
        tightBounds.append(Self.zeroBox)
        return idx
    }

    private mutating func freeNode(_ idx: Int32) {
        let i = Int(idx)
        nodes[i].parentOrNextFree = freeListHead
        nodes[i].left = -1
        nodes[i].right = -1
        nodes[i].height = -1
        nodes[i].userData = nil
        nodes[i].generation &+= 1
        if nodes[i].generation == 0 {
            nodes[i].generation = 1
        }
        freeListHead = idx
        freeCount += 1
    }

    private mutating func insertLeaf(_ leaf: Int32) {
        if root == -1 {
            root = leaf
            nodes[Int(leaf)].parentOrNextFree = -1
            return
        }

        let leafAABB = nodes[Int(leaf)].aabb
        var index = root
        while nodes[Int(index)].height > 0 {
            let i = Int(index)
            let left = nodes[i].left
            let right = nodes[i].right
            let area = nodes[i].aabb.surfaceArea
            let combinedAABB = nodes[i].aabb.union(leafAABB)
            let combinedArea = combinedAABB.surfaceArea

            let cost = 2 * combinedArea
            let inheritanceCost = 2 * (combinedArea - area)

            let costLeft = descentCost(child: left, leafAABB: leafAABB, inheritanceCost: inheritanceCost)
            let costRight = descentCost(child: right, leafAABB: leafAABB, inheritanceCost: inheritanceCost)

            if cost < costLeft && cost < costRight {
                break
            }
            index = costLeft < costRight ? left : right
        }

        let sibling = index
        let oldParent = nodes[Int(sibling)].parentOrNextFree
        let newParent = allocateNode()
        let p = Int(newParent)

        nodes[p].parentOrNextFree = oldParent
        nodes[p].userData = nil
        nodes[p].aabb = leafAABB.union(nodes[Int(sibling)].aabb)
        nodes[p].height = nodes[Int(sibling)].height + 1
        nodes[p].left = sibling
        nodes[p].right = leaf

        relinkChild(parent: oldParent, oldChild: sibling, newChild: newParent)
        nodes[Int(sibling)].parentOrNextFree = newParent
        nodes[Int(leaf)].parentOrNextFree = newParent

        fixUpwards(startingAt: nodes[Int(leaf)].parentOrNextFree)
    }

    private func descentCost(child: Int32, leafAABB: CajuAABB, inheritanceCost: Float) -> Float {
        let c = nodes[Int(child)]
        let combined = leafAABB.union(c.aabb).surfaceArea
        if c.height == 0 {
            return combined + inheritanceCost
        }
        return (combined - c.aabb.surfaceArea) + inheritanceCost
    }

    private mutating func removeLeaf(_ leaf: Int32) {
        if leaf == root {
            root = -1
            return
        }

        let parent = nodes[Int(leaf)].parentOrNextFree
        let grandParent = nodes[Int(parent)].parentOrNextFree
        let sibling =
            nodes[Int(parent)].left == leaf
            ? nodes[Int(parent)].right
            : nodes[Int(parent)].left

        if grandParent != -1 {
            relinkChild(parent: grandParent, oldChild: parent, newChild: sibling)
            nodes[Int(sibling)].parentOrNextFree = grandParent
            freeNode(parent)
            fixUpwards(startingAt: grandParent)
        } else {
            root = sibling
            nodes[Int(sibling)].parentOrNextFree = -1
            freeNode(parent)
        }
    }

    private mutating func fixUpwards(startingAt start: Int32) {
        var index = start
        while index != -1 {
            index = balance(index)
            let i = Int(index)
            let l = Int(nodes[i].left)
            let r = Int(nodes[i].right)
            nodes[i].height = 1 + Swift.max(nodes[l].height, nodes[r].height)
            nodes[i].aabb = nodes[l].aabb.union(nodes[r].aabb)
            index = nodes[i].parentOrNextFree
        }
    }

    private mutating func relinkChild(parent: Int32, oldChild: Int32, newChild: Int32) {
        if parent == -1 {
            root = newChild
        } else {
            let p = Int(parent)
            if nodes[p].left == oldChild {
                nodes[p].left = newChild
            } else {
                nodes[p].right = newChild
            }
        }
    }

    private mutating func balance(_ iA: Int32) -> Int32 {
        let a = Int(iA)
        if nodes[a].height < 2 {
            return iA
        }

        let iB = nodes[a].left
        let iC = nodes[a].right
        let b = Int(iB)
        let c = Int(iC)
        let balanceFactor = nodes[c].height - nodes[b].height

        if balanceFactor > 1 {
            let iF = nodes[c].left
            let iG = nodes[c].right
            let f = Int(iF)
            let g = Int(iG)
            let oldParent = nodes[a].parentOrNextFree

            nodes[c].left = iA
            nodes[c].parentOrNextFree = oldParent
            nodes[a].parentOrNextFree = iC
            relinkChild(parent: oldParent, oldChild: iA, newChild: iC)

            if nodes[f].height > nodes[g].height {
                nodes[c].right = iF
                nodes[a].right = iG
                nodes[g].parentOrNextFree = iA
                nodes[a].aabb = nodes[b].aabb.union(nodes[g].aabb)
                nodes[c].aabb = nodes[a].aabb.union(nodes[f].aabb)
                nodes[a].height = 1 + Swift.max(nodes[b].height, nodes[g].height)
                nodes[c].height = 1 + Swift.max(nodes[a].height, nodes[f].height)
            } else {
                nodes[c].right = iG
                nodes[a].right = iF
                nodes[f].parentOrNextFree = iA
                nodes[a].aabb = nodes[b].aabb.union(nodes[f].aabb)
                nodes[c].aabb = nodes[a].aabb.union(nodes[g].aabb)
                nodes[a].height = 1 + Swift.max(nodes[b].height, nodes[f].height)
                nodes[c].height = 1 + Swift.max(nodes[a].height, nodes[g].height)
            }
            return iC
        }

        if balanceFactor < -1 {
            let iD = nodes[b].left
            let iE = nodes[b].right
            let d = Int(iD)
            let e = Int(iE)
            let oldParent = nodes[a].parentOrNextFree

            nodes[b].left = iA
            nodes[b].parentOrNextFree = oldParent
            nodes[a].parentOrNextFree = iB
            relinkChild(parent: oldParent, oldChild: iA, newChild: iB)

            if nodes[d].height > nodes[e].height {
                nodes[b].right = iD
                nodes[a].left = iE
                nodes[e].parentOrNextFree = iA
                nodes[a].aabb = nodes[c].aabb.union(nodes[e].aabb)
                nodes[b].aabb = nodes[a].aabb.union(nodes[d].aabb)
                nodes[a].height = 1 + Swift.max(nodes[c].height, nodes[e].height)
                nodes[b].height = 1 + Swift.max(nodes[a].height, nodes[d].height)
            } else {
                nodes[b].right = iE
                nodes[a].left = iD
                nodes[d].parentOrNextFree = iA
                nodes[a].aabb = nodes[c].aabb.union(nodes[d].aabb)
                nodes[b].aabb = nodes[a].aabb.union(nodes[e].aabb)
                nodes[a].height = 1 + Swift.max(nodes[c].height, nodes[d].height)
                nodes[b].height = 1 + Swift.max(nodes[a].height, nodes[e].height)
            }
            return iB
        }

        return iA
    }

    private func validateFreeList(expectedCount: Int) -> Bool {
        var cursor = freeListHead
        var walked = 0
        while cursor != -1 {
            walked += 1
            if walked > expectedCount { return false }
            let i = Int(cursor)
            guard i >= 0, i < nodes.count else { return false }
            let node = nodes[i]
            guard node.height == -1, node.userData == nil else { return false }
            cursor = node.parentOrNextFree
        }
        return walked == expectedCount
    }
}
