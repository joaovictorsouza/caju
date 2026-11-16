import CajuCore
import CajuMath

/// Referência à pose de *skinning* em espaço do modelo (sem `inverseBind`), armazenada no ECS.
///
/// Componente `CajuCore` de ID 9 (`BitwiseCopyable`, ~12 bytes). As matrizes não ficam na coluna
/// do arquétipo; apontam para uma faixa contígua dentro de `CajuPoseArena` (recurso do mundo).
/// O `CajuAnim` escreve as matrizes em espaço do modelo na arena e incrementa `version`; o
/// `CajuRender` (R-1b) só lê e multiplica pelo `inverseBind` da malha quando `version` muda.
///
/// ```swift
/// let arena = CajuPoseArena(skeletonCapacity: 16)
/// var pose = try arena.allocate(jointCount: 32)
/// // CajuAnim atualiza `arena` e incrementa `pose.version`.
/// ```
public struct CajuSkinPose: CajuComponent, Equatable, Hashable {
    public static let componentID = CajuComponentID(9)

    /// Sentinela que indica ausência de faixa alocada na `CajuPoseArena`.
    public static let invalidSlot: UInt32 = .max

    /// Índice inicial (em unidades de `CajuMat4`) na `CajuPoseArena`.
    public var poseSlot: UInt32
    /// Quantidade de matrizes válidas a partir de `poseSlot` (`<= CajuPoseArena.maxJointCount`).
    public var jointCount: UInt16
    /// Versão monotônica incrementada a cada escrita na arena; permite pular cópias no render.
    public var version: UInt32

    @inlinable
    public init(
        poseSlot: UInt32 = CajuSkinPose.invalidSlot,
        jointCount: UInt16 = 0,
        version: UInt32 = 0
    ) {
        self.poseSlot = poseSlot
        self.jointCount = jointCount
        self.version = version
    }

    /// `true` quando referencia um slot potencialmente válido com ao menos uma junta.
    @inlinable
    public var isValid: Bool {
        poseSlot != Self.invalidSlot && jointCount > 0
    }
}

/// Arena contígua de matrizes `CajuMat4` com capacidade reservada para poses de *skinning*.
///
/// Mantém todas as matrizes em espaço do modelo (sem `inverseBind`) com **zero alocação no quadro
/// estável**. Toda a memória de matrizes e controle de faixas livres é pré-alocada no `init`;
/// estouros de capacidade retornam erro tipado (`ArenaError.capacityExceeded`).
///
/// Pertence à thread de jogo / laço principal (como `CajuWorld`).
public final class CajuPoseArena {
    /// Limite máximo de juntas por esqueleto no MVP: 128 `(?)`.
    public static let maxJointCount: UInt16 = 128

    /// Erros operacionais da arena de poses.
    public enum ArenaError: Error, Equatable, Sendable {
        /// Quantidade de juntas fora do intervalo `1...CajuPoseArena.maxJointCount`.
        case invalidJointCount(UInt16)
        /// Capacidade da arena insuficiente para atender à alocação solicitada.
        case capacityExceeded(requested: Int, available: Int)
        /// Referência `CajuSkinPose` inválida, já liberada ou fora dos limites da arena.
        case invalidPoseRange(slot: UInt32, jointCount: UInt16)
    }

    private struct FreeRange {
        var offset: UInt32
        var count: UInt32
    }

    /// Capacidade total reservada, em matrizes `CajuMat4`.
    public let matrixCapacity: Int
    private var storage: ContiguousArray<CajuMat4>
    private var freeRanges: ContiguousArray<FreeRange>
    private var allocatedCursor: Int = 0
    private var freeMatrixCount: Int = 0

    /// Cria uma arena com capacidade fixa de `matrixCapacity` matrizes `CajuMat4`.
    public init(matrixCapacity: Int = 4096) {
        let cap = max(0, matrixCapacity)
        self.matrixCapacity = cap
        self.storage = ContiguousArray(repeating: .identity, count: cap)
        self.freeRanges = []
        // Como faixas livres adjacentes sempre coalescem, existem no máximo ceil(cap / 2) faixas livres.
        self.freeRanges.reserveCapacity(max(16, (cap + 1) / 2))
    }

    /// Cria uma arena dimensionada para `skeletonCapacity` esqueletos de até `jointsPerSkeleton` juntas.
    public convenience init(
        skeletonCapacity: Int,
        jointsPerSkeleton: Int = Int(CajuPoseArena.maxJointCount)
    ) {
        let count = max(0, skeletonCapacity)
        let joints = max(0, min(jointsPerSkeleton, Int(Self.maxJointCount)))
        let (total, overflow) = count.multipliedReportingOverflow(by: joints)
        self.init(matrixCapacity: overflow ? Int.max / 64 : total)
    }

    /// Total de matrizes atualmente alocadas para poses ativas.
    public var usedMatrixCount: Int {
        allocatedCursor - freeMatrixCount
    }

    /// Total de matrizes ainda disponíveis na arena (contíguas ou em faixas livres).
    public var availableMatrixCount: Int {
        matrixCapacity - usedMatrixCount
    }

    /// Reserva uma faixa contígua de `jointCount` matrizes inicializadas com a identidade.
    public func allocate(jointCount: UInt16) throws(ArenaError) -> CajuSkinPose {
        guard jointCount > 0 && jointCount <= Self.maxJointCount else {
            throw .invalidJointCount(jointCount)
        }
        let needed = UInt32(jointCount)
        for i in 0..<freeRanges.count {
            if freeRanges[i].count >= needed {
                let slot = freeRanges[i].offset
                if freeRanges[i].count == needed {
                    freeRanges.remove(at: i)
                } else {
                    freeRanges[i].offset &+= needed
                    freeRanges[i].count &-= needed
                }
                freeMatrixCount -= Int(needed)
                fillIdentity(start: Int(slot), count: Int(needed))
                return CajuSkinPose(poseSlot: slot, jointCount: jointCount, version: 0)
            }
        }
        let end = allocatedCursor + Int(needed)
        guard end <= matrixCapacity else {
            throw .capacityExceeded(requested: Int(needed), available: availableMatrixCount)
        }
        let slot = UInt32(allocatedCursor)
        allocatedCursor = end
        fillIdentity(start: Int(slot), count: Int(needed))
        return CajuSkinPose(poseSlot: slot, jointCount: jointCount, version: 0)
    }

    /// Devolve a faixa da pose para reutilização futura e invalida a referência.
    public func release(_ pose: inout CajuSkinPose) throws(ArenaError) {
        guard pose.isValid, pose.jointCount <= Self.maxJointCount else {
            throw .invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount)
        }
        let start = Int(pose.poseSlot)
        let count = Int(pose.jointCount)
        guard start + count <= allocatedCursor else {
            throw .invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount)
        }
        let uStart = pose.poseSlot
        let uCount = UInt32(pose.jointCount)

        var insertIndex = freeRanges.count
        for i in 0..<freeRanges.count where freeRanges[i].offset >= uStart {
            insertIndex = i
            break
        }
        if insertIndex > 0 {
            let prev = freeRanges[insertIndex - 1]
            if prev.offset &+ prev.count > uStart {
                throw .invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount)
            }
        }
        if insertIndex < freeRanges.count {
            let next = freeRanges[insertIndex]
            if uStart &+ uCount > next.offset {
                throw .invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount)
            }
        }

        freeRanges.insert(FreeRange(offset: uStart, count: uCount), at: insertIndex)
        freeMatrixCount += count

        // Coalesce com a faixa à direita.
        if insertIndex + 1 < freeRanges.count {
            let cur = freeRanges[insertIndex]
            let right = freeRanges[insertIndex + 1]
            if cur.offset &+ cur.count == right.offset {
                freeRanges[insertIndex].count &+= right.count
                freeRanges.remove(at: insertIndex + 1)
            }
        }
        // Coalesce com a faixa à esquerda.
        if insertIndex > 0 {
            let left = freeRanges[insertIndex - 1]
            let cur = freeRanges[insertIndex]
            if left.offset &+ left.count == cur.offset {
                freeRanges[insertIndex - 1].count &+= cur.count
                freeRanges.remove(at: insertIndex)
            }
        }
        // Recua o cursor se a última faixa livre encosta no topo alocado.
        if let last = freeRanges.last, Int(last.offset) + Int(last.count) == allocatedCursor {
            allocatedCursor = Int(last.offset)
            freeMatrixCount -= Int(last.count)
            freeRanges.removeLast()
        }

        pose.poseSlot = CajuSkinPose.invalidSlot
        pose.jointCount = 0
    }

    /// Libera todas as faixas mantendo a capacidade já alocada.
    public func reset() {
        allocatedCursor = 0
        freeMatrixCount = 0
        freeRanges.removeAll(keepingCapacity: true)
    }

    /// Fornece acesso mutável direto ao buffer da pose na arena e incrementa `pose.version`.
    public func withMutablePoseBuffer(
        for pose: inout CajuSkinPose,
        _ body: (UnsafeMutableBufferPointer<CajuMat4>) -> Void
    ) throws(ArenaError) {
        let range = try validatedRange(for: pose)
        storage.withUnsafeMutableBufferPointer { base in
            let slice = UnsafeMutableBufferPointer(rebasing: base[range])
            body(slice)
        }
        pose.version &+= 1
    }

    /// Fornece acesso somente leitura ao buffer da pose na arena (sem copiar matrizes).
    public func withPoseBuffer<R>(
        for pose: CajuSkinPose,
        _ body: (UnsafeBufferPointer<CajuMat4>) -> R
    ) throws(ArenaError) -> R {
        let range = try validatedRange(for: pose)
        return storage.withUnsafeBufferPointer { base in
            let slice = UnsafeBufferPointer(rebasing: base[range])
            return body(slice)
        }
    }

    /// Lê uma matriz individual da pose na junta `jointIndex`.
    public func matrix(at jointIndex: Int, for pose: CajuSkinPose) throws(ArenaError) -> CajuMat4 {
        let range = try validatedRange(for: pose)
        guard jointIndex >= 0 && jointIndex < range.count else {
            throw .invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount)
        }
        return storage[range.lowerBound + jointIndex]
    }

    private func validatedRange(for pose: CajuSkinPose) throws(ArenaError) -> Range<Int> {
        guard pose.isValid, pose.jointCount <= Self.maxJointCount else {
            throw .invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount)
        }
        let start = Int(pose.poseSlot)
        let count = Int(pose.jointCount)
        let end = start + count
        guard start >= 0 && end <= allocatedCursor && end <= storage.count else {
            throw .invalidPoseRange(slot: pose.poseSlot, jointCount: pose.jointCount)
        }
        return start..<end
    }

    private func fillIdentity(start: Int, count: Int) {
        storage.withUnsafeMutableBufferPointer { base in
            for i in start..<(start + count) {
                base[i] = .identity
            }
        }
    }
}
