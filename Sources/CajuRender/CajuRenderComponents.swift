import CajuAssets
import CajuCore
import CajuMath

// Componentes de cena que o render extrai (R-1a, ADR 0023). IDs: 8 malha (contrato), 10 câmera, 11 luz
// direcional (9 é `CajuSkinPose` em `CajuScene`). Guardam `SIMD`/handles porque `CajuComponent` exige
// `BitwiseCopyable`.

/// Malha desenhável: a entidade também precisa de `CajuGlobalTransform`. Componente de ID 8.
public struct CajuRenderMesh: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(8)

    public var mesh: CajuAssetHandle<CajuMeshAsset>
    public var material: CajuAssetHandle<CajuMaterialAsset>
    /// Camadas em que a malha aparece; a câmera desenha o que casar com a máscara dela.
    public var layerMask: UInt32
    public var castsShadow: Bool

    public init(
        mesh: CajuAssetHandle<CajuMeshAsset>, material: CajuAssetHandle<CajuMaterialAsset>,
        layerMask: UInt32 = 1, castsShadow: Bool = true
    ) {
        self.mesh = mesh
        self.material = material
        self.layerMask = layerMask
        self.castsShadow = castsShadow
    }
}

/// Projeção da câmera.
public enum CajuProjectionKind: UInt8, Sendable, Hashable, BitwiseCopyable {
    case perspective
    case orthographic
}

/// Câmera de cena: a vista vem do `CajuGlobalTransform` da entidade (`-Z` para frente, `+Y` para cima) e a
/// razão de aspecto do alvo no desenho. Componente de ID 10.
public struct CajuCamera: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(10)

    public var projection: CajuProjectionKind
    /// Campo de visão vertical em radianos (perspectiva).
    public var fovY: Float
    /// Altura visível em unidades de mundo (ortográfica).
    public var orthographicHeight: Float
    public var near: Float
    public var far: Float
    public var layerMask: UInt32
    /// Cor de limpeza do alvo (linear).
    public var clearColorStorage: SIMD4<Float>
    /// Câmeras de maior prioridade vencem quando há várias (empate: a primeira na consulta).
    public var priority: Int32

    public init(
        projection: CajuProjectionKind = .perspective, fovY: Float = .pi / 3, orthographicHeight: Float = 10,
        near: Float = 0.1, far: Float = 100, layerMask: UInt32 = .max,
        clearColor: CajuColor = CajuColor(r: 0, g: 0, b: 0), priority: Int32 = 0
    ) {
        self.projection = projection
        self.fovY = fovY
        self.orthographicHeight = orthographicHeight
        self.near = near
        self.far = far
        self.layerMask = layerMask
        self.clearColorStorage = SIMD4(clearColor.r, clearColor.g, clearColor.b, clearColor.a)
        self.priority = priority
    }

    public var clearColor: CajuColor {
        CajuColor(
            r: clearColorStorage.x, g: clearColorStorage.y, b: clearColorStorage.z, a: clearColorStorage.w)
    }

    /// Matriz de projeção para a razão de aspecto do alvo; `nil` se os parâmetros forem inválidos.
    public func projectionMatrix(aspect: Float) -> CajuMat4? {
        switch projection {
        case .perspective:
            return .perspective(fovY: fovY, aspect: aspect, near: near, far: far)
        case .orthographic:
            let halfHeight = orthographicHeight / 2
            let halfWidth = halfHeight * aspect
            return .orthographic(
                left: -halfWidth, right: halfWidth, bottom: -halfHeight, top: halfHeight, near: near, far: far
            )
        }
    }
}

/// Fonte de luz direcional (o valor de desenho é `CajuDirectionalLight`). Componente de ID 11.
///
/// A direção é a do `CajuGlobalTransform` (`-Z` local, como a câmera) quando `usesTransform`; senão,
/// `directionStorage` em espaço de mundo.
public struct CajuDirectionalLightSource: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(11)

    public var directionStorage: SIMD3<Float>
    public var colorStorage: SIMD3<Float>
    public var intensity: Float
    public var castsShadow: Bool
    public var usesTransform: Bool

    public init(
        direction: CajuVec3 = CajuVec3(0, -1, 0), color: CajuColor = CajuColor(r: 1, g: 1, b: 1),
        intensity: Float = 1, castsShadow: Bool = false, usesTransform: Bool = false
    ) {
        directionStorage = direction.storage
        colorStorage = SIMD3(color.r, color.g, color.b)
        self.intensity = intensity
        self.castsShadow = castsShadow
        self.usesTransform = usesTransform
    }
}
