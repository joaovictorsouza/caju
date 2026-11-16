import CajuAssets
import CajuMath
import CajuRHI

/// Golden de cena da R-1, igual em todo backend (Metal nos testes, Vulkan no aparelho): cubo `unlit`
/// vermelho girado à esquerda, esfera PBR azulada à direita e chão cinza com a sombra delas (R-1b), luz
/// direcional e ambiente, 64x64, MSAA 4x.
///
/// A referência (`CajuSceneGoldenData.samples`) foi gravada do Metal; os outros backends têm de bater nela
/// dentro da tolerância. Pontos exatos (fundo e centro do cubo `unlit`) não têm tolerância.
public enum CajuSceneGolden {
    public static let side = 64
    /// Grade de amostras: a cada `stride` pixels a partir de `stride / 2` (16 × 16 = 256 pontos).
    public static let gridStep = 4
    /// Diferença máxima por canal (0–255) num ponto da grade.
    public static let tolerance = 8
    /// Pontos que podem passar da tolerância (bordas com MSAA e rasterização diferente por GPU).
    public static let allowedOutliers = 6
    public static let clear = CajuColor(r: 0.05, g: 0.05, b: 0.08)

    /// Desenha a cena num alvo `bgra8Unorm` `shared` e devolve os bytes (BGRA, linha a linha).
    public static func render<Device: CajuRenderDevice>(
        device: Device, read: (CajuTextureHandle) throws(CajuRHIError) -> [UInt8]
    ) throws(CajuRenderError) -> [UInt8] {
        let assets = GoldenAssets()
        let cube = assets.put(CajuMeshAsset.cube(size: 1))
        let sphere = assets.put(CajuMeshAsset.sphere(radius: 0.55, segments: 48, rings: 24))
        let red = assets.put(CajuMaterialAsset(model: .unlit, baseColor: CajuColor(r: 1, g: 0, b: 0)))
        let blue = assets.put(
            CajuMaterialAsset(
                model: .pbr, baseColor: CajuColor(r: 0.2, g: 0.5, b: 1), metallic: 0, roughness: 0.4))

        let ground = assets.put(CajuMeshAsset.plane(size: 6))
        let grey = assets.put(CajuMaterialAsset(baseColor: CajuColor(r: 0.6, g: 0.6, b: 0.6), roughness: 0.9))
        let world = CajuRenderWorld(capacity: 4)
        world.camera = (
            .translation(CajuVec3(0, 0, 3)),
            CajuCamera(fovY: .pi / 3, near: 0.1, far: 20, clearColor: clear)
        )
        world.light = CajuDirectionalLight(
            direction: CajuVec3(0.5, -1, 0.6).normalized() ?? CajuVec3(0, -1, 0), intensity: 3,
            castsShadow: true)
        world.ambient = CajuColor(r: 0.05, g: 0.05, b: 0.05)
        let spin =
            (CajuQuat(axis: CajuVec3(0, 1, 0), radians: 0.6) ?? .identity)
            * (CajuQuat(axis: CajuVec3(1, 0, 0), radians: 0.4) ?? .identity)
        try world.append(
            world: .translation(CajuVec3(-0.75, 0, 0)) * .rotation(spin),
            localBounds: CajuMeshAsset.cube().bounds,
            mesh: cube, material: red)
        try world.append(
            world: .translation(CajuVec3(0.75, 0, 0)), localBounds: CajuMeshAsset.sphere(radius: 0.55).bounds,
            mesh: sphere, material: blue)
        // Chão que recebe a sombra (R-1b) e não projeta.
        try world.append(
            world: .translation(CajuVec3(0, -0.7, 0)), localBounds: CajuMeshAsset.plane(size: 6).bounds,
            mesh: ground,
            material: grey, castsShadow: false)

        let renderer = try CajuSceneRenderer(device: device, colorFormat: .bgra8Unorm, sampleCount: 4)
        try renderer.prepare(world: world, assets: assets)
        let target: CajuTextureHandle
        do {
            target = try device.createTexture(
                CajuTextureDescriptor(
                    format: .bgra8Unorm, width: side, height: side,
                    usage: [.renderTarget, .sampled, .copySource],
                    storage: .shared, label: "golden"))
        } catch {
            throw .rhi(error)
        }
        do {
            var commands = try device.queue.makeCommandBuffer(label: "golden")
            try renderer.record(world: world, into: &commands, target: target, width: side, height: side)
            try device.queue.submit(commands)
            try device.queue.waitUntilIdle()
            let bytes = try read(target)
            device.destroy(target)
            return bytes
        } catch let error as CajuRenderError {
            throw error
        } catch {
            throw .rhi(error as? CajuRHIError ?? .outOfMemory)
        }
    }

    /// Amostras da grade (BGRA por ponto) de uma imagem 64x64.
    public static func samples(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity((side / gridStep) * (side / gridStep) * 4)
        for y in stride(from: gridStep / 2, to: side, by: gridStep) {
            for x in stride(from: gridStep / 2, to: side, by: gridStep) {
                let i = (y * side + x) * 4
                result += bytes[i..<i + 4]
            }
        }
        return result
    }

    /// Compara uma imagem com a referência; devolve os problemas (vazio = passou).
    public static func check(_ bytes: [UInt8], reference: [UInt8] = CajuSceneGoldenData.samples) -> [String] {
        guard bytes.count == side * side * 4 else { return ["tamanho \(bytes.count)"] }
        var problems: [String] = []
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            Array(bytes[(y * side + x) * 4..<(y * side + x) * 4 + 4])
        }
        let background: [UInt8] = [
            UInt8((clear.b * 255).rounded()), UInt8((clear.g * 255).rounded()),
            UInt8((clear.r * 255).rounded()), 255,
        ]
        if pixel(1, 1) != background { problems.append("fundo em (1,1): \(pixel(1, 1)) ≠ \(background)") }
        if pixel(18, 32) != [0, 0, 255, 255] { problems.append("cubo unlit em (18,32): \(pixel(18, 32))") }
        let actual = samples(bytes)
        guard actual.count == reference.count else {
            return problems + ["referência com \(reference.count / 4) pontos, imagem com \(actual.count / 4)"]
        }
        var outliers: [String] = []
        let perRow = side / gridStep
        for point in 0..<(actual.count / 4) {
            var worst = 0
            for c in 0..<4 {
                worst = max(worst, abs(Int(actual[point * 4 + c]) - Int(reference[point * 4 + c])))
            }
            if worst > tolerance {
                let x = (point % perRow) * gridStep + gridStep / 2
                let y = (point / perRow) * gridStep + gridStep / 2
                outliers.append(
                    "(\(x),\(y)) \(Array(actual[point * 4..<point * 4 + 4])) ≠ \(Array(reference[point * 4..<point * 4 + 4]))"
                )
            }
        }
        if outliers.count > allowedOutliers {
            problems.append(
                "\(outliers.count) pontos fora da tolerância: " + outliers.prefix(8).joined(separator: ", "))
        }
        return problems
    }
}

/// Servidor de assets mínimo para o golden: valores fixos, sem carga nem eventos.
final class GoldenAssets: CajuAssetServing {
    private var values: [CajuAnyAssetHandle: any CajuAsset] = [:]
    private var next: UInt32 = 0

    func put<A: CajuAsset>(_ value: A) -> CajuAssetHandle<A> {
        let handle = CajuAssetHandle<A>(index: next, generation: 1)
        next += 1
        values[handle.erased] = value
        return handle
    }

    func load<A: CajuAsset>(_ type: A.Type, path: CajuAssetPath) -> CajuAssetHandle<A> { .invalid }
    func state<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetState {
        values[handle.erased] == nil ? .stale : .loaded
    }
    func value<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> A? { values[handle.erased] as? A }
    func error<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> CajuAssetError? { nil }
    func revision<A: CajuAsset>(of handle: CajuAssetHandle<A>) -> UInt32 { 1 }
    func retain<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool { true }
    func release<A: CajuAsset>(_ handle: CajuAssetHandle<A>) -> Bool { true }
    func reload(path: CajuAssetPath) {}
    func applyCompletions() {}
    func drainEvents(_ body: (CajuAssetEvent) -> Void) {}
}
