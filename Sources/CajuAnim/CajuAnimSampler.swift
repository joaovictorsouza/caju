import CajuMath
import CajuScene

/// Buffers pré-alocados e reutilizáveis para amostragem de pose sem alocações no quadro estável.
///
/// Reserva espaço fixo para até `CajuPoseArena.maxJointCount` (128 `(?)`) juntas no `init`.
/// Compartilhe uma única instância na thread de jogo / laço principal entre todas as entidades
/// animadas.
public struct CajuAnimScratchBuffer: Sendable {
    @usableFromInline var localPoseA: ContiguousArray<CajuJointTransform>
    @usableFromInline var localPoseB: ContiguousArray<CajuJointTransform>
    @usableFromInline var localMatrices: ContiguousArray<CajuMat4>
    @usableFromInline var modelMatrices: ContiguousArray<CajuMat4>

    /// Cria buffers reservados para até `CajuPoseArena.maxJointCount` juntas.
    public init() {
        let cap = Int(CajuPoseArena.maxJointCount)
        self.localPoseA = ContiguousArray(repeating: .identity, count: cap)
        self.localPoseB = ContiguousArray(repeating: .identity, count: cap)
        self.localMatrices = ContiguousArray(repeating: .identity, count: cap)
        self.modelMatrices = ContiguousArray(repeating: .identity, count: cap)
    }

    /// Quantidade de juntas reservadas por buffer (`CajuPoseArena.maxJointCount`).
    @inlinable public var capacity: Int { localPoseA.count }
}

/// Amostrador SIMD de clipes, *crossfade*, máscaras e propagação hierárquica em espaço do modelo.
///
/// Todas as funções de caminho quente recebem `CajuAnimScratchBuffer` pré-alocado e gravam a
/// pose final (sem `inverseBind`) diretamente na `CajuPoseArena` do `CajuScene`, com **zero
/// alocação por quadro**.
public enum CajuAnimSampler {
    /// Amostra um clipe no instante `time` respeitando `mask`, gravando TRS locais em `localPose`.
    ///
    /// Juntas fora de `mask` ou sem canal no clipe recebem a `restPose` do esqueleto.
    public static func sampleLocalPose(
        clip: CajuAnimClip,
        time: Float,
        skeleton: CajuSkeleton,
        mask: CajuJointMask = .all,
        into localPose: inout ContiguousArray<CajuJointTransform>
    ) throws(CajuAnimError) {
        try clip.validate(for: skeleton)
        let count = skeleton.jointCount
        guard localPose.count >= count else {
            throw .invalidJointCount(localPose.count)
        }
        for j in 0..<count {
            localPose[j] = skeleton.restPose[j]
        }
        for ch in clip.translationChannels {
            let j = Int(ch.jointIndex)
            if mask.contains(j) {
                localPose[j].translation = ch.sample(at: time)
            }
        }
        for ch in clip.rotationChannels {
            let j = Int(ch.jointIndex)
            if mask.contains(j) {
                localPose[j].rotation = ch.sample(at: time)
            }
        }
        for ch in clip.scaleChannels {
            let j = Int(ch.jointIndex)
            if mask.contains(j) {
                localPose[j].scale = ch.sample(at: time)
            }
        }
    }

    /// Mistura duas poses locais respeitando máscaras individuais e `weight` (peso do destino em `[0, 1]`).
    ///
    /// Para juntas presentes em ambas as máscaras, os pesos são `(1 - w, w)` (somam `1`). Para juntas
    /// habilitadas apenas em uma máscara, o clipe ativo recebe peso `1`.
    public static func blendLocalPoses(
        from sourcePose: ContiguousArray<CajuJointTransform>,
        fromMask: CajuJointMask,
        to targetPose: ContiguousArray<CajuJointTransform>,
        toMask: CajuJointMask,
        weight: Float,
        skeleton: CajuSkeleton,
        into output: inout ContiguousArray<CajuJointTransform>
    ) throws(CajuAnimError) {
        guard weight.isFinite else { throw .invalidBlendWeight(weight) }
        let count = skeleton.jointCount
        guard sourcePose.count >= count, targetPose.count >= count, output.count >= count else {
            throw .invalidJointCount(count)
        }
        let w = CajuScalar.saturate(weight)
        for j in 0..<count {
            let inFrom = fromMask.contains(j)
            let inTo = toMask.contains(j)
            if inFrom && inTo {
                output[j] = CajuJointTransform.blend(sourcePose[j], targetPose[j], weight: w)
            } else if inFrom {
                output[j] = sourcePose[j]
            } else if inTo {
                output[j] = targetPose[j]
            } else {
                output[j] = skeleton.restPose[j]
            }
        }
    }

    /// Propaga transforms locais pela hierarquia do esqueleto usando SIMD (`CajuMat4`),
    /// gerando matrizes em **espaço do modelo** (sem `inverseBind`).
    public static func computeModelPose(
        localPose: ContiguousArray<CajuJointTransform>,
        skeleton: CajuSkeleton,
        scratch: inout CajuAnimScratchBuffer
    ) throws(CajuAnimError) {
        let count = skeleton.jointCount
        guard localPose.count >= count,
            scratch.localMatrices.count >= count,
            scratch.modelMatrices.count >= count
        else {
            throw .invalidJointCount(count)
        }

        // Converte cada TRS local para matriz 4x4 via operações SIMD4 de `CajuMat4`.
        for j in 0..<count {
            scratch.localMatrices[j] = localPose[j].matrix
        }

        // Propaga na ordem topológica (pais sempre antes dos filhos).
        if skeleton.isTopologicallyOrdered {
            for j in 0..<count {
                let parent = Int(skeleton.parentIndices[j])
                if parent < 0 {
                    scratch.modelMatrices[j] = scratch.localMatrices[j]
                } else {
                    scratch.modelMatrices[j] = scratch.modelMatrices[parent] * scratch.localMatrices[j]
                }
            }
        } else {
            for k in 0..<count {
                let j = Int(skeleton.evaluationOrder[k])
                let parent = Int(skeleton.parentIndices[j])
                if parent < 0 {
                    scratch.modelMatrices[j] = scratch.localMatrices[j]
                } else {
                    scratch.modelMatrices[j] = scratch.modelMatrices[parent] * scratch.localMatrices[j]
                }
            }
        }
    }

    /// Amostra `clip` no instante `time`, propaga a hierarquia em espaço do modelo e grava na `CajuPoseArena`.
    ///
    /// Quando `isCulled` é `true`, **pula toda a amostragem e não toca a arena nem `pose.version`**
    /// (retorna `false`). Quando executa, retorna `true` e incrementa `pose.version`.
    @discardableResult
    public static func sampleAndWrite(
        clip: CajuAnimClip,
        time: Float,
        skeleton: CajuSkeleton,
        mask: CajuJointMask = .all,
        isCulled: Bool = false,
        into pose: inout CajuSkinPose,
        arena: CajuPoseArena,
        scratch: inout CajuAnimScratchBuffer
    ) throws(CajuAnimError) -> Bool {
        if isCulled { return false }
        guard Int(pose.jointCount) == skeleton.jointCount else {
            throw .poseArena(.invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount))
        }
        try sampleLocalPose(
            clip: clip,
            time: time,
            skeleton: skeleton,
            mask: mask,
            into: &scratch.localPoseA
        )
        try computeModelPose(
            localPose: scratch.localPoseA,
            skeleton: skeleton,
            scratch: &scratch
        )
        try writeModelMatrices(
            scratch.modelMatrices,
            jointCount: skeleton.jointCount,
            into: &pose,
            arena: arena
        )
        return true
    }

    /// Amostra dois clipes em *crossfade*, propaga a hierarquia em espaço do modelo e grava na `CajuPoseArena`.
    ///
    /// Quando `isCulled` é `true`, **pula toda a amostragem e não toca a arena** (retorna `false`).
    @discardableResult
    public static func sampleCrossfadeAndWrite(
        fromClip: CajuAnimClip,
        fromTime: Float,
        fromMask: CajuJointMask = .all,
        toClip: CajuAnimClip,
        toTime: Float,
        toMask: CajuJointMask = .all,
        weight: Float,
        skeleton: CajuSkeleton,
        isCulled: Bool = false,
        into pose: inout CajuSkinPose,
        arena: CajuPoseArena,
        scratch: inout CajuAnimScratchBuffer
    ) throws(CajuAnimError) -> Bool {
        if isCulled { return false }
        guard Int(pose.jointCount) == skeleton.jointCount else {
            throw .poseArena(.invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount))
        }
        try sampleLocalPose(
            clip: fromClip,
            time: fromTime,
            skeleton: skeleton,
            mask: fromMask,
            into: &scratch.localPoseA
        )
        try sampleLocalPose(
            clip: toClip,
            time: toTime,
            skeleton: skeleton,
            mask: toMask,
            into: &scratch.localPoseB
        )
        try blendLocalPoses(
            from: scratch.localPoseA,
            fromMask: fromMask,
            to: scratch.localPoseB,
            toMask: toMask,
            weight: weight,
            skeleton: skeleton,
            into: &scratch.localPoseA
        )
        try computeModelPose(
            localPose: scratch.localPoseA,
            skeleton: skeleton,
            scratch: &scratch
        )
        try writeModelMatrices(
            scratch.modelMatrices,
            jointCount: skeleton.jointCount,
            into: &pose,
            arena: arena
        )
        return true
    }

    private static func writeModelMatrices(
        _ matrices: ContiguousArray<CajuMat4>,
        jointCount: Int,
        into pose: inout CajuSkinPose,
        arena: CajuPoseArena
    ) throws(CajuAnimError) {
        do throws(CajuPoseArena.ArenaError) {
            try arena.withMutablePoseBuffer(for: &pose) { dst in
                for i in 0..<jointCount {
                    dst[i] = matrices[i]
                }
            }
        } catch {
            throw .poseArena(error)
        }
    }
}
