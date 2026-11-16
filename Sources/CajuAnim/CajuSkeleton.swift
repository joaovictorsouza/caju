import CajuMath
import CajuScene

/// Transformação local TRS de uma junta do esqueleto.
public struct CajuJointTransform: Sendable, BitwiseCopyable, Equatable {
    public var translation: CajuVec3
    public var rotation: CajuQuat
    public var scale: CajuVec3

    public static let identity = CajuJointTransform(
        translation: .zero,
        rotation: .identity,
        scale: .one
    )

    @inlinable
    public init(
        translation: CajuVec3 = .zero,
        rotation: CajuQuat = .identity,
        scale: CajuVec3 = .one
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    /// Matriz local `T * R * S` construída com operações SIMD (`CajuMat4`).
    @inlinable
    public var matrix: CajuMat4 {
        CajuMat4(translation: translation, rotation: rotation, scale: scale)
    }

    /// Mistura dois transforms locais (`lerp` para translação/escala e `slerp` pelo menor arco para rotação).
    ///
    /// `weight` é saturado em `[0, 1]` (não finito equivale a `0`). Os pesos efetivos `(1 - w, w)`
    /// somam `1`.
    @inlinable
    public static func blend(_ a: Self, _ b: Self, weight: Float) -> Self {
        let w = weight.isFinite ? CajuScalar.saturate(weight) : 0
        return Self(
            translation: CajuVec3.lerp(a.translation, b.translation, t: w),
            rotation: CajuQuat.slerp(a.rotation, b.rotation, t: w),
            scale: CajuVec3.lerp(a.scale, b.scale, t: w)
        )
    }
}

/// Hierarquia de juntas para animação esquelética, com suporte até 128 juntas `(?)`.
///
/// Valida índices de pai, ausência de ciclos e calcula uma ordem topológica fixa na criação
/// (aceita juntas em qualquer ordem, inclusive como vêm de glTF). A amostragem percorre
/// `evaluationOrder` em ordem linear, garantindo que o pai seja avaliado antes do filho.
public struct CajuSkeleton: Sendable, Equatable {
    /// Quantidade de juntas (`1...Int(CajuPoseArena.maxJointCount)`).
    public let jointCount: Int
    /// Índice do pai de cada junta (`-1` indica junta raiz).
    public let parentIndices: ContiguousArray<Int16>
    /// Pose de repouso (*rest/bind local*) usada para canais ausentes ou mascarados.
    public let restPose: ContiguousArray<CajuJointTransform>
    /// Ordem topológica pré-computada (pais antes dos filhos) para propagação sem recursão.
    public let evaluationOrder: ContiguousArray<UInt8>
    /// `true` quando `evaluationOrder[i] == i` para todas as juntas.
    public let isTopologicallyOrdered: Bool

    /// Constrói e valida um esqueleto a partir de `parentIndices` e da pose de repouso opcional.
    public init(
        parentIndices: [Int16],
        restPose: [CajuJointTransform]? = nil
    ) throws(CajuAnimError) {
        let count = parentIndices.count
        guard count > 0 && count <= Int(CajuPoseArena.maxJointCount) else {
            throw .invalidJointCount(count)
        }

        var validatedRest: ContiguousArray<CajuJointTransform> = []
        validatedRest.reserveCapacity(count)
        if let restPose {
            guard restPose.count == count else {
                throw .invalidJointCount(restPose.count)
            }
            for tr in restPose {
                guard tr.translation.isFinite, tr.scale.isFinite, tr.rotation.isFinite,
                    let normQ = tr.rotation.normalized()
                else {
                    throw .nonFiniteValue
                }
                validatedRest.append(
                    CajuJointTransform(
                        translation: tr.translation,
                        rotation: normQ,
                        scale: tr.scale
                    )
                )
            }
        } else {
            for _ in 0..<count {
                validatedRest.append(.identity)
            }
        }

        var parents: ContiguousArray<Int16> = []
        parents.reserveCapacity(count)
        for i in 0..<count {
            let p = Int(parentIndices[i])
            guard p >= -1 && p < count && p != i else {
                throw .invalidParentIndex(joint: i, parent: p)
            }
            parents.append(parentIndices[i])
        }

        // Ordenação topológica por Kahn (detecta ciclos e ordena pais antes de filhos).
        // state: 0 = não visitado, 1 = em processamento (na cadeia), 2 = concluído.
        var state = ContiguousArray<UInt8>(repeating: 0, count: count)
        var order: ContiguousArray<UInt8> = []
        order.reserveCapacity(count)
        var stack: ContiguousArray<Int> = []
        stack.reserveCapacity(count)

        for start in 0..<count where state[start] == 0 {
            var curr = start
            while curr >= 0 && state[curr] == 0 {
                state[curr] = 1
                stack.append(curr)
                curr = Int(parents[curr])
            }
            if curr >= 0 && state[curr] == 1 {
                throw .cycleDetected(joint: curr)
            }
            while let node = stack.popLast() {
                state[node] = 2
                order.append(UInt8(node))
            }
        }

        var naturalOrder = true
        for i in 0..<count where Int(order[i]) != i {
            naturalOrder = false
            break
        }

        self.jointCount = count
        self.parentIndices = parents
        self.restPose = validatedRest
        self.evaluationOrder = order
        self.isTopologicallyOrdered = naturalOrder
    }
}
