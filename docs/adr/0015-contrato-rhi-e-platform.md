# ADR 0015: Contrato do RHI e da Platform (TB-2, Fase 1)

**Status:** Aceito (implementa o ADR 0001; não o substitui).

## Contexto
A TB-Android precisa do contrato do `CajuRHI` para escrever o backend Vulkan enquanto a TB-2 escreve o Metal. O contrato é desenhado para Metal e Vulkan juntos (ADR 0001) e precisa respeitar o piso iOS 17 / Android API 29 (ADR 0007) e a política de Foundation (ADR 0005).

## Decisão
- **Genérico, sem `any`:** `CajuRenderDevice`, `CajuQueue` e `CajuCommandBuffer` têm tipos associados (fila, *swapchain*, encoders); o código de render é genérico no dispositivo. Dispositivo e fila **não são `Sendable`**: pertencem à thread de jogo (ADR 0008). O que cruza threads são valores `Sendable` (descritores, handles, `CajuSurfaceDescriptor`).
- **Handles numéricos** `CajuHandle<Tag>` (índice + geração, 8 bytes); handle antigo falha com `.invalidHandle`. `CajuHandlePool` é a tabela geracional reutilizável pelos backends.
- **`~Copyable` onde há protocolo de uso único:** command buffer, encoders e `CajuSwapchainImage` (apresentar duas vezes não compila). Encoders vivem dentro de *closures* (`withRenderPass`) e não escapam do passe; erros de gravação são acumulados e lançados no fim do passe (`throws(CajuRHIError)`).
- **Erros tipados** `CajuRHIError` com payload numérico/enumerado (sem `String` formatada no caminho de erro).
- **Render pass é a unidade:** attachments com `load`/`store`/`resolve`; `memoryless` é modo de armazenamento de textura, válido só para attachment de um passe com carga `clear`/`dontCare` e armazenamento `dontCare`/`resolve` (`TransientAttachment`). Pipeline traz profundidade, máscaras e amostras (estilo Vulkan), o que permite cache de PSO.
- **Frame graph em dois tempos:** `CajuFrameGraphBuilder` (declaração, pura, sem GPU) → `compile(capabilities:)` (corte de passes sem saída, lifetimes, decisão `memoryless` automática e aliasing por *slots* com coloração gulosa) → `CajuFrameGraphExecutor` (sem alocação no estado estável). A ordem dos passes é a da declaração (sem reordenação nesta fase). O backend recebe só texturas concretas; `.resource` do grafo é resolvido pelo executor.
- **Upload:** `writeBuffer`/`writeTexture` usam `UnsafeRawBufferPointer`, **não `Span`** (a `Span` da stdlib exige iOS 26 em runtime, contra o piso iOS 17); revisar quando o piso subir. `CajuUploadBudget` limita bytes por quadro.
- **Swapchain** com `recreate`/`releaseSurface`; perda aparece como `.surfaceOutOfDate`/`.surfaceLost` e nunca derruba o dispositivo.
- **Superfície como inteiro:** `nativeHandle: UInt` mantém `CajuSurfaceDescriptor` `Sendable` sem `@unchecked`. `CajuPlatform` não depende de `CajuRHI` (mapa de camadas): `CajuPlatformSurface` e `CajuSurfaceDescriptor` são tipos paralelos e a camada de render (ou o host) os converte.
- **Platform:** `CajuLifecycleState` (máquina de estados com eventos duplicados tolerados), `CajuEventQueue` (anel fixo que nunca perde evento de ciclo de vida), `CajuMainLoop` (valor puro e testável sem plataforma: relógio manual, *delta* zerado depois do segundo plano, política `continuous`/`onDemand`), protocolos `CajuApplication` (lado do jogo) e `CajuPlatformHost` (lado da plataforma).
- **Backend `CajuNullDevice`** em `CajuRHI`: valida como um backend real e registra comandos; base dos testes headless e da suíte de conformidade.
- **Testes:** sem alvo novo (exigiria `Package.swift`): ficam em `Tests/CajuModulesTests`.

## Alternativas
- `any CajuDevice` e encoders classe: mais simples, mas aloca e perde a verificação em compilação.
- Encoder retornado por `beginRenderPass` (sem *closure*): permite esquecer de terminar o passe; exigiria `~Escapable`/lifetimes ainda experimentais.
- `Span` na API de upload: bloqueado pelo piso iOS 17.
- Reordenar passes por dependência: adiado (benefício pequeno com ~5 passes; aumenta a superfície de bugs).

## Consequências
- `CajuRHIVulkan` implementa os mesmos protocolos; ambos passam na mesma suíte de conformidade.
- A API de passes de render tem arrays nos descritores: a gravação por quadro não aloca no estado estável (o executor reutiliza o descritor), mas montar descritores novos aloca; medir no *benchmark* (Fase 3) `(?)`.
- Handles de textura do *swapchain* são válidos só até a apresentação.

## Estado da implementação (Fase 2 e 3 da TB-2)
- **Entregue:** `CajuRHIMetal` (render pass, `memoryless`, MSAA/resolve, frame graph, swapchain em `CAMetalLayer`), `CajuAppleHost` (UIKit/AppKit, display link, ciclo de vida), `Hosts/Apple` com shaders Slang → MSL e demo cubo + botão no simulador iPhone 17 Pro; suíte de conformidade (erros iguais no backend Metal e no null), golden MSAA, 50 ciclos de superfície com ΔRSS 0,14 MB e benchmark do frame graph (números em `docs/standards/performance.md`).
- **Slang:** `slangc` 2026.8 perde os uniformes do estágio de vértice com vários pontos de entrada num módulo; compila-se um `.metal` por entrada (`Hosts/Apple/Shaders/compile-shaders.sh`). Convenção de vértices no Metal: fluxo `i` → slot `30 - i`.
- **Pendente:** aliasing por heap no Metal (placement heap + fences; hoje só `memoryless` economiza memória de verdade) `(?)`; execução em iPhone 16 Pro e toque no botão; benchmark em `caju-bench` e linha de base de aparelho.

## Quando reabrir
Se o Vulkan exigir semântica que o contrato não expressa (subpass explícito, *render pass* com dependências externas); quando o piso de SO permitir `Span`; se o custo de `~Copyable` associado atrapalhar o tempo de compilação (medir no CI).
