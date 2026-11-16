# Brief V-1: backend Vulkan do `CajuRHI`

Formato da skill `caju-track-brief`. Números marcados `(?)` não foram medidos. Trilha V-1 da [Onda 1](onda-1.md).

1. **Trilha e marco:** V-1 (Onda 1), rumo ao gate "goldens de conformidade iguais em Metal e Vulkan" e ao marco M3 em Android. Sustentada pelos ADRs 0001 (RHI próprio), 0008 (Game Thread), 0015 (contrato do RHI), 0019 (host Android) e pelo **ADR 0024** (VMA e sincronização), escrito nesta trilha.
2. **Diretórios que possuo:** `Sources/CajuRHIVulkan`, parte Android de `Sources/CajuPlatform`, `Hosts/Android`, este brief e os testes correspondentes. **Não toco:** `Sources/CajuRHI` e `Sources/CajuRHIMetal` (se o contrato precisar mudar, vai em PR de contrato separado, como manda o brief da Onda 1), `CajuRender`, `CajuUI`. `Package.swift` e CI só em PR dedicado (PR-B e PR-F abaixo).
3. **Contrato:** implementar `CajuRenderDevice`, `CajuQueue`, `CajuCommandBuffer`, encoders e `CajuSwapchain` do ADR 0015 em Vulkan, sem mudar a API pública. Entrada: o triângulo do ADR 0019 (`CajuVulkanTriangleRenderer`) vira consumidor do backend e depois some.
4. **Decisões técnicas propostas (serão fixadas no ADR 0024, a validar no S22+):**
   - **Vulkan 1.1 como piso**, `VkRenderPass` + `VkFramebuffer` em cache por descritor (sem *dynamic rendering*, que é 1.3). `memoryless` vira `LAZILY_ALLOCATED` + `TRANSIENT_ATTACHMENT` quando o dispositivo expõe o tipo de memória; `capabilities.supportsMemoryless` reflete isso.
   - **VMA** (Vulkan Memory Allocator, MIT) para buffers e imagens. *Aliasing* dos transientes do *frame graph* por `vmaCreateAliasingImage` sobre uma alocação por *slot*.
   - **Sincronização:** uma fila gráfica, 2 quadros em voo, *fence* por submissão e semáforos binários. `destroy(_:)` do contrato é imediato para o chamador, então o backend **adia a destruição** do objeto nativo até a *fence* da última submissão que pode usá-lo (fila de destruição por quadro). Layouts de imagem rastreados por textura; o backend emite as barreiras nas bordas dos passes (conservador no começo, refinado com medição).
   - **Ligação de recursos:** um único `VkPipelineLayout` com um set de *push descriptors* (`VK_KHR_push_descriptor`, com *pool* por quadro como alternativa se faltar). Mapa de *binding* por estágio (Metal tem espaço de índices por estágio, Vulkan não): buffers `0..15` vértice e `16..31` fragmento; texturas `32..47`/`48..63`; samplers `64..79`/`80..95`. `setBytes` (até 4 KB) usa um anel linear de uniformes por quadro; *push constants* ficam para o que couber em 128 B `(?)`.
   - **Shaders:** SPIR-V de Slang (uma entrada por módulo, como no Metal); os de teste vêm de GLSL via `glslc`.
   - **Swapchain:** recriação em `OUT_OF_DATE`/`SUBOPTIMAL`, `releaseSurface` ao ir para segundo plano, `recreate` com o `ANativeWindow` novo e na rotação. Primeira versão com `preTransform = IDENTITY` (o compositor gira; correto e simples); pré-rotação só se a medição de consumo mostrar ganho (ADR 0024).
   - **Conformidade:** a suíte de conformidade passa a ser genérica no dispositivo (alvo novo `CajuRHIConformance`, PR-B) e roda no Metal (testes) e no Vulkan (executável `adb shell` em `Hosts/Android`, sem janela, leitura de pixels da textura). Mesmos casos, mesmos valores esperados.
5. **Fatias e PRs (um por item, pequenos):**

   | PR | Conteúdo | Pronto quando |
   |---|---|---|
   | **A** | Este brief | revisado |
   | **B** (`Package.swift`, dedicado) | alvo C++ `CVMA` (VMA, versão fixa) condicional a Android; alvo `CajuRHIConformance`; teste de conformidade do Metal migrado | CI verde; `swift test` no Mac igual ao de antes |
   | **C** | Instância/dispositivo/fila, capacidades, handles, buffers e texturas via VMA, samplers, shaders, `writeBuffer`/`writeTexture`/`readTexture`, fila de destruição adiada, **ADR 0024** (rascunho), executável de conformidade no aparelho | casos de recurso e erros iguais ao Metal e ao null, no S22+ |
   | **D** | Pipelines, cache de *render pass*/*framebuffer*, encoders de render/copy/compute, `submit`/`waitUntilIdle`, transientes e `memoryless`, *frame graph* | **goldens de conformidade iguais ao Metal** no S22+ (marco de 2 semanas) |
   | **E** | `CajuVulkanSwapchain` (recriação, perda, rotação), host Android sobre o RHI (rotação liberada no manifesto), *validation layers* no build de depuração | triângulo/cubo pelo RHI, rotação e Home/volta sem erro de validação |
   | **F** (CI, dedicado) | job que gera o APK (`assembleDebug`) com toolchain swift.org 6.4.2 + NDK r30 | APK como artefato do CI |
   | **G** | 50 ciclos background/resume/rotação no S22+, evidências em `docs/evidencias/v1-vulkan/`, ADR 0024 final, docs sincronizados | ΔRSS ≤ 1 MB, zero erro de validação |

6. **Riscos e kill-criteria:**
   - **Estouro de prazo:** se passar de 2 semanas (a partir de 2026-11-15) sem os goldens, sinalizar ao dono para reavaliar o ADR 0001 (brief da Onda 1, §6).
   - **Sem validation layers no Android do aparelho** (o Android não traz a camada; ela vem num `.so` no APK): precisa do binário oficial do Khronos para arm64 (download com aprovação do dono). Sem ela, "zero erro de validação" não é verificável; plano B é validar a mesma suíte no Mac via MoltenVK com a camada do Vulkan SDK (`/usr/local/lib/libVkLayer_khronos_validation.dylib` já existe).
   - **`LAZILY_ALLOCATED` ausente ou lento no Adreno 730** `(?)`: cai para `memoryless` = textura comum de vida curta (perde só economia de memória).
   - **`VK_KHR_push_descriptor` ausente `(?)`:** *pool* de sets por quadro.
   - **Contrato do RHI insuficiente** (subpass explícito, dependências externas): abrir PR de contrato e atualizar o ADR 0015, sem mexer no Metal sozinho.
   - **Swift/NDK:** o `swift build` completo para Android usa o toolchain swift.org 6.4.2 (`TOOLCHAINS=org.swift.642202610261a`); o toolchain do Xcode precisa do link manual de `build-native.sh`.
7. **Documentos que vou atualizar:** ADR 0024 + `docs/adr/README.md`, plano (§8 "Onda 1" e estado do Vulkan), `docs/standards/performance.md` e `testes.md` (quando houver medição), READMEs de `CajuRHIVulkan`, `CajuPlatform` e `Hosts/Android`, `docs/evidencias/v1-vulkan/`.
8. **Pré-requisitos:** TB-Android entregue (triângulo no S22+) e S-0 com a linha de base de Android (PR #23). Pedidos ao dono: ver o PR A.
