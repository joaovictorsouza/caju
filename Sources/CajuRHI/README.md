# CajuRHI

Interface de abstração de GPU (RHI) para Metal e Vulkan, desenhada para os dois ao mesmo tempo (ADR 0001, [ADR 0015](../../docs/adr/0015-contrato-rhi-e-platform.md)).

- **Camada:** 2. **Trilha dona:** TB-2. **Estado:** contrato publicado (Fase 1); backends: `CajuNullDevice` (aqui), Metal (`CajuRHIMetal`), Vulkan (`CajuRHIVulkan`, TB-Android).
- **Sem Foundation**, sem `!`/`try!`/`fatalError`/`precondition`; erros tipados `throws(CajuRHIError)`.

## Peças
| Área | Tipos |
|---|---|
| Recursos | `CajuHandle<Tag>` (índice + geração), `CajuHandlePool`, `CajuBufferDescriptor`, `CajuTextureDescriptor`, `CajuSamplerDescriptor`, `CajuShaderModuleDescriptor` |
| Formatos | `CajuPixelFormat` (inclui ASTC 4x4 a 8x8), `CajuSampleCounts`, `CajuDeviceCapabilities` |
| Pipelines | `CajuRenderPipelineDescriptor` (vértices, cor, profundidade, mistura, amostras), `CajuComputePipelineDescriptor` |
| Passes | `CajuRenderPassDescriptor` com `load`/`store`/`resolve`; `memoryless` = `TransientAttachment` |
| Comandos | `CajuRenderDevice`, `CajuQueue`, `CajuCommandBuffer`, `CajuRenderEncoder`/`CajuComputeEncoder`/`CajuCopyEncoder` (tipos `Copyable`; encoders só em *closures*; `~Copyable` em tipo associado exige Swift 6.3+, ADR 0015) |
| Superfície | `CajuSurfaceDescriptor`, `CajuSwapchain` (`recreate`, `releaseSurface`), `CajuSwapchainImage` (`~Copyable`) |
| Frame graph | `CajuFrameGraphBuilder` → `compile` → `CajuCompiledFrameGraph` (corte, lifetimes, aliasing, memoryless) → `CajuFrameGraphExecutor` |
| Upload | `CajuUploadBudget` |
| Testes | `CajuNullDevice` (valida e registra comandos; injeta `surfaceOutOfDate`/`surfaceLost`) |

## Uso (esboço)
```swift
var graph = CajuFrameGraphBuilder()
let backbuffer = graph.importTexture(format: .bgra8UnormSRGB)
let msaa = graph.createTransient(
    CajuTextureDescriptor(format: .bgra8UnormSRGB, width: 1179, height: 2556, sampleCount: 4, usage: .renderTarget))
graph.addPass(CajuFrameGraphPass(name: "scene", render: CajuRenderPassDescriptor(colorAttachments: [
    CajuColorAttachment(texture: .resource(msaa), store: .resolve, resolveTexture: .resource(backbuffer))])))
let compiled = try graph.compile(capabilities: device.capabilities)  // msaa vira memoryless
```
Compile uma vez, `executor.prepare(compiled)`, e por quadro: `bind` do importado e `execute`.

## Dependências
`CajuCore`, `CajuMath`.

## Como testar
`swift test` na raiz (`Tests/CajuModulesTests/CajuRHITests.swift`, `CajuFrameGraphTests.swift`); roda em Linux e macOS sem GPU.
