/// Pilha de travessia reutilizável para consultas em BVH sem alocação no caminho quente.
///
/// Armazena até 64 entradas em buffer *inline* (na *stack* da CPU ou no próprio valor)
/// e cresce dinamicamente para um *buffer* auxiliar apenas se a profundidade exceder 64 níveis.
/// Reutilizar a mesma instância entre consultas elimina alocações de *heap* mesmo em árvores profundas.
///
/// ```swift
/// var stack = CajuBVHTraversalStack()
/// let hit = bvh.raycastFirst(ray, stack: &stack)
/// ```
public struct CajuBVHTraversalStack: Sendable {
    @usableFromInline
    internal static let inlineCapacity = 64

    // 4 x SIMD16 = 64 entradas inline sem alocação de heap e compatível com Swift 6 / iOS 17 / macOS 14 / Linux.
    @usableFromInline internal var n0 = SIMD16<Int32>.zero
    @usableFromInline internal var n1 = SIMD16<Int32>.zero
    @usableFromInline internal var n2 = SIMD16<Int32>.zero
    @usableFromInline internal var n3 = SIMD16<Int32>.zero

    @usableFromInline internal var t0 = SIMD16<Float>.zero
    @usableFromInline internal var t1 = SIMD16<Float>.zero
    @usableFromInline internal var t2 = SIMD16<Float>.zero
    @usableFromInline internal var t3 = SIMD16<Float>.zero

    @usableFromInline internal var count: Int = 0
    @usableFromInline internal var overflowNodes: [Int32] = []
    @usableFromInline internal var overflowTNear: [Float] = []

    /// Cria uma pilha vazia pronta para reutilização.
    public init() {}

    /// Limpa a pilha mantendo eventual capacidade de *overflow* já alocada.
    @inlinable
    public mutating func reset() {
        count = 0
        if !overflowNodes.isEmpty {
            overflowNodes.removeAll(keepingCapacity: true)
            overflowTNear.removeAll(keepingCapacity: true)
        }
    }

    /// Indica se a pilha está vazia.
    @inlinable
    internal var isEmpty: Bool {
        count == 0
    }

    @inlinable
    internal mutating func push(_ nodeIndex: Int32, tNear: Float = 0) {
        if count < Self.inlineCapacity {
            setInline(at: count, node: nodeIndex, tNear: tNear)
        } else {
            overflowNodes.append(nodeIndex)
            overflowTNear.append(tNear)
        }
        count += 1
    }

    @inlinable
    internal mutating func pop() -> (nodeIndex: Int32, tNear: Float)? {
        guard count > 0 else { return nil }
        count -= 1
        if count < Self.inlineCapacity {
            return getInline(at: count)
        }
        let node = overflowNodes.removeLast()
        let t = overflowTNear.removeLast()
        return (node, t)
    }

    @inlinable
    internal mutating func setInline(at index: Int, node: Int32, tNear: Float) {
        let lane = index & 15
        switch index >> 4 {
        case 0:
            n0[lane] = node
            t0[lane] = tNear
        case 1:
            n1[lane] = node
            t1[lane] = tNear
        case 2:
            n2[lane] = node
            t2[lane] = tNear
        default:
            n3[lane] = node
            t3[lane] = tNear
        }
    }

    @inlinable
    internal func getInline(at index: Int) -> (Int32, Float) {
        let lane = index & 15
        switch index >> 4 {
        case 0:
            return (n0[lane], t0[lane])
        case 1:
            return (n1[lane], t1[lane])
        case 2:
            return (n2[lane], t2[lane])
        default:
            return (n3[lane], t3[lane])
        }
    }
}
