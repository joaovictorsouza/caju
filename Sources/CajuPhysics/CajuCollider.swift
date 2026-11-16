import CajuCore
import CajuMath

/// Forma local de um `CajuCollider`.
public enum CajuColliderShape: UInt8, Sendable, BitwiseCopyable, Equatable {
    /// Caixa alinhada ao espaço local do nó (`halfExtents` em `CajuCollider.size`).
    case box = 0
    /// Esfera de raio `CajuCollider.size.x`.
    case sphere = 1
}

/// Volume de consulta de um nó (raycast, sobreposição e picking). Componente de ID 24.
///
/// A forma vive no espaço local do nó e é levada ao mundo pelo `CajuGlobalTransform`; escala não
/// uniforme é respeitada nas consultas de raio. Não há resposta de colisão (física dinâmica é da Onda 2).
public struct CajuCollider: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(24)

    public var shape: CajuColliderShape
    /// Máscara de camadas a que este volume pertence; consultas filtram por `layerMask & layers != 0`.
    public var layers: UInt32
    /// Centro da forma no espaço local.
    public var center: SIMD3<Float>
    /// Semi-eixos da caixa; para esfera só `x` (raio) é usado.
    public var size: SIMD3<Float>

    public init(
        shape: CajuColliderShape, center: SIMD3<Float> = .zero, size: SIMD3<Float>,
        layers: UInt32 = 1
    ) {
        self.shape = shape
        self.center = center
        self.size = size
        self.layers = layers
    }

    public static func box(
        halfExtents: CajuVec3, center: CajuVec3 = .zero, layers: UInt32 = 1
    ) -> CajuCollider {
        CajuCollider(shape: .box, center: center.storage, size: halfExtents.storage, layers: layers)
    }

    public static func sphere(
        radius: Float, center: CajuVec3 = .zero, layers: UInt32 = 1
    ) -> CajuCollider {
        CajuCollider(
            shape: .sphere, center: center.storage, size: SIMD3(repeating: radius), layers: layers)
    }

    /// `true` se centro e tamanho são finitos e o tamanho não é negativo.
    public var isValid: Bool {
        let f =
            center.x.isFinite && center.y.isFinite && center.z.isFinite
            && size.x.isFinite && size.y.isFinite && size.z.isFinite
        return f && size.x >= 0 && size.y >= 0 && size.z >= 0
    }
}

/// Movimento cinemático simples: velocidade linear (mundo do pai) e angular (eixo × rad/s, local).
/// Componente de ID 25. Aplicado por `CajuPhysics.kinematicSystem()` sobre o `CajuTransform`.
public struct CajuKinematicBody: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(25)

    public var linearVelocity: SIMD3<Float>
    public var angularVelocity: SIMD3<Float>

    public init(linearVelocity: SIMD3<Float> = .zero, angularVelocity: SIMD3<Float> = .zero) {
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
    }
}
