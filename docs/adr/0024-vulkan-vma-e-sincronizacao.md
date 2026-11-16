# ADR 0024: Backend Vulkan do `CajuRHI`: VMA, ligação de recursos, layouts e swapchain

**Status:** Aceito (V-1, Onda 1; 2026-11-15). Substitui a parte de **link manual** do [ADR 0019](0019-host-android-build-e-link.md); o resto do 0019 segue valendo.

## Contexto
O contrato do RHI (ADR 0015) nasceu com cara de Metal: recursos ligados por índice e estágio, sem barreiras, `destroy` imediato, `memoryless`, NDC com y para cima e origem da textura no canto superior esquerdo. O backend Vulkan precisa entregar os **mesmos goldens de conformidade** do Metal no Galaxy S22+ (Adreno 730, Vulkan 1.1 como piso; ADR 0007) sem mudar a API pública, e sobreviver a rotação e Home/volta sem vazamento nem erro de validação.

## Decisão
- **Piso Vulkan 1.1**, uma fila gráfica, sem *dynamic rendering*: `VkRenderPass` e `VkFramebuffer` em cache por chaves de tamanho fixo (até 4 cores, 4 *resolves* e profundidade), sem alocar por quadro. Um subpasse por passe; o pipeline é criado contra um *render pass* compatível (só formatos e amostras contam).
- **Memória pelo VMA 3.5.0** (`CVMA`, vendorizado). `memoryless` = `LAZILY_ALLOCATED` + `TRANSIENT_ATTACHMENT` quando o tipo de memória existe (existe no Adreno 730); `capabilities.supportsMemoryless` reflete isso. *Aliasing* de transientes do *frame graph* fica para depois (hoje cada transiente tem memória própria).
- **Destruição adiada:** `destroy(_:)` invalida o handle na hora; o objeto nativo vai para uma fila marcada com a série da última submissão e só é destruído quando a *fence* dela termina. *Fence* por submissão, *command buffers* reaproveitados. O `deinit` do dispositivo libera tudo o que ainda está vivo antes do alocador (o VMA aborta se sobrar alocação).
- **Ligação de recursos:** mapa por estágio no set 0 (buffers `0..15` vértice e `16..31` fragmento, texturas `32..47`/`48..63`, samplers `64..79`/`80..95`). Em vez de um layout fixo com 96 *bindings* (estoura `maxPushDescriptors`, mínimo 32), **cada pipeline lê os *bindings* do SPIR-V** (`CajuVulkanShaderReflection`, reflexão mínima em Swift, testada no host) e monta o layout só com o que usa, ligado por **`VK_KHR_push_descriptor`** a cada *draw* com mudança. `sampler2D` de GLSL usa o sampler do mesmo índice e estágio. Plano B sem a extensão (pool de sets por submissão) não foi implementado: o Adreno 730 tem a extensão; sem ela, `createRenderPipeline` falha com `.backend(code:)`.
- **`setBytes`:** anel de uniformes de 4 MB (`HOST_VISIBLE | HOST_COHERENT`, mapeado), sub-alocado em sequência e marcado por submissão; só espera a GPU se o anel inteiro estiver em uso.
- **Layouts sem barreiras no contrato:** cada textura tem um **layout de repouso** (amostrável em `SHADER_READ_ONLY_OPTIMAL`, *swapchain* em `PRESENT_SRC`, attachment puro em `*_ATTACHMENT_OPTIMAL`). Cópias e passes terminam no repouso, então `setTexture` dentro do passe não precisa de barreira. Attachments com `load` são levados ao layout de attachment antes do passe; os demais entram como `UNDEFINED`. Dependências externas conservadoras nos dois lados do subpasse (refinar com medição).
- **Coordenadas:** viewport com altura negativa (núcleo no 1.1): NDC com y para cima e origem em cima, como no Metal; com isso o sentido (`frontFace`) também casa sem troca.
- **Swapchain:** FIFO, 2 quadros em voo (semáforo de aquisição por quadro, reusado só após a *fence*; semáforo de fim de render por imagem). **`preTransform = IDENTITY`** na v1: o compositor gira; o tamanho é o lógico da janela (`ANativeWindow_getWidth/Height`, porque `currentExtent` vem na orientação nativa e às vezes atrasado logo após girar). O `SUBOPTIMAL` que o Android devolve com a rotação diferente é esperado e ignorado; `OUT_OF_DATE` vira `.surfaceOutOfDate`. `releaseSurface` solta superfície, cadeia e imagens; o resto do dispositivo sobrevive. A plataforma também trata `onConfigurationChanged` como redimensionamento (nem todo aparelho chama `onNativeWindowResized` ao girar).
- **Camada de validação:** binário oficial do Khronos `vulkan-sdk-1.4.363.1` (só arm64, hash conferido com o *digest* do GitHub) baixado por `Hosts/Android/scripts/fetch-validation-layer.sh` e empacotado só no APK de depuração (`CAJU_VALIDATION=1`). O dispositivo liga a camada quando ela existe (`enableValidation`) e conta as mensagens: **só as que têm id do Khronos (`VUID-…`, `UNASSIGNED-…`) contam como erro**; o driver Adreno manda dicas próprias pelo mesmo canal (ex.: `VKDBGUTILWARN003`, multipass) marcadas como erro de validação, e elas contam como aviso.
- **Build:** `swift build --product` com o toolchain do swift.org 6.4.2 liga direto para Android (inclusive o alvo C++ do VMA) e passa a ser pré-requisito de `build-native.sh` e do executável de conformidade; o link manual do ADR 0019 sai.
- **Conformidade:** a mesma suíte (`CajuRHIConformance`) roda no Metal (`swift test`) e no Vulkan (`Hosts/Android/scripts/run-conformance.sh`, executável sem janela por `adb shell`).

## Alternativas
- Layout fixo de 96 *bindings* com pool por quadro: mais simples de ligar, mas aloca sets por *draw* e reserva descritores que não usa.
- Gravar o passe numa lista própria e emitir barreiras exatas antes de começar o `VkRenderPass`: mais preciso, mas uma cópia de todo comando gravado; o layout de repouso resolve o caso comum sem isso.
- Pré-rotação (`preTransform = currentTransform`): economiza a rotação do compositor, mas exige girar a projeção em toda a engine; só se a medição de consumo mostrar ganho.
- *Dynamic rendering* (1.3): fora do piso 1.1.

## Consequências
- Goldens de conformidade iguais ao Metal no S22+ (6/6; `docs/evidencias/v1-vulkan/`), antes do prazo de 2026-11-29: o ADR 0001 não precisa ser reaberto.
- A camada de validação aponta um aviso de boa prática por recriação (`preTransform` diferente de `currentTransform`), esperado por esta decisão.
- A reflexão exige `binding` explícito no shader, dentro do mapa; arrays de recursos e sets diferentes de 0 são rejeitados.
- O toolchain do swift.org vira pré-requisito do host Android (já era do CI do APK).

## Quando reabrir
Aparelho de referência sem `VK_KHR_push_descriptor` (implementar o plano B); medição de consumo mostrando ganho com pré-rotação; dependências externas conservadoras aparecendo no perfil do Adreno; contrato do RHI ganhando barreiras ou subpasses explícitos (ADR 0015).
