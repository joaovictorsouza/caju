/// BVH e consultas espaciais (`raycast`, `shapecast`, sobreposição).
///
/// Tipo marcador mantido para compatibilidade de vínculo entre módulos.
public enum CajuPhysicsSpatialModule {}

/// Erros tipados emitidos por operações espaciais de `CajuPhysicsSpatial`.
public enum CajuSpatialError: Error, Sendable, Equatable {
    /// Limites contêm `NaN` ou infinito.
    case nonFiniteBounds
    /// Limites inválidos (`min > max` em algum eixo).
    case invalidBounds
    /// Origem, direção ou intervalo `[tMin, tMax]` do raio contém `NaN` ou infinito.
    case nonFiniteRay
    /// Direção do raio é nula.
    case zeroDirectionRay
    /// Intervalo do raio inválido (`tMin < 0` ou `tMin > tMax`).
    case invalidRayRange
    /// Centro ou raio da esfera contém `NaN` ou infinito.
    case nonFiniteSphere
    /// Raio da esfera é negativo.
    case invalidRadius
    /// Vetor ou deslocamento contém `NaN` ou infinito.
    case nonFiniteVector
    /// Vértice de malha contém `NaN` ou infinito.
    case nonFiniteVertex
    /// Quantidade de coordenadas de vértices não é múltipla de 3.
    case invalidVertexCoordinateCount(Int)
    /// Quantidade de índices de triângulos não é múltipla de 3.
    case invalidTriangleIndexCount(Int)
    /// Índice de triângulo fora dos limites do buffer de vértices.
    case invalidTriangleIndex(index: Int, vertexCount: Int)
    /// Handle (`CajuBVHProxy`) inválido ou já removido.
    case invalidHandle
    /// Capacidade máxima da BVH excedida.
    case capacityExceeded
}

/// Pilha de travessia reutilizável para consultas sem alocação no caminho quente.
///
/// Armazena até 64 índices em buffer inline (`SIMD64<Int32>`) sem alocação em heap;
/// só aloca espaço adicional em `overflow` se a profundidade da árvore ultrapassar 64 níveis.
/// Reutilize a mesma instância entre consultas para evitar qualquer alocação subsequente.
///
/// ```swift
/// var stack = CajuBVHTraversalStack()
/// let hit = bvh.raycastFirst(ray: ray, stack: &stack)
/// ```
public struct CajuBVHTraversalStack: Sendable {
    private var inline: SIMD64<Int32> = .zero
    private var overflow: [Int32] = []
    private var count: Int = 0

    /// Cria uma pilha de travessia vazia com capacidade inline de 64 elementos.
    public init() {}

    /// Remove todos os elementos mantendo eventual capacidade de overflow já alocada.
    public mutating func clear() {
        count = 0
        if !overflow.isEmpty {
            overflow.removeAll(keepingCapacity: true)
        }
    }

    @usableFromInline
    internal var isEmpty: Bool { count == 0 }

    @usableFromInline
    internal mutating func push(_ value: Int32) {
        if count < 64 {
            inline[count] = value
        } else {
            overflow.append(value)
        }
        count += 1
    }

    @usableFromInline
    internal mutating func pop() -> Int32? {
        guard count > 0 else { return nil }
        count -= 1
        if count < 64 {
            return inline[count]
        }
        return overflow.popLast()
    }
}
