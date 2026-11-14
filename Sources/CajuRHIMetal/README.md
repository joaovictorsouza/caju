# CajuRHIMetal

Backend Metal do RHI (iOS, macOS). Implementa `CajuRenderDevice` ([ADR 0015](../../docs/adr/0015-contrato-rhi-e-platform.md)); compila só onde `Metal` existe (`#if canImport(Metal)`), então Linux e Android ignoram o módulo.

- **Camada:** 2. **Trilha dona:** TB-2. **Estado:** entregue (Fase 2/3): render pass com `load`/`store`/`resolve`, MSAA e texturas `memoryless`, frame graph, *swapchain* sobre `CAMetalLayer` (`recreate`/`releaseSurface`), uploads (`writeBuffer`; `writeTexture` com *staging* em texturas privadas), compute e cópias.
- **Convenções:** fluxo de vértices `i` do RHI vira o slot Metal `30 - i`; uniformes e texturas usam o índice do shader. Shaders de produção entram como `.metalLibrary` (Slang → MSL → metallib offline); `.metalSource` só para testes.
- **Limites conhecidos:** transientes com memória usam uma textura própria por `(slot, descritor)`; **aliasing por heap (`MTLHeap` com placement e fences) está pendente** `(?)`. Hoje a economia real vem do `memoryless` (MSAA e profundidade da demo não ocupam memória). `readTexture` serve a testes e *goldens*.
- **Diagnóstico:** `liveResourceCount`, `transientTextureCount`, `allocatedBytes`.

## Dependências
`CajuRHI`.

## Como testar
`swift test` na raiz roda `Tests/CajuModulesTests/CajuMetalTests.swift` (conformidade contra o backend null, golden MSAA, frame graph, 50 ciclos de superfície com ΔRSS) em Macs com GPU; sem device Metal os testes são pulados.
