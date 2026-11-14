# CajuRHIVulkan

Backend Vulkan do RHI (Android/Linux).

- **Camada:** 2 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** TB-Android.
- **Estado:** primeiro marco do TB-Android. `CajuVulkanTriangleRenderer` desenha um triângulo girando em Vulkan 1.1 sobre uma `ANativeWindow` (S22+, Adreno 730). **Ainda não implementa o contrato `CajuRHI`** (ADR 0015): é um renderer específico que valida instância, dispositivo, swapchain, render pass, pipeline e sincronização no aparelho. O backend `CajuRHI` vem depois, reaproveitando estas peças.
- **Só no Android:** o renderer fica sob `#if os(Android)` e usa o `CVulkan` ([ADR 0019](../../docs/adr/0019-host-android-build-e-link.md)). `CajuVulkanSwapchainPlan` (escolha de contagem de imagens, extensão e formato) e `CajuVulkanError` são puros e testados no host.

## API
- `CajuVulkanTriangleRenderer`: `init()` cria a instância; `attach(window:)` cria superfície, dispositivo (1ª vez) e swapchain; `drawFrame()` (FIFO, 2 quadros em voo, sem alocação de heap); `resize()`; `detach()` (idempotente). Tudo na Game Thread.
- Erros tipados `CajuVulkanError` (`throws(CajuVulkanError)`): sem `!`/`fatalError`.
- Shaders: `Hosts/Android/shaders/*.vert|frag` → `scripts/compile-shaders.sh` → `CajuVulkanTriangleShaders.swift` (gerado).

## Fora do escopo deste marco
VMA (o triângulo não tem buffers), *validation layers*, pré-rotação da swapchain (o manifesto fixa retrato), MSAA e *frame graph*.

## Dependências
- `CajuRHI`, `CVulkan` (só Android)

## Como testar
`swift test --filter CajuRHIVulkanTests` (partes puras, no host). No aparelho: `Hosts/Android/README.md`.
