/// Máscara de ativação por junta para até 128 juntas `(?)` sem alocação de *heap*.
///
/// Armazena dois `UInt64` (16 bytes, `BitwiseCopyable`), onde o bit `j` controla se a junta `j`
/// é afetada por uma amostragem ou mistura.
///
/// ```swift
/// var mask = CajuJointMask.none
/// mask.set(0, enabled: true)
/// mask.set(3, enabled: true)
/// ```
public struct CajuJointMask: Sendable, BitwiseCopyable, Equatable, Hashable {
    /// Bits para as juntas `0..<64`.
    public var low: UInt64
    /// Bits para as juntas `64..<128`.
    public var high: UInt64

    /// Máscara com todas as 128 juntas habilitadas.
    public static let all = CajuJointMask(low: .max, high: .max)
    /// Máscara com todas as juntas desabilitadas.
    public static let none = CajuJointMask(low: 0, high: 0)

    @inlinable
    public init(low: UInt64 = 0, high: UInt64 = 0) {
        self.low = low
        self.high = high
    }

    /// Cria uma máscara habilitando apenas as primeiras `jointCount` juntas (`0..<min(jointCount, 128)`).
    @inlinable
    public init(jointCount: Int) {
        let clamped = max(0, min(jointCount, 128))
        if clamped == 0 {
            self.low = 0
            self.high = 0
        } else if clamped < 64 {
            self.low = (1 &<< UInt64(clamped)) &- 1
            self.high = 0
        } else if clamped == 64 {
            self.low = .max
            self.high = 0
        } else if clamped < 128 {
            self.low = .max
            self.high = (1 &<< UInt64(clamped - 64)) &- 1
        } else {
            self.low = .max
            self.high = .max
        }
    }

    /// Cria uma máscara habilitando os índices informados em `0..<128` (índices fora da faixa são ignorados).
    public init(enabledJoints: some Sequence<Int>) {
        var mask = Self.none
        for joint in enabledJoints {
            mask.set(joint, enabled: true)
        }
        self = mask
    }

    /// Retorna `true` se a junta `jointIndex` está habilitada na máscara.
    @inlinable
    public func contains(_ jointIndex: Int) -> Bool {
        guard jointIndex >= 0 && jointIndex < 128 else { return false }
        if jointIndex < 64 {
            return (low & (1 &<< UInt64(jointIndex))) != 0
        }
        return (high & (1 &<< UInt64(jointIndex - 64))) != 0
    }

    /// Habilita ou desabilita `jointIndex` (índices fora de `0..<128` são ignorados).
    @inlinable
    public mutating func set(_ jointIndex: Int, enabled: Bool) {
        guard jointIndex >= 0 && jointIndex < 128 else { return }
        if jointIndex < 64 {
            let bit: UInt64 = 1 &<< UInt64(jointIndex)
            if enabled { low |= bit } else { low &= ~bit }
        } else {
            let bit: UInt64 = 1 &<< UInt64(jointIndex - 64)
            if enabled { high |= bit } else { high &= ~bit }
        }
    }

    /// União bit a bit de duas máscaras.
    @inlinable
    public func union(_ other: Self) -> Self {
        Self(low: low | other.low, high: high | other.high)
    }

    /// Interseção bit a bit de duas máscaras.
    @inlinable
    public func intersection(_ other: Self) -> Self {
        Self(low: low & other.low, high: high & other.high)
    }

    /// Inverso bit a bit da máscara.
    @inlinable
    public func inverted() -> Self {
        Self(low: ~low, high: ~high)
    }

    /// Cria uma máscara habilitando `rootJoint` e todos os seus descendentes em `skeleton`.
    public static func subtree(of skeleton: CajuSkeleton, rootJoint: Int) throws(CajuAnimError) -> Self {
        guard rootJoint >= 0 && rootJoint < skeleton.jointCount else {
            throw .invalidChannelTarget(
                jointIndex: UInt16(truncatingIfNeeded: max(0, rootJoint)),
                maxJointCount: skeleton.jointCount
            )
        }
        var mask = Self.none
        mask.set(rootJoint, enabled: true)
        for idx in skeleton.evaluationOrder {
            let j = Int(idx)
            let parent = Int(skeleton.parentIndices[j])
            if parent >= 0 && mask.contains(parent) {
                mask.set(j, enabled: true)
            }
        }
        return mask
    }
}
