import CajuScene

/// Erros tipados do módulo de animação (`CajuAnim`).
public enum CajuAnimError: Error, Equatable, Sendable {
    /// Quantidade de juntas fora do intervalo `1...CajuPoseArena.maxJointCount`.
    case invalidJointCount(Int)
    /// Índice de pai fora do intervalo válido (`-1` ou `0..<jointCount`) ou auto-referência.
    case invalidParentIndex(joint: Int, parent: Int)
    /// Ciclo detectado na hierarquia de juntas do esqueleto.
    case cycleDetected(joint: Int)
    /// Duração do clipe ou transição inválida (negativa ou não finita).
    case invalidDuration(Float)
    /// Valor numérico não finito (NaN ou infinito) ou quaternion de norma nula em entrada.
    case nonFiniteValue
    /// Vetor de tempos e valores de um canal possuem tamanhos diferentes ou estão vazios.
    case invalidKeyframeCount(times: Int, values: Int)
    /// Tempos de *keyframes* negativos, não finitos ou fora de ordem não decrescente.
    case invalidKeyframeOrder(jointIndex: UInt16, keyframeIndex: Int)
    /// Canal aponta para uma junta fora dos limites suportados ou do esqueleto.
    case invalidChannelTarget(jointIndex: UInt16, maxJointCount: Int)
    /// Peso de mistura fora do intervalo válido ou não finito.
    case invalidBlendWeight(Float)
    /// Índice de esqueleto ausente no registro `CajuAnimLibrary`.
    case skeletonIndexOutOfBounds(Int)
    /// Índice de clipe ausente no registro `CajuAnimLibrary`.
    case clipIndexOutOfBounds(Int)
    /// Erro propagado pela arena de poses (`CajuPoseArena`).
    case poseArena(CajuPoseArena.ArenaError)
}
