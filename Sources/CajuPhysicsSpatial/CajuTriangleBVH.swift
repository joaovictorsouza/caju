import CajuMath

/// Resultado da interseção raio-triângulo de Möller–Trumbore.
public struct CajuTriangleHit: Sendable, Equatable {
    /// Parâmetro de distância ao longo do raio.
    public let t: Float
    /// Coordenada baricêntrica associada ao vértice `v1`.
    public let u: Float
    /// Coordenada baricêntrica associada ao vértice `v2` (o peso de `v0` é `1 - u - v`).
    public let v: Float

    /// Cria um resultado de interseção raio-triângulo.
    public init(t: Float, u: Float, v: Float) {
        self.t = t
        self.u = u
        self.v = v
    }
}

/// Triângulo geométrico validado com interseção raio-triângulo e testes de sobreposição.
///
/// ```swift
/// let tri = try CajuTriangle(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
/// let ray = try CajuRay(origin: SIMD3(0.2, 0.2, 1), direction: SIMD3(0, 0, -1))
/// let hit = tri.intersect(ray: ray)
/// ```
public struct CajuTriangle: Sendable, Equatable {
    /// Primeiro vértice.
    public let v0: SIMD3<Float>
    /// Segundo vértice.
    public let v1: SIMD3<Float>
    /// Terceiro vértice.
    public let v2: SIMD3<Float>

    @usableFromInline
    internal init(unchecked v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>) {
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
    }

    /// Cria um triângulo validando que todos os vértices são finitos.
    public init(
        _ v0: SIMD3<Float>,
        _ v1: SIMD3<Float>,
        _ v2: SIMD3<Float>
    ) throws(CajuSpatialError) {
        guard CajuAABB.isFinite(v0), CajuAABB.isFinite(v1), CajuAABB.isFinite(v2) else {
            throw .nonFiniteVertex
        }
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
    }

    /// Cria um triângulo a partir de vetores `CajuVec3`.
    public init(_ v0: CajuVec3, _ v1: CajuVec3, _ v2: CajuVec3) throws(CajuSpatialError) {
        try self.init(v0.storage, v1.storage, v2.storage)
    }

    /// Caixa delimitadora mínima do triângulo.
    @inlinable
    public var bounds: CajuAABB {
        let bMin = SIMD3(
            Swift.min(v0.x, Swift.min(v1.x, v2.x)),
            Swift.min(v0.y, Swift.min(v1.y, v2.y)),
            Swift.min(v0.z, Swift.min(v1.z, v2.z))
        )
        let bMax = SIMD3(
            Swift.max(v0.x, Swift.max(v1.x, v2.x)),
            Swift.max(v0.y, Swift.max(v1.y, v2.y)),
            Swift.max(v0.z, Swift.max(v1.z, v2.z))
        )
        return CajuAABB(uncheckedMin: bMin, max: bMax)
    }

    /// Interseção raio-triângulo pelo algoritmo de Möller–Trumbore.
    ///
    /// Triângulos degenerados (área zero ou colineares) nunca geram hit (`nil`).
    /// Quando `twoSided` é `false`, aplica culling de face traseira (orientação anti-horária).
    @inlinable
    public func intersect(ray: CajuRay, twoSided: Bool = true) -> CajuTriangleHit? {
        intersectRange(ray: ray, maxT: ray.tMax, twoSided: twoSided)
    }

    /// Testa sobreposição exata entre o triângulo e `aabb` (SAT).
    @inlinable
    public func overlaps(_ aabb: CajuAABB) -> Bool {
        let c = aabb.center
        let e = (aabb.max - aabb.min) * 0.5
        let a = v0 - c
        let b = v1 - c
        let d = v2 - c

        if Swift.min(a.x, Swift.min(b.x, d.x)) > e.x || Swift.max(a.x, Swift.max(b.x, d.x)) < -e.x {
            return false
        }
        if Swift.min(a.y, Swift.min(b.y, d.y)) > e.y || Swift.max(a.y, Swift.max(b.y, d.y)) < -e.y {
            return false
        }
        if Swift.min(a.z, Swift.min(b.z, d.z)) > e.z || Swift.max(a.z, Swift.max(b.z, d.z)) < -e.z {
            return false
        }

        let f0 = b - a
        let f1 = d - b
        let f2 = a - d

        // 9 eixos de produto vetorial entre os eixos da AABB e as arestas do triângulo
        guard
            Self.testEdgeAxisX(f0, a, b, d, e),
            Self.testEdgeAxisX(f1, a, b, d, e),
            Self.testEdgeAxisX(f2, a, b, d, e),
            Self.testEdgeAxisY(f0, a, b, d, e),
            Self.testEdgeAxisY(f1, a, b, d, e),
            Self.testEdgeAxisY(f2, a, b, d, e),
            Self.testEdgeAxisZ(f0, a, b, d, e),
            Self.testEdgeAxisZ(f1, a, b, d, e),
            Self.testEdgeAxisZ(f2, a, b, d, e)
        else {
            return false
        }

        let normal = Self.cross(f0, f1)
        let planeDist = Self.dot(normal, a)
        let planeRadius = e.x * abs(normal.x) + e.y * abs(normal.y) + e.z * abs(normal.z)
        return abs(planeDist) <= planeRadius
    }

    /// Testa sobreposição exata entre o triângulo e a esfera `(center, radius)`.
    @inlinable
    public func intersects(sphereCenter center: SIMD3<Float>, radius: Float) -> Bool {
        let closest = Self.closestPoint(onTriangle: v0, v1, v2, to: center)
        let delta = closest - center
        let distSq = Self.dot(delta, delta)
        let radiusSq = radius * radius
        if distSq.isFinite, radiusSq.isFinite {
            return distSq <= radiusSq
        }
        return distSq.squareRoot() <= radius
    }

    @usableFromInline
    internal func intersectRange(
        ray: CajuRay,
        maxT: Float,
        twoSided: Bool
    ) -> CajuTriangleHit? {
        let e1 = v1 - v0
        let e2 = v2 - v0
        let e1LenSq = Self.dot(e1, e1)
        let e2LenSq = Self.dot(e2, e2)
        guard e1LenSq > 0, e2LenSq > 0 else { return nil }

        let areaCross = Self.cross(e1, e2)
        let areaCrossSq = Self.dot(areaCross, areaCross)
        guard areaCrossSq.isFinite, areaCrossSq > 1e-12 * e1LenSq * e2LenSq else {
            return nil
        }

        let pvec = Self.cross(ray.direction, e2)
        let det = Self.dot(e1, pvec)
        if !twoSided {
            guard det > 0 else { return nil }
        }

        let dirLenSq = Self.dot(ray.direction, ray.direction)
        let scaleSq = areaCrossSq * dirLenSq
        if scaleSq.isFinite, scaleSq > 0 {
            guard det * det > 1e-12 * scaleSq else { return nil }
        }
        guard det != 0 else { return nil }

        let invDet = 1 / det
        guard invDet.isFinite else { return nil }

        let tvec = ray.origin - v0
        let u = Self.dot(tvec, pvec) * invDet
        guard u >= 0, u <= 1 else { return nil }

        let qvec = Self.cross(tvec, e1)
        let v = Self.dot(ray.direction, qvec) * invDet
        guard v >= 0, u + v <= 1 else { return nil }

        let t = Self.dot(e2, qvec) * invDet
        guard t >= ray.tMin, t <= maxT else { return nil }

        return CajuTriangleHit(t: t, u: u, v: v)
    }

    @inline(__always)
    @usableFromInline
    internal static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        (a * b).sum()
    }

    @inline(__always)
    @usableFromInline
    internal static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }

    @inline(__always)
    @usableFromInline
    internal static func testEdgeAxisX(
        _ f: SIMD3<Float>,
        _ v0: SIMD3<Float>,
        _ v1: SIMD3<Float>,
        _ v2: SIMD3<Float>,
        _ e: SIMD3<Float>
    ) -> Bool {
        let p0 = -f.z * v0.y + f.y * v0.z
        let p1 = -f.z * v1.y + f.y * v1.z
        let p2 = -f.z * v2.y + f.y * v2.z
        let r = e.y * abs(f.z) + e.z * abs(f.y)
        return Swift.min(p0, Swift.min(p1, p2)) <= r && Swift.max(p0, Swift.max(p1, p2)) >= -r
    }

    @inline(__always)
    @usableFromInline
    internal static func testEdgeAxisY(
        _ f: SIMD3<Float>,
        _ v0: SIMD3<Float>,
        _ v1: SIMD3<Float>,
        _ v2: SIMD3<Float>,
        _ e: SIMD3<Float>
    ) -> Bool {
        let p0 = f.z * v0.x - f.x * v0.z
        let p1 = f.z * v1.x - f.x * v1.z
        let p2 = f.z * v2.x - f.x * v2.z
        let r = e.x * abs(f.z) + e.z * abs(f.x)
        return Swift.min(p0, Swift.min(p1, p2)) <= r && Swift.max(p0, Swift.max(p1, p2)) >= -r
    }

    @inline(__always)
    @usableFromInline
    internal static func testEdgeAxisZ(
        _ f: SIMD3<Float>,
        _ v0: SIMD3<Float>,
        _ v1: SIMD3<Float>,
        _ v2: SIMD3<Float>,
        _ e: SIMD3<Float>
    ) -> Bool {
        let p0 = -f.y * v0.x + f.x * v0.y
        let p1 = -f.y * v1.x + f.x * v1.y
        let p2 = -f.y * v2.x + f.x * v2.y
        let r = e.x * abs(f.y) + e.y * abs(f.x)
        return Swift.min(p0, Swift.min(p1, p2)) <= r && Swift.max(p0, Swift.max(p1, p2)) >= -r
    }

    @usableFromInline
    internal static func closestPoint(
        onTriangle a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>,
        to p: SIMD3<Float>
    ) -> SIMD3<Float> {
        let ab = b - a
        let ac = c - a
        let ap = p - a

        let d1 = dot(ab, ap)
        let d2 = dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }

        let bp = p - b
        let d3 = dot(ab, bp)
        let d4 = dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let denom = d1 - d3
            let v = denom > 0 ? d1 / denom : 0
            return a + ab * v
        }

        let cp = p - c
        let d5 = dot(ab, cp)
        let d6 = dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let denom = d2 - d6
            let w = denom > 0 ? d2 / denom : 0
            return a + ac * w
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, (d4 - d3) >= 0, (d5 - d6) >= 0 {
            let denom = (d4 - d3) + (d5 - d6)
            let w = denom > 0 ? (d4 - d3) / denom : 0
            return b + (c - b) * w
        }

        let sum = va + vb + vc
        let denom = sum > 0 ? 1 / sum : 0
        let v = vb * denom
        let w = vc * denom
        return a + ab * v + ac * w
    }
}

/// Resultado de raycast contra `CajuTriangleBVH`.
public struct CajuTriangleBVHHit: Sendable, Equatable {
    /// Índice original do triângulo na malha (`0 ..< triangleCount`).
    public let triangleIndex: UInt32
    /// Parâmetro de distância ao longo do raio.
    public let t: Float
    /// Coordenada baricêntrica `u`.
    public let u: Float
    /// Coordenada baricêntrica `v`.
    public let v: Float

    /// Cria um resultado de raycast em malha de triângulos.
    public init(triangleIndex: UInt32, t: Float, u: Float, v: Float) {
        self.triangleIndex = triangleIndex
        self.t = t
        self.u = u
        self.v = v
    }
}

/// BVH estática sobre malha de triângulos construída com SAH binned (16 bins).
///
/// ```swift
/// let verts = [CajuVec3(0, 0, 0), CajuVec3(1, 0, 0), CajuVec3(0, 1, 0)]
/// let bvh = try CajuTriangleBVH(positions: verts, indices: [0, 1, 2])
/// let ray = try CajuRay(origin: SIMD3(0.2, 0.2, 1), direction: SIMD3(0, 0, -1))
/// let hit = bvh.raycastFirst(ray: ray)
/// ```
public struct CajuTriangleBVH: Sendable {
    private static let maxLeafTriangles = 4

    private struct Node: Sendable {
        var aabb: CajuAABB
        var leftOrFirst: Int32
        var rightOrCount: Int32
        var isLeaf: Bool
    }

    private struct TriangleEntry: Sendable {
        var triangle: CajuTriangle
        var originalIndex: UInt32
    }

    private struct BuildTask {
        var range: Range<Int>
        var parent: Int32
        var isLeft: Bool
    }

    private var nodes: [Node] = []
    private var triangles: [TriangleEntry] = []

    /// Quantidade total de triângulos indexados pela BVH.
    public let triangleCount: Int

    /// `true` quando a BVH não contém triângulos.
    public var isEmpty: Bool { triangleCount == 0 }

    /// Caixa delimitadora raiz da malha, ou `nil` se vazia.
    public var bounds: CajuAABB? {
        nodes.first?.aabb
    }

    /// Constrói uma BVH estática a partir de vértices `CajuVec3` e índices `UInt32`.
    public init(positions: [CajuVec3], indices: [UInt32]) throws(CajuSpatialError) {
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(positions.count)
        for p in positions {
            let v = p.storage
            guard CajuAABB.isFinite(v) else {
                throw .nonFiniteVertex
            }
            verts.append(v)
        }
        try self.init(validatedVertices: verts, indices: indices)
    }

    /// Constrói uma BVH estática a partir de coordenadas planas `[x0, y0, z0, ...]` e índices `UInt32`.
    public init(positions: [Float], indices: [UInt32]) throws(CajuSpatialError) {
        guard positions.count % 3 == 0 else {
            throw .invalidVertexCoordinateCount(positions.count)
        }
        let vertexCount = positions.count / 3
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(vertexCount)
        var offset = 0
        while offset < positions.count {
            let v = SIMD3(positions[offset], positions[offset + 1], positions[offset + 2])
            guard CajuAABB.isFinite(v) else {
                throw .nonFiniteVertex
            }
            verts.append(v)
            offset += 3
        }
        try self.init(validatedVertices: verts, indices: indices)
    }

    private init(validatedVertices vertices: [SIMD3<Float>], indices: [UInt32]) throws(CajuSpatialError) {
        guard indices.count % 3 == 0 else {
            throw .invalidTriangleIndexCount(indices.count)
        }
        let vertexCount = vertices.count
        for idx in indices {
            if Int(idx) >= vertexCount {
                throw .invalidTriangleIndex(index: Int(idx), vertexCount: vertexCount)
            }
        }

        let triCount = indices.count / 3
        self.triangleCount = triCount
        guard triCount > 0 else { return }
        guard triCount <= Int(Int32.max) / 2 else {
            throw .capacityExceeded
        }

        var rawTriangles: [CajuTriangle] = []
        var triBounds: [CajuAABB] = []
        var triCenters: [SIMD3<Float>] = []
        rawTriangles.reserveCapacity(triCount)
        triBounds.reserveCapacity(triCount)
        triCenters.reserveCapacity(triCount)

        var i = 0
        while i < indices.count {
            let tri = CajuTriangle(
                unchecked: vertices[Int(indices[i])],
                vertices[Int(indices[i + 1])],
                vertices[Int(indices[i + 2])]
            )
            let b = tri.bounds
            rawTriangles.append(tri)
            triBounds.append(b)
            triCenters.append(b.center)
            i += 3
        }

        var order = Array(0..<triCount)
        let zeroBox = CajuAABB(uncheckedMin: .zero, max: .zero)
        nodes.reserveCapacity(2 * triCount - 1)
        triangles.reserveCapacity(triCount)

        var tasks: [BuildTask] = [BuildTask(range: 0..<triCount, parent: -1, isLeft: true)]
        var internalOrder: [Int32] = []

        while let task = tasks.popLast() {
            let nodeIdx = Int32(nodes.count)
            nodes.append(Node(aabb: zeroBox, leftOrFirst: 0, rightOrCount: 0, isLeaf: false))

            if task.parent != -1 {
                if task.isLeft {
                    nodes[Int(task.parent)].leftOrFirst = nodeIdx
                } else {
                    nodes[Int(task.parent)].rightOrCount = nodeIdx
                }
            }

            if task.range.count <= Self.maxLeafTriangles {
                let firstTri = Int32(triangles.count)
                var leafBox = triBounds[order[task.range.lowerBound]]
                for k in task.range {
                    let origIdx = order[k]
                    leafBox = leafBox.union(triBounds[origIdx])
                    triangles.append(
                        TriangleEntry(triangle: rawTriangles[origIdx], originalIndex: UInt32(origIdx))
                    )
                }
                nodes[Int(nodeIdx)] = Node(
                    aabb: leafBox,
                    leftOrFirst: firstTri,
                    rightOrCount: Int32(task.range.count),
                    isLeaf: true
                )
            } else {
                let (mid, _) = CajuSAHBuilder.partition(
                    bounds: triBounds,
                    centers: triCenters,
                    indices: &order,
                    range: task.range
                )
                internalOrder.append(nodeIdx)
                tasks.append(BuildTask(range: mid..<task.range.upperBound, parent: nodeIdx, isLeft: false))
                tasks.append(BuildTask(range: task.range.lowerBound..<mid, parent: nodeIdx, isLeft: true))
            }
        }

        for idx in internalOrder.reversed() {
            let n = nodes[Int(idx)]
            nodes[Int(idx)].aabb = nodes[Int(n.leftOrFirst)].aabb.union(nodes[Int(n.rightOrCount)].aabb)
        }
    }

    /// Verifica os invariantes estruturais da BVH de triângulos.
    public func validate() -> Bool {
        if nodes.isEmpty {
            return triangleCount == 0 && triangles.isEmpty
        }
        guard triangles.count == triangleCount else { return false }

        var stack = CajuBVHTraversalStack()
        stack.push(0)
        var visitedNodes = 0
        var visitedTriangles = 0

        while let idx = stack.pop() {
            let i = Int(idx)
            guard i >= 0, i < nodes.count else { return false }
            visitedNodes += 1
            if visitedNodes > nodes.count { return false }

            let node = nodes[i]
            if node.isLeaf {
                let first = Int(node.leftOrFirst)
                let count = Int(node.rightOrCount)
                guard count > 0, first >= 0, first + count <= triangles.count else { return false }
                for k in first..<(first + count) {
                    guard node.aabb.contains(triangles[k].triangle.bounds) else { return false }
                }
                visitedTriangles += count
            } else {
                let l = Int(node.leftOrFirst)
                let r = Int(node.rightOrCount)
                guard l >= 0, l < nodes.count, r >= 0, r < nodes.count, l != r else { return false }
                guard node.aabb.contains(nodes[l].aabb), node.aabb.contains(nodes[r].aabb) else {
                    return false
                }
                stack.push(node.leftOrFirst)
                stack.push(node.rightOrCount)
            }
        }

        return visitedNodes == nodes.count && visitedTriangles == triangleCount
    }

    /// Retorna o primeiro triângulo atingido por `ray` usando pilha de travessia reutilizável.
    public func raycastFirst(
        ray: CajuRay,
        twoSided: Bool = true,
        stack: inout CajuBVHTraversalStack
    ) -> CajuTriangleBVHHit? {
        guard !nodes.isEmpty else { return nil }
        guard nodes[0].aabb.intersectRange(ray: ray, maxT: ray.tMax) != nil else { return nil }

        var bestT = ray.tMax
        var bestHit: CajuTriangleBVHHit?
        stack.clear()
        stack.push(0)

        while let idx = stack.pop() {
            let node = nodes[Int(idx)]
            guard node.aabb.intersectRange(ray: ray, maxT: bestT) != nil else { continue }

            if node.isLeaf {
                let first = Int(node.leftOrFirst)
                let end = first + Int(node.rightOrCount)
                for k in first..<end {
                    let entry = triangles[k]
                    if let hit = entry.triangle.intersectRange(ray: ray, maxT: bestT, twoSided: twoSided) {
                        if bestHit == nil || hit.t < bestT {
                            bestT = hit.t
                            bestHit = CajuTriangleBVHHit(
                                triangleIndex: entry.originalIndex,
                                t: hit.t,
                                u: hit.u,
                                v: hit.v
                            )
                        }
                    }
                }
            } else {
                let l = node.leftOrFirst
                let r = node.rightOrCount
                let leftHit = nodes[Int(l)].aabb.intersectRange(ray: ray, maxT: bestT)
                let rightHit = nodes[Int(r)].aabb.intersectRange(ray: ray, maxT: bestT)
                switch (leftHit, rightHit) {
                case (.some(let lh), .some(let rh)):
                    if lh.tEnter < rh.tEnter {
                        stack.push(r)
                        stack.push(l)
                    } else {
                        stack.push(l)
                        stack.push(r)
                    }
                case (.some, .none):
                    stack.push(l)
                case (.none, .some):
                    stack.push(r)
                case (.none, .none):
                    break
                }
            }
        }
        return bestHit
    }

    /// Retorna o primeiro triângulo atingido por `ray` com pilha local sem alocação até profundidade 64.
    public func raycastFirst(ray: CajuRay, twoSided: Bool = true) -> CajuTriangleBVHHit? {
        var stack = CajuBVHTraversalStack()
        return raycastFirst(ray: ray, twoSided: twoSided, stack: &stack)
    }

    /// Visita todos os triângulos atingidos por `ray` (em ordem não especificada).
    ///
    /// Retorne `false` de `visitor` para interromper a travessia antecipadamente.
    public func raycastAll(
        ray: CajuRay,
        twoSided: Bool = true,
        stack: inout CajuBVHTraversalStack,
        visitor: (CajuTriangleBVHHit) -> Bool
    ) {
        guard !nodes.isEmpty else { return }
        stack.clear()
        stack.push(0)

        while let idx = stack.pop() {
            let node = nodes[Int(idx)]
            guard node.aabb.intersectRange(ray: ray, maxT: ray.tMax) != nil else { continue }

            if node.isLeaf {
                let first = Int(node.leftOrFirst)
                let end = first + Int(node.rightOrCount)
                for k in first..<end {
                    let entry = triangles[k]
                    if let hit = entry.triangle.intersectRange(
                        ray: ray,
                        maxT: ray.tMax,
                        twoSided: twoSided
                    ) {
                        let bvhHit = CajuTriangleBVHHit(
                            triangleIndex: entry.originalIndex,
                            t: hit.t,
                            u: hit.u,
                            v: hit.v
                        )
                        if !visitor(bvhHit) { return }
                    }
                }
            } else {
                stack.push(node.leftOrFirst)
                stack.push(node.rightOrCount)
            }
        }
    }

    /// Visita todos os triângulos atingidos por `ray` com pilha local.
    public func raycastAll(
        ray: CajuRay,
        twoSided: Bool = true,
        visitor: (CajuTriangleBVHHit) -> Bool
    ) {
        var stack = CajuBVHTraversalStack()
        raycastAll(ray: ray, twoSided: twoSided, stack: &stack, visitor: visitor)
    }

    /// Consulta os índices originais de todos os triângulos que sobrepõem `aabb`.
    ///
    /// Retorne `false` de `visitor` para interromper a travessia antecipadamente.
    public func query(
        overlapping aabb: CajuAABB,
        stack: inout CajuBVHTraversalStack,
        visitor: (UInt32) -> Bool
    ) {
        guard !nodes.isEmpty else { return }
        stack.clear()
        stack.push(0)

        while let idx = stack.pop() {
            let node = nodes[Int(idx)]
            guard node.aabb.overlaps(aabb) else { continue }

            if node.isLeaf {
                let first = Int(node.leftOrFirst)
                let end = first + Int(node.rightOrCount)
                for k in first..<end {
                    let entry = triangles[k]
                    if entry.triangle.overlaps(aabb) {
                        if !visitor(entry.originalIndex) { return }
                    }
                }
            } else {
                stack.push(node.leftOrFirst)
                stack.push(node.rightOrCount)
            }
        }
    }

    /// Consulta os índices originais de todos os triângulos que sobrepõem `aabb` com pilha local.
    public func query(overlapping aabb: CajuAABB, visitor: (UInt32) -> Bool) {
        var stack = CajuBVHTraversalStack()
        query(overlapping: aabb, stack: &stack, visitor: visitor)
    }

    /// Consulta os índices originais de todos os triângulos que intersectam a esfera `(center, radius)`.
    ///
    /// Retorne `false` de `visitor` para interromper a travessia antecipadamente.
    public func query(
        sphereCenter center: SIMD3<Float>,
        radius: Float,
        stack: inout CajuBVHTraversalStack,
        visitor: (UInt32) -> Bool
    ) throws(CajuSpatialError) {
        guard CajuAABB.isFinite(center), radius.isFinite else {
            throw .nonFiniteSphere
        }
        guard radius >= 0 else {
            throw .invalidRadius
        }
        guard !nodes.isEmpty else { return }
        stack.clear()
        stack.push(0)

        while let idx = stack.pop() {
            let node = nodes[Int(idx)]
            guard node.aabb.intersects(sphereCenter: center, radius: radius) else { continue }

            if node.isLeaf {
                let first = Int(node.leftOrFirst)
                let end = first + Int(node.rightOrCount)
                for k in first..<end {
                    let entry = triangles[k]
                    if entry.triangle.intersects(sphereCenter: center, radius: radius) {
                        if !visitor(entry.originalIndex) { return }
                    }
                }
            } else {
                stack.push(node.leftOrFirst)
                stack.push(node.rightOrCount)
            }
        }
    }

    /// Consulta os índices originais de todos os triângulos que intersectam a esfera `(center, radius)` com pilha local.
    public func query(
        sphereCenter center: SIMD3<Float>,
        radius: Float,
        visitor: (UInt32) -> Bool
    ) throws(CajuSpatialError) {
        var stack = CajuBVHTraversalStack()
        try query(sphereCenter: center, radius: radius, stack: &stack, visitor: visitor)
    }
}
