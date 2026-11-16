# CajuRHIVulkan

Backend Vulkan do `CajuRHI` (Android). Decisões: [ADR 0024](../../docs/adr/0024-vulkan-vma-e-sincronizacao.md) (VMA, ligação de recursos, layouts, swapchain), [ADR 0015](../../docs/adr/0015-contrato-rhi-e-platform.md) (contrato), [ADR 0019](../../docs/adr/0019-host-android-build-e-link.md) (host).

- **Camada:** 2 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** V-1 ([brief](../../docs/briefs/v1-vulkan.md)).
- **Estado:** implementa `CajuRenderDevice`, `CajuQueue`, `CajuCommandBuffer`, encoders de render e cópia e `CajuSwapchain` em Vulkan 1.1. A suíte de conformidade (`CajuRHIConformance`) passa 6/6 no Galaxy S22+ com os mesmos valores do Metal (`docs/evidencias/v1-vulkan/`). Compute ainda não (`capabilities.supportsCompute == false`).
- **Só no Android:** o código nativo fica sob `#if os(Android)` e usa `CVulkan` + `CVMA`. `CajuVulkanSwapchainPlan` e `CajuVulkanShaderReflection`/`CajuVulkanBindingMap` são puros e testados no host.

## API
- `CajuVulkanDevice(enableSurface:enableValidation:)`: `enableSurface` liga as extensões de superfície (o executável de conformidade, sem janela, passa `false`); `enableValidation` carrega `VK_LAYER_KHRONOS_validation` se estiver no APK e expõe `validationMessageCounts`.
- Diagnóstico: `liveResourceCount`, `pendingDestructionCount`, `allocatedBytes` (VMA), `transientTextureCount`.
- `readTexture(_:)`: leitura do mip 0 de uma textura `shared` (conformidade e goldens).
- `CajuVulkanSwapchain`: FIFO, 2 quadros em voo, `preTransform = IDENTITY`, `compositorRotation` para diagnóstico.

## Ligação de recursos (shaders SPIR-V)
`binding` explícito no set 0, no espaço do contrato: buffers `0..15` (vértice) e `16..31` (fragmento), texturas `32..47`/`48..63`, samplers `64..79`/`80..95`. O fluxo de vértices usa `setVertexBuffer(index:)` = *binding* de vértice `index`. `setBytes` vira um buffer de uniforme no *binding* do índice.

## Dependências
- `CajuRHI`, `CVulkan` e `CVMA` (só Android)

## Como testar
- Host: `swift test --filter CajuRHIVulkanTests` (plano de swapchain, reflexão de SPIR-V, mapa de bindings).
- Aparelho: `Hosts/Android/scripts/run-conformance.sh` (suíte de conformidade) e `Hosts/Android/scripts/lifecycle-cycles.sh` (rotação + Home/volta com RSS e validação). Ver `Hosts/Android/README.md`.
