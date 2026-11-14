import CajuCore
import CajuMath

/// Transform local (TRS) de um nó. Componente `CajuCore` de ID 0.
///
/// Guarda `SIMD`s (e não `CajuVec3`/`CajuQuat`) porque `CajuComponent` exige `BitwiseCopyable` e os tipos
/// do `CajuMath` ainda não declaram essa conformância; os acessores convertem sem custo.
public struct CajuTransform: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(0)

    public var positionStorage: SIMD3<Float>
    public var rotationStorage: SIMD4<Float>
    public var scaleStorage: SIMD3<Float>

    public init(
        position: CajuVec3 = .zero, rotation: CajuQuat = .identity, scale: CajuVec3 = .one
    ) {
        positionStorage = position.storage
        rotationStorage = rotation.storage
        scaleStorage = scale.storage
    }

    public static let identity = CajuTransform()

    public var position: CajuVec3 {
        get { CajuVec3(storage: positionStorage) }
        set { positionStorage = newValue.storage }
    }
    public var rotation: CajuQuat {
        get {
            CajuQuat(x: rotationStorage.x, y: rotationStorage.y, z: rotationStorage.z, w: rotationStorage.w)
        }
        set { rotationStorage = newValue.storage }
    }
    public var scale: CajuVec3 {
        get { CajuVec3(storage: scaleStorage) }
        set { scaleStorage = newValue.storage }
    }

    /// Matriz local `T · R · S`.
    @inlinable public var matrix: CajuMat4 {
        CajuMat4.translation(position) * CajuMat4.rotation(rotation) * CajuMat4.scale(scale)
    }
}

/// Matriz de mundo do nó (calculada por `CajuScene.transformPropagation`). Componente de ID 1.
public struct CajuGlobalTransform: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(1)

    public var c0: SIMD4<Float>
    public var c1: SIMD4<Float>
    public var c2: SIMD4<Float>
    public var c3: SIMD4<Float>

    @inlinable public init(_ m: CajuMat4) {
        c0 = m.c0
        c1 = m.c1
        c2 = m.c2
        c3 = m.c3
    }

    @inlinable public var matrix: CajuMat4 {
        CajuMat4(columns: c0, c1, c2, c3)
    }
}

/// Liga o nó ao pai. `depth` (≥ 1) é mantido por `setParent` e ordena a propagação. Componente de ID 2.
public struct CajuParent: CajuComponent, Equatable {
    public static let componentID = CajuComponentID(2)
    public var entity: CajuEntity
    public var depth: UInt16

    public init(entity: CajuEntity, depth: UInt16 = 1) {
        self.entity = entity
        self.depth = depth
    }
}
