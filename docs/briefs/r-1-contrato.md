# R-1: contrato do mundo de render (proposta)

Formato da skill `caju-track-brief`. Base: brief da Onda 1 ([onda-1.md](onda-1.md)), ADR 0001, 0003, 0014, 0015 e o rascunho do [ADR 0023](../adr/0023-mundo-de-render-e-extracao.md). Números marcados `(?)` não foram medidos. **Este documento é o contrato publicado em PR draft; consumidores (A-1, AN-1, U-1b) só começam a depender dele depois do aceite do dono. Sem implementação de extração, sombra, instancing ou skinning neste PR.**

## 1. Trilha, dono e escopo
- **Trilha:** R-1 (Onda 1), dividida em **R-1a** (extração, unlit/PBR simples, luz direcional) e **R-1b** (1 sombra, instancing/batching, skinning).
- **Dono:** `Sources/CajuRender` (+ testes em `Tests/CajuModulesTests`, alvo existente). **Não toca:** `Package.swift`, CI, `CajuRHI*`, `CajuScene`, `CajuAssets`, `CajuAnim`.
- **Este PR:** só contrato: este documento, ADR 0023 (proposto), tipos de valor puros em `CajuRenderContract.swift` e testes da chave de ordenação.

## 2. Mundo de render separado
O render **não lê o ECS de jogo durante o desenho**. Cada quadro tem duas fases:

1. **Extração** (thread de jogo, fim do quadro, depois de `postUpdate`/`transformPropagation`): um sistema de `CajuRender` percorre as consultas do ECS e **copia** para o `CajuRenderWorld` apenas o que o desenho precisa (matriz de mundo, ids de malha/material, caixa de mundo, luz, câmera, pose). Nada do mundo de render aponta para componentes do ECS.
2. **Preparação e desenho**: o `CajuRenderWorld` faz *cull*, ordena a draw list, decide instâncias, monta o frame graph e grava no `CajuCommandBuffer`. Só lê o que a extração copiou.

Por que separar: (a) o mundo de jogo pode avançar para o próximo quadro enquanto o desenho do anterior ainda grava (o ADR 0008 já reserva a thread de jogo; o pipeline em dois quadros fica para depois `(?)`); (b) o render passa a depender de dados lineares e contíguos, não de arquétipos; (c) testes headless do render sem ECS (alimentar o mundo de render na mão).

Regras do `CajuRenderWorld` (valor, `~Escapable` não é exigido; não é `Sendable`, pertence à thread de jogo como o dispositivo):
- Capacidade reservada na criação; no quadro estável **nenhuma alocação** (verificação por SIL/instrumentação, `performance.md` regra 1). Estouro de capacidade é erro tipado `CajuRenderError.capacityExceeded(kind:)`, nunca crescimento silencioso no caminho quente.
- Dados em colunas (SoA): matrizes, caixas, ids em arrays paralelos; índice de instância estável dentro do quadro.
- Extração incremental: R-1a começa **cheia por quadro** (copia tudo que é visível ao ECS); extração por diferença (só `CajuGlobalTransform` alterado) entra se o benchmark mostrar custo `(?)`.

## 3. Entidade extraível
Uma entidade é desenhada se tiver `CajuGlobalTransform` (CajuScene) e `CajuRenderMesh` (componente novo de `CajuRender`, ID de componente **8**, confirmado livre pelo dono):

| Componente | Conteúdo |
|---|---|
| `CajuRenderMesh` | `mesh: CajuAssetHandle<mesh>`, `material: CajuAssetHandle<material>`, `layerMask: UInt32`, `castsShadow: Bool` |
| `CajuCamera` (R-1a) | projeção (perspectiva/ortográfica), planos, `viewport`; a matriz de vista vem do `CajuGlobalTransform` |
| `CajuDirectionalLight` (valor do contrato; componente em R-1a) | direção, cor, intensidade, `castsShadow` |
| `CajuSkinPose` (R-1b, vive em `CajuScene`, ID 9 `(?)`) | ver §7.2 |

`CajuRenderMeshID` e `CajuRenderMaterialID` são handles geracionais (`CajuHandle<Tag>`, ADR 0015) **do mundo de render** (posições no cache de residência); a ponte com `AssetServer` está no §7.1.

## 4. Frame graph de cena
O `CajuFrameGraphBuilder` do RHI (ADR 0015) já cuida de passes, transientes e aliasing. R-1 declara o grafo **de cena** em cima dele:

```
shadow (R-1b) ──depth──▶ main (forward, MSAA transitório, resolve) ──▶ [UI (U-1b)] ──▶ backbuffer
```
- **Forward com MSAA** (plano §4): cor e profundidade MSAA são `transient` (`memoryless` em Apple GPU quando o passe é único); resolve para o *backbuffer* importado.
- **Passe `shadow`** (R-1b): só profundidade, mapa único (cascata única); lido como textura amostrada pelo passe `main`. Só existe se a luz tem `castsShadow` e há receptor.
- **Passe de UI** fica em `CajuUI` (U-1b), que **declara seu passe no mesmo grafo**: `CajuRender` expõe `CajuSceneGraphHandles` (recursos `backbuffer`, `sceneColor`) para a UI se pendurar depois do `main`. Contrato fino de U-1b fica no ADR 0026; aqui só se reserva o ponto de encaixe.
- A topologia muda só quando muda a configuração (ligar sombra, trocar MSAA): **compila-se uma vez e reusa** (como no executor do RHI); mudança de topologia recompila fora do quadro estável.
- Ordem dos passes = ordem de declaração (ADR 0015); sem reordenação.

## 5. Formato da draw list
Draw list = vetor reservado de `CajuDrawItem` (valor, sem referência), ordenado por `CajuDrawKey` de 64 bits (`CajuRenderContract.swift`):

```
63..60 fila (shadow=0, opaque=1, mask=2, blend=3)
59..48 pipeline (12 bits, índice no cache de PSO)
47..32 material (16 bits)
31..0  profundidade (bits do Float, 31 bits úteis; invertida em `blend`)
```
- Opacos e *mask*: agrupados por pipeline → material, depois frente-para-trás (menos *overdraw*). `blend`: trás-para-frente.
- `CajuDrawItem` = chave + `mesh` + `material` + `instanceIndex` (posição da matriz na tabela de instâncias do quadro) + `poseIndex` (R-1b; `noPose` = `UInt32.max`).
- **Instancing (R-1b):** itens consecutivos com mesma `(mesh, material, pipeline)` viram **um** `drawIndexed(instanceCount:)`; as matrizes ficam num buffer por quadro lido pelo vértice por `instanceIndex`. Em Metal e Vulkan o buffer é `storage`/`uniform` conforme `capabilities` (ADR 0015: modos equivalentes).
- **Orçamento:** ≤ 300 draw calls por quadro (`performance.md`); a UI tem o seu (≤ 40).
- **Ordenação:** radix de 64 bits sobre a coluna de chaves, sem alocação (buffer de trabalho reservado); a função de comparação (`<`) do contrato serve de oráculo nos testes.

## 6. Luz e material (R-1a)
- **Materiais:** `CajuMaterialModel.unlit` (cor base × textura) e `.pbr` (base color, metálico/rugosidade, normal, emissivo; sem IBL no MVP, ambiente por cor/hemisfério `(?)`). `CajuMaterialParams` em espaço linear; texturas ausentes usam o escalar.
- **PSO:** um pipeline por `(modelo, alphaMode, doubleSided, formato de vértice, amostras)`; cache em memória em R-1a, persistido em R-1b/V-1 (ADR 0001: nenhum quadro > 50 ms por compilação de pipeline: pipelines do cenário de referência são pré-compiladas na carga).
- **Luz:** **uma** `CajuDirectionalLight` por cena no MVP (a de maior intensidade se houver várias, escolha determinística por índice) + cor ambiente. Sem luzes pontuais/spot no MVP.
- **Shaders:** Slang → MSL/SPIR-V offline (ADR 0001); a variação unlit/PBR é por *specialization/permutação* escolhida no PSO, não por ramo dinâmico.

## 7. R-1a e R-1b e o que cada uma exige de A-1 e AN-1

| | **R-1a** (extração + unlit/PBR + luz) | **R-1b** (sombra + instancing + skinning) |
|---|---|---|
| Entrega | `CajuRenderWorld`, extração cheia, `CajuCamera`, materiais unlit/PBR, luz direcional, frame graph `main` com MSAA, cull por frustum, draw list ordenada, cache de PSO em memória, golden Metal (cubo unlit, esfera PBR) | passe `shadow` (mapa único, PCF simples `(?)`), instancing automático, skinning na GPU (paleta de juntas), cache de PSO persistido |
| Exige de **A-1** | `CajuAssetHandle` + `CajuAssetServing` (`state`, `value`, `revision`) do PR #26, assets de malha, material e textura com dados de CPU | o mesmo, mais `inverseBindMatrices` e `jointCount` no asset de malha skinned |
| Exige de **AN-1** | nada | `CajuSkinPose` + `CajuPoseArena`, pose em espaço do modelo sem `inverseBind` (§7.2) |
| Depende de | CajuScene e CajuRHI (existentes), contrato A-1 (#26) e PR de `Package.swift` com `CajuRender` → `CajuAssets` | R-1a, contrato A-1, contrato AN-1 (ADR 0027) |

R-1a **não bloqueia** em AN-1; em A-1 depende só do contrato (`CajuAssetServing`, handles, `revision`): testes usam servidor falso e assets sintéticos.

### 7.1 R-1 ↔ A-1: ponte entre assets e render (decisão, ver ADR 0023)
**Decisão:** `CajuRender` passa a **depender de `CajuAssets`** (mesma camada, como `CajuUI` → `CajuInput`) e é dono da **residência na GPU**. Não há "cola" de aplicação.
- O componente de malha guarda `CajuAssetHandle<…>` (8 bytes, `BitwiseCopyable`, ADR 0021). A extração copia o handle; o render mantém um **cache de residência** em colunas, indexado por `handle.index`, com `generation` e a `revision` do asset (que o A-1 já incrementa "para recriar buffer de GPU após hot reload").
- Na preparação do quadro: `revision` igual → usa o recurso; diferente ou ausente e `state.hasValue` → sobe o dado de CPU (`value(of:)`, saída dos parsers de `CajuAssetsCore`) sob `CajuUploadBudget` (o que não couber espera o quadro seguinte); `.queued`/`.loading`/`.failed` → desenha o **substituto** (malha/material padrão), sem bloquear nem lançar.
- Descarte: handle `.stale` ou evento `unloaded` → o render agenda a destruição do recurso com atraso de N quadros em voo (N = quadros em voo do RHI `(?)`).
- O render consulta só o protocolo `CajuAssetServing` (genérico no servidor), então os testes headless usam um servidor falso e `CajuNullDevice`.

**Por que (comparação):**

| Opção | Como outras engines fazem | Veredito |
|---|---|---|
| **Render depende de assets e é dono da residência (escolhida)** | Bevy: `RenderAssets<GpuMesh>` preparado no mundo de render a partir de `AssetEvent`; Godot e Filament: o servidor de render é dono dos recursos de GPU e o jogo passa ids | Sem cola, sem tradução por quadro; A-1 fica sem GPU (CPU puro, testável em Linux); upload sob orçamento e hot reload por `revision` |
| Cola da aplicação + protocolo de residência (rascunho inicial) | Nenhuma engine mainstream precisa; vira código de integração que todo jogo reescreve | Rejeitada: peça extra, ponto de falha, ninguém dono |
| A-1 sobe a GPU e entrega `CajuTextureHandle`/buffers | Unity: `Mesh` guarda os buffers | Rejeitada: acopla A-1 ao RHI e ao orçamento por quadro; o upload fica fora do controle do frame graph |
| Módulo neutro novo abaixo dos dois | — | Rejeitada: exige `Package.swift` e tipos sem dono claro |

**Custo aceito:** uma linha de dependência em `Package.swift` (`CajuRender` → `CajuAssets`) em **PR dedicado e curto**, só depois do aceite do contrato A-1 (PR #26). Até lá R-1a testa com o servidor falso do protocolo. Se o dono recusar a dependência, o plano B é o protocolo de residência do rascunho anterior (só os tipos de valor deste PR sobrevivem).

### 7.2 R-1b ↔ AN-1: pose de skinning (decisão, ver ADR 0023)
**Decisão:** o AN-1 entrega **pose em espaço do modelo, sem `inverseBind`**; o R-1b multiplica pelo `inverseBind` da malha ao copiar para o buffer do quadro. Componentes em `CajuScene`:
- `CajuSkinPose` (coluna `BitwiseCopyable`, ~12 bytes): `poseSlot: UInt32` (posição na arena), `jointCount: UInt16`, `version: UInt32`. **Só referência**; matrizes ficam numa **arena `CajuPoseArena`** (recurso do mundo, capacidade reservada, sem alocação por quadro), escrita pelo AN-1 e lida pelo R-1b. Motivo: paleta de até 128 `CajuMat4` (~8 KB) não cabe numa coluna do ECS.
- IDs de componente: `CajuRenderMesh` = **8** (confirmado livre pelo dono), `CajuSkinPose` = **9** `(?)`; 3 a 7 ficam livres para `CajuScene`.
- **Por que `CajuScene`:** AN-1 e R-1 já dependem dela; evita AN-1 → CajuRender (animação headless não deve puxar GPU). Mudança aditiva pequena: PR de contrato do dono de `CajuScene`.
- **Por que o `inverseBind` fica no render:** pertence à malha, não ao esqueleto; vários meshes skinned podem compartilhar uma pose (cada um aplica o seu); e só se multiplica para o que passou no *cull* (o AN-1 já corta fora da tela). Unreal e Bevy também finalizam as matrizes de osso no lado de render; Filament recebe a paleta pronta via `setBones`.
- **Alternativa rejeitada:** juntas como entidades com `CajuTransform` (modelo Bevy): reaproveita a propagação, mas custa ~60 entidades por personagem e propaga hierarquia que o AN-1 faz melhor em SIMD num array.
- `jointCount ≤ 128` `(?)`; sem *blend shapes* no MVP. R-1b só copia quando `version` mudou.
- Contrato fino de formato (layout das matrizes, fronteira com clipes) fecha no ADR 0027 do AN-1.

## 9. Testes, goldens e benchmark (quando implementar)
- **Já neste PR:** testes puros da `CajuDrawKey` (ordem de fila, frente-para-trás, trás-para-frente em `blend`, saturação, `NaN`) em `CajuRenderContractTests`.
- **R-1a:** extração com ECS sintético (headless, null device): entidade com/sem componente, hierarquia, handle em `.loading` usa substituto; goldens Metal: cubo unlit, esfera PBR, luz direcional; golden Vulkan quando V-1 fechar. **Benchmark de CPU da extração** (N = 1 000 e 10 000 entidades) com meta `(?)` (< 0,5 ms para 1 000 no aparelho alto, hipótese), e do *sort* da draw list.
- **R-1b:** golden de sombra (tolerância SSIM, plano §testes), contagem de draw calls antes/depois de instancing, golden de skinning com pose sintética.
- **Alocação por quadro estável = 0:** verificada por SIL/instrumentação nos módulos quentes (`performance.md`).
- Números de aparelho ficam `(?)` até medir em iPhone 16 Pro e Galaxy S22+.

## 10. Riscos, kill-criteria e perguntas abertas
- **Sem Swift na nuvem:** tipos e testes deste PR só são verificados pelo CI; números `(?)`.
- **Extração cheia estoura o orçamento** (> 1 ms para 1 000 entidades `(?)`): passar para extração diferencial (ADR de revisão), sem mudar os tipos públicos.
- **`Package.swift` trancado:** a decisão do §7.1 exige uma linha (`CajuRender` → `CajuAssets`) em PR dedicado, depois do aceite do contrato A-1; sem ela vale o plano B do §7.1.
- **Decisões do dono (2026-11-15):** (1)/(2) ponte A-1 ↔ R-1 e lugar da pose: o dono pediu estudo e decisão estratégica, registrada em §7.1/§7.2 e no ADR 0023; (3) uma luz direcional basta para o vertical slice (sim); ID 8 livre (sim); prefixo `Caju*` mantido na API de render por consistência com o resto da engine (o dono disse que não precisa manter em tudo; a UI decide o dela no ADR 0026).
- **Aberto:** PR de `Package.swift` (`CajuRender` → `CajuAssets`) e PR de contrato em `CajuScene` (`CajuSkinPose`, `CajuPoseArena`); ambos depois do aceite deste PR.

## 11. Documentos que este PR atualiza
ADR 0023 (proposto) + `docs/adr/README.md`; plano (§8 Onda 1); `docs/standards/performance.md` (metas de R-1 `(?)`) e `testes.md` (goldens de cena); `Sources/CajuRender/README.md` e DocC.
