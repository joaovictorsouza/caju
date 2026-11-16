import CajuAssets
import CajuCore
import CajuMath
import CajuRHI
import CajuScene

/// Erros do render (sem `fatalError`; ADR 0009).
public enum CajuRenderError: Error, Sendable, Equatable {
    /// O quadro tem mais itens que a capacidade reservada na criação (nunca cresce no caminho quente).
    case capacityExceeded(CajuRenderCapacityKind)
    /// Erro do RHI ao criar recursos ou gravar o quadro.
    case rhi(CajuRHIError)
}

public enum CajuRenderCapacityKind: UInt8, Sendable, Equatable {
    case meshes
    case drawItems
    case residentMeshes
    case residentMaterials
}

/// Vista de uma câmera para um alvo (matrizes prontas para o desenho).
public struct CajuRenderView: Sendable, Equatable {
    public var view: CajuMat4
    public var projection: CajuMat4
    public var viewProjection: CajuMat4
    public var position: CajuVec3
    public var clearColor: CajuColor
    public var layerMask: UInt32
}

/// Mundo de render (ADR 0023): cópia, em colunas, do que o desenho precisa do quadro. Preenchido pela
/// extração (`extract`) ou à mão (testes headless); o desenho nunca lê o ECS.
///
/// Capacidade fixa na criação: no quadro estável não aloca; estourar lança `.capacityExceeded`.
/// Pertence à *thread* do jogo, como o dispositivo (não é `Sendable`).
public final class CajuRenderWorld {
    public let capacity: Int
    public private(set) var count = 0

    public private(set) var worldMatrices: [CajuMat4]
    public private(set) var worldBounds: [CajuAABB]
    public private(set) var meshes: [CajuAssetHandle<CajuMeshAsset>]
    public private(set) var materials: [CajuAssetHandle<CajuMaterialAsset>]
    public private(set) var layerMasks: [UInt32]

    /// Câmera do quadro (matriz de mundo da câmera e parâmetros); `nil` se a cena não tem câmera.
    public var camera: (transform: CajuMat4, camera: CajuCamera)?
    /// A luz direcional do quadro (a de maior intensidade; empate fica com a primeira na consulta).
    public var light: CajuDirectionalLight?
    /// Luz ambiente (cor × intensidade), somada ao PBR e ignorada pelo `unlit`.
    public var ambient = CajuColor(r: 0.03, g: 0.03, b: 0.03)

    public init(capacity: Int) {
        let capacity = max(capacity, 1)
        self.capacity = capacity
        worldMatrices = []
        worldBounds = []
        meshes = []
        materials = []
        layerMasks = []
        worldMatrices.reserveCapacity(capacity)
        worldBounds.reserveCapacity(capacity)
        meshes.reserveCapacity(capacity)
        materials.reserveCapacity(capacity)
        layerMasks.reserveCapacity(capacity)
    }

    /// Esvazia o quadro mantendo a memória.
    public func clear() {
        count = 0
        worldMatrices.removeAll(keepingCapacity: true)
        worldBounds.removeAll(keepingCapacity: true)
        meshes.removeAll(keepingCapacity: true)
        materials.removeAll(keepingCapacity: true)
        layerMasks.removeAll(keepingCapacity: true)
        camera = nil
        light = nil
    }

    /// Acrescenta uma malha ao quadro (a extração usa isto; testes também).
    public func append(
        world: CajuMat4, localBounds: CajuAABB, mesh: CajuAssetHandle<CajuMeshAsset>,
        material: CajuAssetHandle<CajuMaterialAsset>, layerMask: UInt32 = 1
    ) throws(CajuRenderError) {
        guard count < capacity else { throw .capacityExceeded(.meshes) }
        worldMatrices.append(world)
        worldBounds.append(localBounds.transformed(by: world))
        meshes.append(mesh)
        materials.append(material)
        layerMasks.append(layerMask)
        count += 1
    }

    /// Caixa usada para o *cull* de malhas que ainda não carregaram (não são desenhadas, mas entram no quadro).
    public static let pendingBounds = CajuAABB(min: CajuVec3(-0.5, -0.5, -0.5), max: CajuVec3(0.5, 0.5, 0.5))

    /// Extração cheia (R-1a): copia do ECS as malhas visíveis, a câmera e a luz. Chamar no fim do quadro de
    /// jogo, depois da propagação de transforms. Único ponto que consulta o servidor de assets.
    public func extract(from world: CajuWorld, assets: some CajuAssetServing) throws(CajuRenderError) {
        clear()
        var overflow = false
        world.forEach(CajuRead<CajuGlobalTransform>.self, CajuRead<CajuRenderMesh>.self) { transform, mesh in
            guard !overflow else { return }
            let bounds = assets.value(of: mesh.mesh)?.bounds ?? Self.pendingBounds
            do throws(CajuRenderError) {
                try append(
                    world: transform.matrix, localBounds: bounds, mesh: mesh.mesh, material: mesh.material,
                    layerMask: mesh.layerMask)
            } catch { overflow = true }
        }
        if overflow { throw .capacityExceeded(.meshes) }

        var best: (CajuMat4, CajuCamera)?
        world.forEach(CajuRead<CajuGlobalTransform>.self, CajuRead<CajuCamera>.self) { transform, camera in
            if best == nil || camera.priority > (best?.1.priority ?? .min) {
                best = (transform.matrix, camera)
            }
        }
        camera = best

        func consider(_ source: CajuDirectionalLightSource, direction: CajuVec3) {
            guard let normalized = direction.normalized() else { return }
            if let current = light, current.intensity >= source.intensity { return }
            light = CajuDirectionalLight(
                direction: normalized,
                color: CajuColor(
                    r: source.colorStorage.x, g: source.colorStorage.y, b: source.colorStorage.z),
                intensity: source.intensity, castsShadow: source.castsShadow)
        }
        world.forEach(CajuRead<CajuDirectionalLightSource>.self) { source in
            if !source.usesTransform {
                consider(source, direction: CajuVec3(storage: source.directionStorage))
            }
        }
        world.forEach(CajuRead<CajuGlobalTransform>.self, CajuRead<CajuDirectionalLightSource>.self) {
            transform, source in
            if source.usesTransform {
                consider(source, direction: transform.matrix.transformDirection(CajuVec3(0, 0, -1)))
            }
        }
    }

    /// Matrizes da câmera do quadro para um alvo com a razão de aspecto dada.
    public func makeView(aspect: Float) -> CajuRenderView? {
        guard let camera, let view = camera.transform.inverseAffine,
            let projection = camera.camera.projectionMatrix(aspect: aspect)
        else { return nil }
        let c3 = camera.transform.c3
        return CajuRenderView(
            view: view, projection: projection, viewProjection: projection * view,
            position: CajuVec3(c3.x, c3.y, c3.z), clearColor: camera.camera.clearColor,
            layerMask: camera.camera.layerMask)
    }
}

/// O que a draw list precisa saber de um item já resolvido pela residência na GPU.
public struct CajuResolvedDraw: Sendable, Equatable {
    public var mesh: CajuRenderMeshID
    public var material: CajuRenderMaterialID
    public var queue: CajuRenderQueue
    /// Índice do pipeline no cache de PSO (12 bits na chave).
    public var pipeline: UInt32

    public init(
        mesh: CajuRenderMeshID, material: CajuRenderMaterialID, queue: CajuRenderQueue, pipeline: UInt32
    ) {
        self.mesh = mesh
        self.material = material
        self.queue = queue
        self.pipeline = pipeline
    }
}

/// Draw list do quadro: itens visíveis ordenados por `CajuDrawKey` (radix de 64 bits, sem alocação).
public struct CajuDrawList {
    public private(set) var items: [CajuDrawItem]
    private var scratch: [CajuDrawItem]
    private var counts = [Int](repeating: 0, count: 256)
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        items = []
        scratch = []
        items.reserveCapacity(self.capacity)
        scratch.reserveCapacity(self.capacity)
    }

    /// Monta a lista: *cull* por frustum e máscara de camada, resolução na residência (`resolve` devolve
    /// `nil` para o que ainda não está na GPU) e ordenação.
    public mutating func build(
        from world: CajuRenderWorld, view: CajuRenderView,
        resolve: (CajuAssetHandle<CajuMeshAsset>, CajuAssetHandle<CajuMaterialAsset>) -> CajuResolvedDraw?
    ) throws(CajuRenderError) {
        items.removeAll(keepingCapacity: true)
        let frustum = CajuFrustum(viewProjection: view.viewProjection)
        for i in 0..<world.count {
            guard world.layerMasks[i] & view.layerMask != 0 else { continue }
            let bounds = world.worldBounds[i]
            if let frustum, !frustum.intersects(bounds) { continue }
            guard let resolved = resolve(world.meshes[i], world.materials[i]) else { continue }
            guard items.count < capacity else { throw .capacityExceeded(.drawItems) }
            let center = (bounds.min + bounds.max) * 0.5
            let depth = (center - view.position).length
            items.append(
                CajuDrawItem(
                    key: CajuDrawKey(
                        queue: resolved.queue, pipeline: resolved.pipeline, material: resolved.material.index,
                        depth: depth),
                    mesh: resolved.mesh, material: resolved.material, instanceIndex: UInt32(i)))
        }
        sort()
    }

    /// Só para testes: troca os itens por chaves avulsas.
    mutating func replaceForTesting(_ keys: [CajuDrawKey]) {
        items.removeAll(keepingCapacity: true)
        for (i, key) in keys.enumerated() {
            items.append(CajuDrawItem(key: key, mesh: .null, material: .null, instanceIndex: UInt32(i)))
        }
    }

    /// Ordena por chave: radix LSD de 8 bits (8 passes), estável, no buffer de trabalho reservado.
    public mutating func sort() {
        let n = items.count
        guard n > 1 else { return }
        if scratch.count < n {
            scratch.append(contentsOf: repeatElement(items[0], count: n - scratch.count))
        }
        items.withUnsafeMutableBufferPointer { a in
            scratch.withUnsafeMutableBufferPointer { b in
                counts.withUnsafeMutableBufferPointer { counts in
                    var source = a
                    var destination = b
                    for pass in 0..<8 {
                        let shift = UInt64(pass * 8)
                        for i in 0..<256 { counts[i] = 0 }
                        for i in 0..<n { counts[Int((source[i].key.bits >> shift) & 0xFF)] += 1 }
                        var total = 0
                        for i in 0..<256 {
                            let c = counts[i]
                            counts[i] = total
                            total += c
                        }
                        for i in 0..<n {
                            let digit = Int((source[i].key.bits >> shift) & 0xFF)
                            destination[counts[digit]] = source[i]
                            counts[digit] += 1
                        }
                        swap(&source, &destination)
                    }
                    // 8 passes (par): o resultado volta para `items`.
                }
            }
        }
    }
}
