import CajuAssets
import CajuMath
import CajuScene

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    import Android
#endif

// Assets de CPU que o render consome (R-1a, ADR 0023): valores `Sendable` produzidos pelos *loaders*
// (glTF → malha/material, KTX2/PNG → textura) e lidos só na extração. O render sobe na GPU a partir deles
// (`CajuRenderResidency`); `CajuAssets` nunca vê o RHI.

/// Layout de vértice único do MVP: posição (3), normal (3), UV (2) em `Float`, intercalados (32 bytes).
public enum CajuMeshVertexLayout {
    public static let floatsPerVertex = 8
    public static let stride = floatsPerVertex * MemoryLayout<Float>.stride
}

/// Dados de *skinning* de uma malha (R-1b): por vértice, 4 índices de junta (como `Float`) e 4 pesos,
/// intercalados (8 `Float`); e o `inverseBind` de cada junta. A pose vem do AN-1 em espaço do modelo
/// (`CajuSkinPose`/`CajuPoseArena`); o render multiplica pelo `inverseBind` (ADR 0023, 0027).
public struct CajuMeshSkin: Sendable, Equatable {
    public static let floatsPerVertex = 8
    public static var stride: Int { floatsPerVertex * MemoryLayout<Float>.stride }

    public var jointsAndWeights: [Float]
    public var inverseBindMatrices: [CajuMat4]

    public init(jointsAndWeights: [Float], inverseBindMatrices: [CajuMat4]) {
        self.jointsAndWeights = jointsAndWeights
        self.inverseBindMatrices = inverseBindMatrices
    }

    public var jointCount: Int { inverseBindMatrices.count }

    /// Todos os vértices com peso 1 na junta `joint` (malha rígida presa a uma junta).
    public static func rigid(vertexCount: Int, joint: Int = 0, inverseBindMatrices: [CajuMat4])
        -> CajuMeshSkin
    {
        var data = [Float](repeating: 0, count: vertexCount * floatsPerVertex)
        for v in 0..<vertexCount {
            data[v * floatsPerVertex] = Float(joint)
            data[v * floatsPerVertex + 4] = 1
        }
        return CajuMeshSkin(jointsAndWeights: data, inverseBindMatrices: inverseBindMatrices)
    }
}

/// Malha em CPU: vértices intercalados (`CajuMeshVertexLayout`), índices de 32 bits, caixa local e,
/// opcionalmente, *skinning*.
public struct CajuMeshAsset: CajuAsset, Equatable {
    public var vertices: [Float]
    public var indices: [UInt32]
    public var bounds: CajuAABB
    public var skin: CajuMeshSkin?

    public init(vertices: [Float], indices: [UInt32], bounds: CajuAABB, skin: CajuMeshSkin? = nil) {
        self.vertices = vertices
        self.indices = indices
        self.bounds = bounds
        self.skin = skin
    }

    /// Quantidade de vértices.
    public var vertexCount: Int { vertices.count / CajuMeshVertexLayout.floatsPerVertex }

    /// `true` se a malha é desenhável: vértices completos, índices em triângulos e dentro da faixa.
    public var isValid: Bool {
        guard !vertices.isEmpty, vertices.count % CajuMeshVertexLayout.floatsPerVertex == 0,
            !indices.isEmpty, indices.count % 3 == 0
        else { return false }
        let limit = UInt32(truncatingIfNeeded: vertexCount)
        for index in indices where index >= limit { return false }
        if let skin {
            guard skin.jointsAndWeights.count == vertexCount * CajuMeshSkin.floatsPerVertex,
                skin.jointCount > 0, skin.jointCount <= Int(CajuPoseArena.maxJointCount)
            else { return false }
            let maxJoint = Float(skin.jointCount - 1)
            for v in 0..<vertexCount {
                for k in 0..<4 {
                    let joint = skin.jointsAndWeights[v * CajuMeshSkin.floatsPerVertex + k]
                    guard joint >= 0, joint <= maxJoint, joint == joint.rounded() else { return false }
                }
            }
        }
        return true
    }
}

/// Textura em CPU: RGBA8 (sRGB ou linear), mip 0, linhas sem preenchimento.
public struct CajuTextureAsset: CajuAsset, Equatable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]
    public var isSRGB: Bool

    public init(width: Int, height: Int, pixels: [UInt8], isSRGB: Bool = true) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.isSRGB = isSRGB
    }

    public var isValid: Bool { width > 0 && height > 0 && pixels.count == width * height * 4 }
}

/// Material em CPU (espaço linear). As texturas são outros assets; ausentes usam o escalar.
public struct CajuMaterialAsset: CajuAsset, Equatable {
    public var model: CajuMaterialModel
    public var alphaMode: CajuAlphaMode
    public var baseColor: CajuColor
    public var metallic: Float
    public var roughness: Float
    public var emissive: CajuColor
    public var alphaCutoff: Float
    public var doubleSided: Bool
    public var baseColorTexture: CajuAssetHandle<CajuTextureAsset>

    public init(
        model: CajuMaterialModel = .pbr, alphaMode: CajuAlphaMode = .opaque,
        baseColor: CajuColor = CajuColor(r: 1, g: 1, b: 1), metallic: Float = 0, roughness: Float = 1,
        emissive: CajuColor = CajuColor(r: 0, g: 0, b: 0), alphaCutoff: Float = 0.5,
        doubleSided: Bool = false,
        baseColorTexture: CajuAssetHandle<CajuTextureAsset> = .invalid
    ) {
        self.model = model
        self.alphaMode = alphaMode
        self.baseColor = baseColor
        self.metallic = metallic
        self.roughness = roughness
        self.emissive = emissive
        self.alphaCutoff = alphaCutoff
        self.doubleSided = doubleSided
        self.baseColorTexture = baseColorTexture
    }

    /// Material substituto (asset ainda carregando ou com falha): PBR branco fosco.
    public static let fallback = CajuMaterialAsset()
}

// MARK: - Malhas procedurais (testes, goldens e substitutos)

extension CajuMeshAsset {
    /// Cubo de lado `size` centrado na origem, 24 vértices (normais por face) e UV por face.
    public static func cube(size: Float = 1) -> CajuMeshAsset {
        let h = size / 2
        // (normal, eixo u, eixo v) por face; os 4 cantos em sentido anti-horário visto de fora.
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
        ]
        var vertices: [Float] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(24 * CajuMeshVertexLayout.floatsPerVertex)
        indices.reserveCapacity(36)
        for (face, (n, u, v)) in faces.enumerated() {
            let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
            for (cu, cv) in corners {
                let p = (n + u * cu + v * cv) * h
                vertices += [p.x, p.y, p.z, n.x, n.y, n.z, (cu + 1) / 2, (1 - cv) / 2]
            }
            let base = UInt32(face * 4)
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let extent = CajuVec3(h, h, h)
        return CajuMeshAsset(
            vertices: vertices, indices: indices, bounds: CajuAABB(min: -extent, max: extent))
    }

    /// Plano quadrado de lado `size` no plano XZ, normal `+Y`, centrado na origem.
    public static func plane(size: Float = 1) -> CajuMeshAsset {
        let h = size / 2
        let vertices: [Float] = [
            -h, 0, h, 0, 1, 0, 0, 1,
            h, 0, h, 0, 1, 0, 1, 1,
            h, 0, -h, 0, 1, 0, 1, 0,
            -h, 0, -h, 0, 1, 0, 0, 0,
        ]
        return CajuMeshAsset(
            vertices: vertices, indices: [0, 1, 2, 0, 2, 3],
            bounds: CajuAABB(min: CajuVec3(-h, -0.001, -h), max: CajuVec3(h, 0.001, h)))
    }

    /// Esfera UV de raio `radius` (`segments` meridianos, `rings` paralelos), normais suaves.
    public static func sphere(radius: Float = 0.5, segments: Int = 32, rings: Int = 16) -> CajuMeshAsset {
        let segments = max(segments, 3)
        let rings = max(rings, 2)
        var vertices: [Float] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity((segments + 1) * (rings + 1) * CajuMeshVertexLayout.floatsPerVertex)
        indices.reserveCapacity(segments * rings * 6)
        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let theta = v * .pi
            let (sinT, cosT) = (sinf(theta), cosf(theta))
            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let phi = u * 2 * .pi
                let n = SIMD3<Float>(sinT * cosf(phi), cosT, -sinT * sinf(phi))
                let p = n * radius
                vertices += [p.x, p.y, p.z, n.x, n.y, n.z, u, v]
            }
        }
        let row = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for segment in 0..<UInt32(segments) {
                let a = ring * row + segment
                let b = a + row
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        let extent = CajuVec3(radius, radius, radius)
        return CajuMeshAsset(
            vertices: vertices, indices: indices, bounds: CajuAABB(min: -extent, max: extent))
    }
}
