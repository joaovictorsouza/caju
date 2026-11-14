import CajuMath

/// Resultado de um *raycast* contra `CajuTriangleBVH`.
public struct CajuTriangleBVHHit: Sendable, Equatable {
    /// Índice do triângulo atingido (`0..<triangleCount`, correspondente a `indices[3*i ..< 3*i+3]`).
    public let triangleIndex: UInt32
    /// Parâmetro `t` ao longo do raio no ponto de interseção.
    public let t: Float
    /// Coordenada baricêntrica `u` associada a `v1 - v0`.
    public let u: Float
    /// Coordenada baricêntrica `v` associada a `v2 - v0`.
    public let v: Float

    /// Cria um resultado de *raycast* em malha de triângulos.
    @inlinable
    public init(triangleIndex: UInt32, t: Float, u: Float, v: Float) {
        self.triangleIndex = triangleIndex
        self.t = t
        self.u = u
        self.v = v
    }
}

/// BVH estática de triângulos construída via SAH *binned* (16 *bins*).
///
/// Valida posições (`NaN`/infinito) e índices (`% 3 == 0` e dentro dos limites) na construção,
/// sem nunca causar *crash* com dados inválidos. Consultas usam `CajuBVHTraversalStack`
/// reutilizável e *visitors* sem alocação de *heap* no caminho quente.
///
/// ```swift
/// let positions = [CajuVec3(0, 0, 0), CajuVec3(1, 0, 0), CajuVec3(0, 1, 0)]
/// let bvh = try CajuTriangleBVH(positions: positions, indices: [0, 1, 2])
/// let ray = try CajuRayQuery(origin: SIMD3(0.2, 0.2, -1), direction: SIMD3(0, 0, 1))
/// let hit = bvh.raycastFirst(ray)
/// ```
public struct CajuTriangleBVH: Sendable {
    @usableFromInline
    internal static let sahBinCount = 16
    @usableFromInline
    internal static let maxLeafTriangles = 4
    @usableFromInline
    internal static let absoluteMaxTriangles: Int = Int(Int32.max / 2)
    @usableFromInline
    internal static let aabbTraversalSlack: Float = 1e-6

    @usableFromInline
    internal struct Node: Sendable {
        @usableFromInline var bounds: CajuAABB
        @usableFromInline var leftOrFirstPrim: Int32
        @usableFromInline var right: Int32
        @usableFromInline var primCount: Int32

        @inlinable
        var isLeaf: Bool { primCount > 0 }
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

    @usableFromInline internal let vertices: [SIMD3<Float>]
    @usableFromInline internal let indices: [UInt32]
    @usableFromInline internal var primOrder: [UInt32]
    @usableFromInline internal var nodes: [Node]

    /// Quantidade total de triângulos na malha.
    public let triangleCount: Int

    /// Indica se a BVH não contém triângulos.
    @inlinable
    public var isEmpty: Bool { triangleCount == 0 }

    /// AABB global da malha, ou `nil` se vazia.
    @inlinable
    public var bounds: CajuAABB? {
        nodes.isEmpty ? nil : nodes[0].bounds
    }

    /// Cria uma BVH de triângulos vazia.
    public init() {
        self.vertices = []
        self.indices = []
        self.primOrder = []
        self.nodes = []
        self.triangleCount = 0
    }

    /// Constrói uma BVH estática a partir de vértices `CajuVec3` e índices `UInt32`.
    ///
    /// - Throws:
    ///   - `CajuSpatialError.nonFiniteInput` se algum vértice contiver `NaN` ou infinito.
    ///   - `CajuSpatialError.invalidTriangleIndices` se `indices.count % 3 != 0` ou houver índice fora do limite.
    ///   - `CajuSpatialError.capacityExceeded` se o número de triângulos exceder `maxCapacity`.
    public init(
        positions: [CajuVec3],
        indices: [UInt32],
        maxCapacity: Int? = nil
    ) throws(CajuSpatialError) {
        var simdVertices: [SIMD3<Float>] = []
        simdVertices.reserveCapacity(positions.count)
        for p in positions {
            guard allFinite(p.storage) else {
                throw .nonFiniteInput
            }
            simdVertices.append(p.storage)
        }
        try self.init(validatedVertices: simdVertices, indices: indices, maxCapacity: maxCapacity)
    }

    /// Constrói uma BVH estática a partir de vértices `SIMD3<Float>` e índices `UInt32`.
    ///
    /// - Throws: `CajuSpatialError.nonFiniteInput`, `.invalidTriangleIndices` ou `.capacityExceeded`.
    public init(
        positions: [SIMD3<Float>],
        indices: [UInt32],
        maxCapacity: Int? = nil
    ) throws(CajuSpatialError) {
        for p in positions {
            guard allFinite(p) else {
                throw .nonFiniteInput
            }
        }
        try self.init(validatedVertices: positions, indices: indices, maxCapacity: maxCapacity)
    }

    /// Constrói uma BVH estática a partir de posições empacotadas `[x0, y0, z0, ...]` e índices `UInt32`.
    ///
    /// - Throws: `CajuSpatialError.nonFiniteInput`, `.invalidTriangleIndices` ou `.capacityExceeded`.
    public init(
        packedPositions: [Float],
        indices: [UInt32],
        maxCapacity: Int? = nil
    ) throws(CajuSpatialError) {
        guard packedPositions.count % 3 == 0 else {
            throw .invalidTriangleIndices
        }
        let vertexCount = packedPositions.count / 3
        var simdVertices: [SIMD3<Float>] = []
        simdVertices.reserveCapacity(vertexCount)
        var i = 0
        while i < packedPositions.count {
            let v = SIMD3<Float>(packedPositions[i], packedPositions[i + 1], packedPositions[i + 2])
            guard allFinite(v) else {
                throw .nonFiniteInput
            }
            simdVertices.append(v)
            i += 3
        }
        try self.init(validatedVertices: simdVertices, indices: indices, maxCapacity: maxCapacity)
    }

    private init(
        validatedVertices: [SIMD3<Float>],
        indices: [UInt32],
        maxCapacity: Int?
    ) throws(CajuSpatialError) {
        guard indices.count % 3 == 0 else {
            throw .invalidTriangleIndices
        }
        let triCount = indices.count / 3
        let resolvedCap = maxCapacity ?? Self.absoluteMaxTriangles
        guard resolvedCap >= 0, resolvedCap <= Self.absoluteMaxTriangles, triCount <= resolvedCap else {
            throw .capacityExceeded
        }

        let vertexCount = validatedVertices.count
        for idx in indices {
            guard Int(idx) < vertexCount else {
                throw .invalidTriangleIndices
            }
        }

        self.vertices = validatedVertices
        self.indices = indices
        self.triangleCount = triCount

        guard triCount > 0 else {
            self.primOrder = []
            self.nodes = []
            return
        }

        var triBounds: [CajuAABB] = []
        var triCentroids: [SIMD3<Float>] = []
        var order: [UInt32] = []
        triBounds.reserveCapacity(triCount)
        triCentroids.reserveCapacity(triCount)
        order.reserveCapacity(triCount)

        for t in 0..<triCount {
            let base = t * 3
            let v0 = validatedVertices[Int(indices[base])]
            let v1 = validatedVertices[Int(indices[base + 1])]
            let v2 = validatedVertices[Int(indices[base + 2])]
            let minP = SIMD3<Float>(
                Swift.min(v0.x, Swift.min(v1.x, v2.x)),
                Swift.min(v0.y, Swift.min(v1.y, v2.y)),
                Swift.min(v0.z, Swift.min(v1.z, v2.z))
            )
            let maxP = SIMD3<Float>(
                Swift.max(v0.x, Swift.max(v1.x, v2.x)),
                Swift.max(v0.y, Swift.max(v1.y, v2.y)),
                Swift.max(v0.z, Swift.max(v1.z, v2.z))
            )
            let b = CajuAABB(min: CajuVec3(storage: minP), max: CajuVec3(storage: maxP))
            triBounds.append(b)
            triCentroids.append(aabbCenter(b))
            order.append(UInt32(t))
        }

        var builtNodes: [Node] = []
        builtNodes.reserveCapacity(Swift.max(1, 2 * triCount - 1))

        var bins = [SAHBin](repeating: SAHBin(), count: Self.sahBinCount)
        var leftBounds = [CajuAABB](
            repeating: CajuAABB(min: .zero, max: .zero),
            count: Self.sahBinCount - 1
        )
        var leftCounts = [Int](repeating: 0, count: Self.sahBinCount - 1)

        self.primOrder = order
        self.nodes = []
        Self.buildNode(
            start: 0,
            end: triCount,
            triBounds: triBounds,
            triCentroids: triCentroids,
            primOrder: &self.primOrder,
            nodes: &builtNodes,
            bins: &bins,
            leftBounds: &leftBounds,
            leftCounts: &leftCounts
        )
        self.nodes = builtNodes
    }

    /// Retorna o triângulo no índice `index`, ou `nil` se fora dos limites.
    @inlinable
    public func triangle(at index: Int) -> CajuTriangle? {
        guard index >= 0, index < triangleCount else { return nil }
        return uncheckedTriangle(at: index)
    }

    @inlinable
    internal func uncheckedTriangle(at index: Int) -> CajuTriangle {
        let base = index * 3
        return CajuTriangle(
            vertices[Int(indices[base])],
            vertices[Int(indices[base + 1])],
            vertices[Int(indices[base + 2])]
        )
    }

    // MARK: - Consultas

    /// Retorna o primeiro impacto de raio contra a malha (menor `t` em `[ray.tMin, ray.tMax]`), ou `nil`.
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    @inlinable
    public func raycastFirst(
        _ ray: CajuRayQuery,
        twoSided: Bool = true,
        stack: inout CajuBVHTraversalStack
    ) -> CajuTriangleBVHHit? {
        stack.reset()
        defer { stack.reset() }
        guard !nodes.isEmpty else { return nil }
        guard
            let rootT = ray.intersectSlabs(
                nodes[0].bounds,
                tEnterInit: ray.tMin,
                tExitInit: ray.tMax,
                exitSlack: Self.aabbTraversalSlack
            )
        else {
            return nil
        }

        var bestT = ray.tMax
        var bestHit: CajuTriangleBVHHit?
        stack.push(0, tNear: rootT)

        while let (nodeIdx, tNear) = stack.pop() {
            let currentLimit = bestHit != nil ? bestT : ray.tMax
            let slackLimit =
                currentLimit + Swift.abs(currentLimit) * Self.aabbTraversalSlack + Self.aabbTraversalSlack
            if tNear > slackLimit {
                continue
            }
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let first = Int(node.leftOrFirstPrim)
                let end = first + Int(node.primCount)
                for p in first..<end {
                    let triIdx = primOrder[p]
                    let tri = uncheckedTriangle(at: Int(triIdx))
                    if let hit = tri.intersect(ray: ray, twoSided: twoSided, tMaxLimit: bestT) {
                        if bestHit == nil || hit.t < bestT {
                            bestT = hit.t
                            bestHit = CajuTriangleBVHHit(
                                triangleIndex: triIdx,
                                t: hit.t,
                                u: hit.u,
                                v: hit.v
                            )
                        }
                    }
                }
            } else {
                let left = node.leftOrFirstPrim
                let right = node.right
                let tLeft = ray.intersectSlabs(
                    nodes[Int(left)].bounds,
                    tEnterInit: ray.tMin,
                    tExitInit: bestT,
                    exitSlack: Self.aabbTraversalSlack
                )
                let tRight = ray.intersectSlabs(
                    nodes[Int(right)].bounds,
                    tEnterInit: ray.tMin,
                    tExitInit: bestT,
                    exitSlack: Self.aabbTraversalSlack
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
    ///   se a profundidade ultrapassar 64 níveis). No caminho quente, use
    ///   ``raycastFirst(_:twoSided:stack:)``.
    @inlinable
    public func raycastFirst(_ ray: CajuRayQuery, twoSided: Bool = true) -> CajuTriangleBVHHit? {
        var stack = CajuBVHTraversalStack()
        return raycastFirst(ray, twoSided: twoSided, stack: &stack)
    }

    /// Visita todos os triângulos atingidos por `ray` (em ordem não especificada).
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    @inlinable
    public func raycastAll(
        _ ray: CajuRayQuery,
        twoSided: Bool = true,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuTriangleBVHHit) -> Bool
    ) {
        stack.reset()
        defer { stack.reset() }
        guard !nodes.isEmpty else { return }
        guard
            ray.intersectSlabs(
                nodes[0].bounds,
                tEnterInit: ray.tMin,
                tExitInit: ray.tMax,
                exitSlack: Self.aabbTraversalSlack
            ) != nil
        else {
            return
        }

        stack.push(0)
        while let (nodeIdx, _) = stack.pop() {
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let first = Int(node.leftOrFirstPrim)
                let end = first + Int(node.primCount)
                for p in first..<end {
                    let triIdx = primOrder[p]
                    let tri = uncheckedTriangle(at: Int(triIdx))
                    if let hit = tri.intersect(ray: ray, twoSided: twoSided) {
                        let outHit = CajuTriangleBVHHit(
                            triangleIndex: triIdx,
                            t: hit.t,
                            u: hit.u,
                            v: hit.v
                        )
                        if !visitor(outHit) { return }
                    }
                }
            } else {
                let left = node.leftOrFirstPrim
                let right = node.right
                if ray.intersectSlabs(
                    nodes[Int(left)].bounds,
                    tEnterInit: ray.tMin,
                    tExitInit: ray.tMax,
                    exitSlack: Self.aabbTraversalSlack
                ) != nil {
                    stack.push(left)
                }
                if ray.intersectSlabs(
                    nodes[Int(right)].bounds,
                    tEnterInit: ray.tMin,
                    tExitInit: ray.tMax,
                    exitSlack: Self.aabbTraversalSlack
                ) != nil {
                    stack.push(right)
                }
            }
        }
    }

    /// Conveniência de `raycastAll` sem pilha explícita.
    ///
    /// - Important: Aloca uma `CajuBVHTraversalStack` local a cada chamada (alocando em *heap*
    ///   se a profundidade ultrapassar 64 níveis). No caminho quente, use
    ///   ``raycastAll(_:twoSided:stack:visitor:)``.
    @inlinable
    public func raycastAll(
        _ ray: CajuRayQuery,
        twoSided: Bool = true,
        visitor: (CajuTriangleBVHHit) -> Bool
    ) {
        var stack = CajuBVHTraversalStack()
        raycastAll(ray, twoSided: twoSided, stack: &stack, visitor: visitor)
    }

    /// Acrescenta todos os hits do raio em `results`.
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` e a capacidade de `results`
    /// sem alocações por consulta.
    @inlinable
    public func raycastAll(
        _ ray: CajuRayQuery,
        twoSided: Bool = true,
        into results: inout [CajuTriangleBVHHit],
        stack: inout CajuBVHTraversalStack
    ) {
        raycastAll(ray, twoSided: twoSided, stack: &stack) { hit in
            results.append(hit)
            return true
        }
    }

    /// Visita todos os índices de triângulos que sobrepõem exatamente `aabb` (via SAT).
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    ///
    /// - Throws: `CajuSpatialError.nonFiniteBounds` ou `.invalidBounds` se `aabb` for inválida.
    @inlinable
    public func query(
        overlapping aabb: CajuAABB,
        stack: inout CajuBVHTraversalStack,
        visitor: (UInt32) -> Bool
    ) throws(CajuSpatialError) {
        try validateAABB(aabb)

        stack.reset()
        defer { stack.reset() }
        guard !nodes.isEmpty else { return }
        guard nodes[0].bounds.intersects(aabb) else { return }

        stack.push(0)
        while let (nodeIdx, _) = stack.pop() {
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let first = Int(node.leftOrFirstPrim)
                let end = first + Int(node.primCount)
                for p in first..<end {
                    let triIdx = primOrder[p]
                    let tri = uncheckedTriangle(at: Int(triIdx))
                    if tri.overlaps(aabb) {
                        if !visitor(triIdx) { return }
                    }
                }
            } else {
                let left = node.leftOrFirstPrim
                let right = node.right
                if nodes[Int(left)].bounds.intersects(aabb) {
                    stack.push(left)
                }
                if nodes[Int(right)].bounds.intersects(aabb) {
                    stack.push(right)
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
        visitor: (UInt32) -> Bool
    ) throws(CajuSpatialError) {
        var stack = CajuBVHTraversalStack()
        try query(overlapping: aabb, stack: &stack, visitor: visitor)
    }

    /// Visita todos os índices de triângulos que sobrepõem a esfera `sphere`.
    ///
    /// Variante recomendada para o caminho quente: reutiliza `stack` sem alocações de *heap* após aquecida.
    ///
    /// - Throws: `CajuSpatialError.nonFiniteInput` ou `CajuSpatialError.invalidRadius`.
    @inlinable
    public func query(
        overlapping sphere: CajuSphere,
        stack: inout CajuBVHTraversalStack,
        visitor: (UInt32) -> Bool
    ) throws(CajuSpatialError) {
        try validateSphere(sphere)
        let center = sphere.center.storage
        let radius = sphere.radius

        stack.reset()
        defer { stack.reset() }
        guard !nodes.isEmpty else { return }
        let cullRadius = clampToFinite(radius * (1.0 + Self.aabbTraversalSlack) + Self.aabbTraversalSlack)
        guard aabbOverlapsSphere(nodes[0].bounds, center: center, radius: cullRadius) else { return }

        stack.push(0)
        while let (nodeIdx, _) = stack.pop() {
            let node = nodes[Int(nodeIdx)]
            if node.isLeaf {
                let first = Int(node.leftOrFirstPrim)
                let end = first + Int(node.primCount)
                for p in first..<end {
                    let triIdx = primOrder[p]
                    let tri = uncheckedTriangle(at: Int(triIdx))
                    if tri.overlaps(sphere) {
                        if !visitor(triIdx) { return }
                    }
                }
            } else {
                let left = node.leftOrFirstPrim
                let right = node.right
                if aabbOverlapsSphere(nodes[Int(left)].bounds, center: center, radius: cullRadius) {
                    stack.push(left)
                }
                if aabbOverlapsSphere(nodes[Int(right)].bounds, center: center, radius: cullRadius) {
                    stack.push(right)
                }
            }
        }
    }

    /// Conveniência de `query(overlapping:)` por esfera sem pilha explícita.
    ///
    /// - Important: Aloca uma `CajuBVHTraversalStack` local a cada chamada (alocando em *heap*
    ///   se a profundidade ultrapassar 64 níveis). No caminho quente, use
    ///   ``query(overlapping:stack:visitor:)``.
    @inlinable
    public func query(
        overlapping sphere: CajuSphere,
        visitor: (UInt32) -> Bool
    ) throws(CajuSpatialError) {
        var stack = CajuBVHTraversalStack()
        try query(overlapping: sphere, stack: &stack, visitor: visitor)
    }

    /// Verifica invariantes estruturais da BVH de triângulos (bounds pai/filho, folhas e partição completa).
    public func validate() -> Bool {
        if nodes.isEmpty {
            return triangleCount == 0 && primOrder.isEmpty
        }
        if primOrder.count != triangleCount { return false }

        var visitedNodes = 0
        var visitedPrims = 0
        var stack = CajuBVHTraversalStack()
        stack.push(0)

        while let (nodeIdx, _) = stack.pop() {
            visitedNodes += 1
            if visitedNodes > nodes.count { return false }
            let i = Int(nodeIdx)
            if i < 0 || i >= nodes.count { return false }
            let node = nodes[i]

            if node.isLeaf {
                let first = Int(node.leftOrFirstPrim)
                let count = Int(node.primCount)
                if first < 0 || count <= 0 || first + count > triangleCount { return false }
                for p in first..<(first + count) {
                    let triIdx = Int(primOrder[p])
                    if triIdx < 0 || triIdx >= triangleCount { return false }
                    let tri = uncheckedTriangle(at: triIdx)
                    if !node.bounds.contains(CajuVec3(storage: tri.v0))
                        || !node.bounds.contains(CajuVec3(storage: tri.v1))
                        || !node.bounds.contains(CajuVec3(storage: tri.v2))
                    {
                        return false
                    }
                }
                visitedPrims += count
            } else {
                let l = Int(node.leftOrFirstPrim)
                let r = Int(node.right)
                if l < 0 || l >= nodes.count || r < 0 || r >= nodes.count || l == r { return false }
                let expected = nodes[l].bounds.union(nodes[r].bounds)
                if node.bounds != expected { return false }
                if !aabbContains(node.bounds, nodes[l].bounds)
                    || !aabbContains(node.bounds, nodes[r].bounds)
                {
                    return false
                }
                stack.push(node.leftOrFirstPrim)
                stack.push(node.right)
            }
        }

        return visitedNodes == nodes.count && visitedPrims == triangleCount
    }

    // MARK: - Construção SAH

    @discardableResult
    private static func buildNode(
        start: Int,
        end: Int,
        triBounds: [CajuAABB],
        triCentroids: [SIMD3<Float>],
        primOrder: inout [UInt32],
        nodes: inout [Node],
        bins: inout [SAHBin],
        leftBounds: inout [CajuAABB],
        leftCounts: inout [Int]
    ) -> Int32 {
        let span = end - start
        let nodeIdx = Int32(nodes.count)

        var totalBounds = triBounds[Int(primOrder[start])]
        var cMin = triCentroids[Int(primOrder[start])]
        var cMax = cMin
        for idx in (start + 1)..<end {
            let triIdx = Int(primOrder[idx])
            totalBounds = totalBounds.union(triBounds[triIdx])
            let c = triCentroids[triIdx]
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

        if span <= maxLeafTriangles {
            nodes.append(
                Node(
                    bounds: totalBounds,
                    leftOrFirstPrim: Int32(start),
                    right: -1,
                    primCount: Int32(span)
                )
            )
            return nodeIdx
        }

        var bestAxis = -1
        var bestSplitBin = -1
        var bestCost = Float.greatestFiniteMagnitude
        var bestAxisScale: Float = 0
        var bestAxisMin: Float = 0

        for axis in 0..<3 {
            let extent = cMax[axis] - cMin[axis]
            guard extent > 0, extent.isFinite else { continue }
            let scale = Float(sahBinCount) / extent
            guard scale.isFinite, scale > 0 else { continue }

            for b in 0..<sahBinCount {
                bins[b].count = 0
                bins[b].occupied = false
            }

            let minVal = cMin[axis]
            for idx in start..<end {
                let triIdx = Int(primOrder[idx])
                let c = triCentroids[triIdx][axis]
                let b = Swift.min(sahBinCount - 1, Swift.max(0, Int((c - minVal) * scale)))
                let bBox = triBounds[triIdx]
                if bins[b].occupied {
                    bins[b].bounds = bins[b].bounds.union(bBox)
                } else {
                    bins[b].bounds = bBox
                    bins[b].occupied = true
                }
                bins[b].count += 1
            }

            // Varredura prefixa (esquerda -> direita)
            var accCount = 0
            var accOccupied = false
            var accBounds = CajuAABB(min: .zero, max: .zero)
            for i in 0..<(sahBinCount - 1) {
                if bins[i].occupied {
                    accBounds = accOccupied ? accBounds.union(bins[i].bounds) : bins[i].bounds
                    accOccupied = true
                }
                accCount += bins[i].count
                leftCounts[i] = accCount
                leftBounds[i] = accBounds
            }

            var rightCount = 0
            var rightOccupied = false
            var rightBounds = CajuAABB(min: .zero, max: .zero)
            for i in stride(from: sahBinCount - 1, through: 1, by: -1) {
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
                let triIdx = Int(primOrder[left])
                let c = triCentroids[triIdx][bestAxis]
                let b = Swift.min(sahBinCount - 1, Swift.max(0, Int((c - bestAxisMin) * bestAxisScale)))
                if b <= bestSplitBin {
                    left += 1
                } else {
                    primOrder.swapAt(left, right)
                    right -= 1
                }
            }
            if left > start && left < end {
                mid = left
            }
        }

        // Reserva o slot do nó interno antes dos filhos para manter raiz em índice 0.
        nodes.append(Node(bounds: totalBounds, leftOrFirstPrim: -1, right: -1, primCount: 0))
        let leftIdx = buildNode(
            start: start,
            end: mid,
            triBounds: triBounds,
            triCentroids: triCentroids,
            primOrder: &primOrder,
            nodes: &nodes,
            bins: &bins,
            leftBounds: &leftBounds,
            leftCounts: &leftCounts
        )
        let rightIdx = buildNode(
            start: mid,
            end: end,
            triBounds: triBounds,
            triCentroids: triCentroids,
            primOrder: &primOrder,
            nodes: &nodes,
            bins: &bins,
            leftBounds: &leftBounds,
            leftCounts: &leftCounts
        )
        nodes[Int(nodeIdx)].leftOrFirstPrim = leftIdx
        nodes[Int(nodeIdx)].right = rightIdx
        return nodeIdx
    }
}
