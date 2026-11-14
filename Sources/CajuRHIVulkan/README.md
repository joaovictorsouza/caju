# CajuRHIVulkan

Backend Vulkan do RHI (Android/Linux).

- **Camada:** 2 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** TB-Android.
- **Estado:** 1ª fatia do contrato `CajuRHI` sobre Vulkan 1.1 ([ADR 0015](../../docs/adr/0015-contrato-rhi-e-platform.md)), além do renderer inicial `CajuVulkanTriangleRenderer` validado no S22+ (Adreno 730).
- **Portabilidade:** `CajuVulkanDevice`, `CajuVulkanQueue`, `CajuVulkanCommandBuffer`, `CajuVulkanRenderEncoder`, `CajuVulkanCopyEncoder`, `CajuVulkanComputeEncoder`, `CajuVulkanSwapchain` e `CajuVulkanTriangleRenderer` ficam sob `#if os(Android)` (`import CVulkan`, [ADR 0019](../../docs/adr/0019-host-android-build-e-link.md)). `CajuVulkanTranslation`, `CajuVulkanSwapchainPlan` e `CajuVulkanError` são puros e testados no macOS/Linux.

## API implementada (1ª fatia)
- **`CajuVulkanDevice: CajuRenderDevice`** (Android):
  - Instância Vulkan 1.1 (`VK_KHR_surface`, `VK_KHR_android_surface`), seleção de GPU com fila gráfica, `capabilities` consultadas do dispositivo físico, `CajuHandlePool` geracional para handles.
  - `createBuffer` / `writeBuffer` / `destroy(_ buffer:)`: alocação `vkAllocateMemory` *host-visible* + *host-coherent* por buffer (mapeamento persistente para `.shared`; VMA fica para fatia futura).
  - `createShaderModule` / `destroy(_ shader:)`: validação e criação de `VkShaderModule` a partir de SPIR-V.
  - `createRenderPipeline` / `destroy(_ pipeline:)`: `VkPipeline` com `VkRenderPass` compatível com os attachments declarados, viewport/scissor dinâmicos e *push constants* (até 128 B via `setBytes`).
  - `createSwapchain`: entrega `CajuVulkanSwapchain`.
- **`CajuVulkanSwapchain: CajuSwapchain`** (Android):
  - `acquireNextImage() -> CajuSwapchainImage` (`~Copyable`), `recreate(_:)`, `releaseSurface()`.
  - 6 variantes de `VkRenderPass` pré-criadas para combinações de `(loadOp, storeOp)` sem alocação no caminho quente; `VK_ERROR_OUT_OF_DATE_KHR` → `.surfaceOutOfDate`, `VK_ERROR_SURFACE_LOST_KHR` → `.surfaceLost`.
- **`CajuVulkanQueue` / `CajuVulkanCommandBuffer` / `CajuVulkanRenderEncoder`** (Android):
  - 2 quadros em voo com `VkCommandBuffer`, `VkSemaphore` (`imageAvailable` por slot, `renderFinished` por imagem) e `VkFence` pré-alocados.
  - `withRenderPass` (load/store/clear), `setPipeline`, `setViewport`, `setScissor`, `setBytes` (*push constants*), `setBuffer` (vertex), `draw`, `drawIndexed`, `present(consuming:)`, `submit` e `waitUntilIdle`.
  - `withCopyPass`: `copyBuffer` via `vkCmdCopyBuffer`.
- **`CajuVulkanTranslation`** (portátil):
  - Tradução `CajuPixelFormat` ↔ `VkFormat`, `CajuVertexFormat` → `VkFormat`, `load`/`store` ops, topologia, *cull*/*winding*, *compare*, *blend*, *index type*, estágios, uso de buffer, amostras, `VkResult` → `CajuRHIError`, seleção de tipo de memória e empacotamento SPIR-V.

## Adiado nesta 1ª fatia (lança `CajuRHIError.unsupported`)
- Texturas fora da swapchain (`createTexture`, `writeTexture`, `setTexture`, `copyBufferToTexture`, `generateMipmaps`): lançam `.unsupported(.pixelFormat(...))`.
- Texturas transitórias e `memoryless` (`transientTexture`): lançam `.unsupported(.memorylessAttachments)` ou `.unsupported(.pixelFormat(...))`.
- Samplers (`createSampler`): lançam `.unsupported(.pixelFormat(.rgba8Unorm))`.
- Compute (`createComputePipeline`, `withComputePass`): lançam `.unsupported(.computePipelines)`.
- Sub-alocador VMA (buffers usam `vkAllocateMemory` dedicado nesta fatia), *validation layers*, pré-rotação da swapchain e MSAA resolve.

## Dependências
- `CajuRHI`, `CVulkan` (só Android)

## Como testar
- Host (macOS/Linux): `swift test --filter CajuRHIVulkanTests`
- Compilação cruzada Android: `ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/30.0.15729638 swift build --swift-sdk aarch64-unknown-linux-android29 --product CajuRHIVulkan`
