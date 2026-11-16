# CajuRender

Renderização: mundo de render separado, extração a partir do ECS, *frame graph* de cena, draw list, materiais e luz.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** R-1 (Onda 1), dividida em R-1a e R-1b.
- **Estado:** **R-1a implementada** ([ADR 0023](../../docs/adr/0023-mundo-de-render-e-extracao.md)): assets de render em CPU (`CajuMeshAsset`, `CajuMaterialAsset`, `CajuTextureAsset`, cubo e esfera procedurais), componentes `CajuRenderMesh` (ID 8), `CajuCamera` (ID 10), `CajuDirectionalLightSource` (ID 11), `CajuRenderWorld` com extração cheia, `CajuDrawList` (cull + radix), `CajuSceneRenderer` (residência, PSO em memória, passe `main` MSAA, `unlit` e PBR com uma luz) e o golden de cena `CajuSceneGolden`. R-1b (sombra, instancing, skinning) ainda não.

## Uso por quadro
```swift
let render = CajuRenderWorld(capacity: 4096)
let renderer = try CajuSceneRenderer(device: device, colorFormat: swapchain.format)
// fim do quadro de jogo, depois da propagação de transforms:
try render.extract(from: world, assets: assetServer)
try renderer.prepare(world: render, assets: assetServer)        // eventos de asset + uploads sob orçamento
var commands = try device.queue.makeCommandBuffer(label: "quadro")
try renderer.record(world: render, into: &commands, target: image.texture, width: image.width, height: image.height)
```

## Contrato em uma página
1. **Extração:** no fim do quadro, copia do ECS (`CajuGlobalTransform` + `CajuRenderMesh`) para o mundo de render; o desenho nunca lê o ECS.
2. **Draw list:** vetor de `CajuDrawItem` ordenado por `CajuDrawKey` (fila | pipeline | material | profundidade); opacos frente-para-trás, `blend` trás-para-frente.
3. **Frame graph de cena:** `shadow` (R-1b) → `main` (forward + MSAA transitório) → UI → *backbuffer*, sobre o `CajuFrameGraphBuilder` do RHI.
4. **A-1:** `CajuRender` (depois de PR de pacote) depende de `CajuAssets` (que nunca importa RHI nem Render) e é dono da residência na GPU: a extração consulta o servidor na thread de jogo e copia o valor de CPU; eventos de asset (`drainEvents`) criam e descartam recursos; upload sob orçamento; substituto enquanto o asset carrega.
5. **AN-1:** R-1b recebe `CajuSkinPose` (referência a uma pose em espaço do modelo, em `CajuScene`) e aplica o `inverseBind` da malha.

## Divisão
- **R-1a:** extração, unlit/PBR simples, luz direcional, câmera, cull, PSO em memória.
- **R-1b:** 1 sombra, instancing, skinning, PSO persistido.

## Limites conhecidos
Uma luz direcional, sem IBL, sem luzes pontuais, sem *blend shapes*; metas de desempenho `(?)` (ver `docs/standards/performance.md`).

## Shaders
`Shaders/CajuRender/scene.{vert,frag}` (GLSL) → `scripts/compile-scene-shaders.sh` → `CajuSceneShaderSPIRV.swift` (gerado). O MSL equivalente fica em `CajuSceneShaderMSL.swift` (mudanças valem para os dois até o Slang). Ligações: vértice `setBytes(index: 0)` = objeto, fragmento `setBytes(index: 0)` = material e luz, textura/sampler 0 = cor base.

## Dependências
- `CajuCore`, `CajuMath`, `CajuRHI`, `CajuScene`, `CajuAssets`

## Como testar
- `swift test` na raiz: `CajuRenderContractTests`, `CajuRenderWorldTests` (extração, draw list, quadro no dispositivo null, alocação), `CajuSceneGoldenMetalTests` (golden de cena no Metal).
- Regenerar a referência do golden: `CAJU_GOLDEN_DUMP=<dir> swift test --filter CajuSceneGoldenMetal` e copiar `samples.txt` para `CajuSceneGoldenData.swift`.
- Vulkan (S22+): `Hosts/Android/scripts/run-conformance.sh` roda o mesmo golden (`sceneGoldenR1a`).
- Benchmark: `swift run -c release caju-bench` (suíte `CajuRender`).
