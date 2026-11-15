// Contrato público da trilha R-1 (ADR 0023, proposto): tipos de valor do mundo de render.
// Só declarações e funções puras; a extração, o frame graph de cena e os sistemas chegam em R-1a/R-1b.
import CajuMath
import CajuRHI

// MARK: - Identificadores do mundo de render

public enum CajuRenderMeshTag: Sendable {}
public enum CajuRenderMaterialTag: Sendable {}

/// Malha residente na GPU, conhecida pelo mundo de render: posição no cache de residência de `CajuRender`.
/// O render cria o cache a partir do `CajuAssetHandle` da malha (A-1) e o sobe na GPU sob o orçamento
/// de upload (ver `docs/briefs/r-1-contrato.md` §7.1 e ADR 0023); o jogo nunca cria este id à mão.
public typealias CajuRenderMeshID = CajuHandle<CajuRenderMeshTag>
/// Material residente (parâmetros + pipeline) conhecido pelo mundo de render.
public typealias CajuRenderMaterialID = CajuHandle<CajuRenderMaterialTag>

// MARK: - Material básico

/// Modelo de sombreamento do MVP: sem luz (`unlit`) ou PBR metálico-rugoso simples.
public enum CajuMaterialModel: UInt8, Sendable, Hashable {
    case unlit
    case pbr
}

/// Modo de mistura do material; define a fila de desenho (opaco antes de transparente).
public enum CajuAlphaMode: UInt8, Sendable, Hashable {
    case opaque
    case mask
    case blend
}

/// Material **resolvido** para o desenho, em espaço linear: é o que o render monta a partir do asset
/// de material (A-1) depois de subir as texturas. Textura ausente usa o valor escalar.
public struct CajuMaterialParams: Sendable, Equatable {
    public var model: CajuMaterialModel
    public var alphaMode: CajuAlphaMode
    public var baseColor: CajuColor
    public var metallic: Float
    public var roughness: Float
    public var emissive: CajuColor
    /// Corte de alfa quando `alphaMode == .mask`.
    public var alphaCutoff: Float
    public var doubleSided: Bool
    public var baseColorTexture: CajuTextureHandle?
    public var metallicRoughnessTexture: CajuTextureHandle?
    public var normalTexture: CajuTextureHandle?
    public var emissiveTexture: CajuTextureHandle?

    public init(
        model: CajuMaterialModel = .pbr, alphaMode: CajuAlphaMode = .opaque,
        baseColor: CajuColor = CajuColor(r: 1, g: 1, b: 1), metallic: Float = 0, roughness: Float = 1,
        emissive: CajuColor = CajuColor(r: 0, g: 0, b: 0), alphaCutoff: Float = 0.5,
        doubleSided: Bool = false,
        baseColorTexture: CajuTextureHandle? = nil, metallicRoughnessTexture: CajuTextureHandle? = nil,
        normalTexture: CajuTextureHandle? = nil, emissiveTexture: CajuTextureHandle? = nil
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
        self.metallicRoughnessTexture = metallicRoughnessTexture
        self.normalTexture = normalTexture
        self.emissiveTexture = emissiveTexture
    }
}

// MARK: - Luz

/// Luz direcional do MVP (uma por quadro); a sombra (R-1b) usa só ela.
public struct CajuDirectionalLight: Sendable, Equatable {
    /// Direção em que a luz viaja, em espaço de mundo (normalizada na extração).
    public var direction: CajuVec3
    public var color: CajuColor
    /// Intensidade escalar (unidade relativa; calibrar com o golden `(?)`).
    public var intensity: Float
    public var castsShadow: Bool

    public init(
        direction: CajuVec3, color: CajuColor = CajuColor(r: 1, g: 1, b: 1), intensity: Float = 1,
        castsShadow: Bool = false
    ) {
        self.direction = direction
        self.color = color
        self.intensity = intensity
        self.castsShadow = castsShadow
    }
}

// MARK: - Draw list

/// Fila de desenho; a ordem numérica é a ordem de submissão.
public enum CajuRenderQueue: UInt8, Sendable, Hashable {
    case shadow = 0
    case opaque = 1
    case mask = 2
    case blend = 3
}

/// Chave de ordenação de 64 bits de um item de desenho: fila (4 bits), pipeline (12), material (16),
/// profundidade (32).
///
/// Ordenar as chaves agrupa por pipeline e material (menos trocas de estado) e, dentro do grupo, desenha
/// opacos de frente para trás e transparentes de trás para frente (profundidade invertida na fila `blend`).
public struct CajuDrawKey: Sendable, Hashable, Comparable {
    public var bits: UInt64

    @inlinable public init(bits: UInt64) { self.bits = bits }

    /// Empacota os campos; valores acima da largura do campo são saturados (nunca invadem o campo vizinho).
    /// `depth` é a distância à câmera, não negativa; negativos e `NaN` valem `0`.
    public init(queue: CajuRenderQueue, pipeline: UInt32, material: UInt32, depth: Float) {
        let q = UInt64(queue.rawValue & 0xF)
        let p = UInt64(min(pipeline, 0xFFF))
        let m = UInt64(min(material, 0xFFFF))
        var d: UInt64 = 0
        if depth > 0 {
            // Distância não negativa: os bits do `Float` preservam a ordem; sem o bit de sinal (31 bits).
            d = UInt64(depth.bitPattern & 0x7FFF_FFFF)
        }
        if queue == .blend { d = 0x7FFF_FFFF - d }
        self.bits = (q << 60) | (p << 48) | (m << 32) | d
    }

    public var queue: UInt8 { UInt8(truncatingIfNeeded: bits >> 60) }
    public var pipeline: UInt32 { UInt32(truncatingIfNeeded: (bits >> 48) & 0xFFF) }
    public var material: UInt32 { UInt32(truncatingIfNeeded: (bits >> 32) & 0xFFFF) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.bits < rhs.bits }
}

/// Um item da draw list: o que desenhar, onde e com qual chave. Valor puro.
public struct CajuDrawItem: Sendable, Equatable {
    public var key: CajuDrawKey
    public var mesh: CajuRenderMeshID
    public var material: CajuRenderMaterialID
    /// Posição da matriz de mundo na tabela de instâncias do quadro (R-1b agrupa instâncias iguais).
    public var instanceIndex: UInt32
    /// Posição da paleta de juntas no quadro; `UInt32.max` = sem skinning (R-1b).
    public var poseIndex: UInt32

    public static let noPose: UInt32 = .max

    public init(
        key: CajuDrawKey, mesh: CajuRenderMeshID, material: CajuRenderMaterialID, instanceIndex: UInt32,
        poseIndex: UInt32 = CajuDrawItem.noPose
    ) {
        self.key = key
        self.mesh = mesh
        self.material = material
        self.instanceIndex = instanceIndex
        self.poseIndex = poseIndex
    }
}
