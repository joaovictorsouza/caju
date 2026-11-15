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
Uma entidade é desenhada se tiver `CajuGlobalTransform` (CajuScene) e `CajuRenderMesh` (componente novo de `CajuRender`, ID de componente reservado no ADR 0023: **ID 8** `(?)`, a confirmar contra o mapa de IDs do `CajuCore`):

| Componente | Conteúdo |
|---|---|
| `CajuRenderMesh` | `mesh: CajuRenderMeshID`, `material: CajuRenderMaterialID`, `layerMask: UInt32`, `castsShadow: Bool` |
| `CajuCamera` (R-1a) | projeção (perspectiva/ortográfica), planos, `viewport`; a matriz de vista vem do `CajuGlobalTransform` |
| `CajuDirectionalLight` (valor do contrato; componente em R-1a) | direção, cor, intensidade, `castsShadow` |
| `CajuSkinPose` (R-1b) | ver §7.2 |

`CajuRenderMeshID` e `CajuRenderMaterialID` são handles geracionais (`CajuHandle<Tag>`, ADR 0015) **do mundo de render**; o vínculo com `AssetServer` está no §7.1.

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
| Exige de **A-1** | `CajuMeshAsset`/`CajuTextureAsset` residentes na GPU consultáveis por handle (§7.1) | o mesmo, mais `inverseBindMatrices` e `jointCount` na malha skinned |
| Exige de **AN-1** | nada | `CajuSkinPose` por entidade (§7.2) |
| Depende de | CajuScene (existente), CajuRHI (existente), contrato A-1 | R-1a, contrato A-1, contrato AN-1 (ADR 0027) |

R-1a **não bloqueia** em AN-1; em A-1 depende só do contrato (handles + residência), pois testes usam assets sintéticos criados direto no RHI.

### 7.1 O que R-1 exige de A-1 (handles)
`CajuRender` **não depende de `CajuAssets`** (mesma camada; `Package.swift` trancado). Quem une os dois é a **cola da aplicação** (camada 4 / host), que implementa o protocolo `CajuRenderResidency` declarado em R-1a:

1. **Handle de asset estável e barato:** `CajuAssetHandle<Asset>` (índice + geração, `Sendable`, `BitwiseCopyable`, consulta **sem alocação**, ADR 0021). A extração só copia o handle; nunca segura referência ao asset.
2. **Estados de carga consultáveis:** `.loading`, `.ready`, `.failed`. Em `.loading`/`.failed` a extração desenha um **substituto** (malha/material padrão do `CajuRenderWorld`), nunca bloqueia o quadro nem lança erro de jogo.
3. **Residência na GPU:** para um handle `.ready`, A-1 (que já depende de `CajuRHI`) entrega: buffers de vértice/índice do RHI, faixas de submalha (`firstIndex`, `indexCount`), **AABB local**, layout de vértice (id de formato), e para materiais as texturas como `CajuTextureHandle` do RHI + escalares. A cola converte isso em `CajuRenderMeshID`/`CajuRenderMaterialID`.
4. **Hot reload:** troca de conteúdo mantém o handle e **incrementa uma geração de conteúdo**; o mundo de render invalida o que depende disso no quadro seguinte.
5. **Descarte seguro:** destruir um asset não destrói recurso do RHI que ainda esteja na draw list do quadro em voo (descarte adiado por N quadros; N definido no ADR 0021 `(?)`).

Se A-1 preferir outro formato, R-1 ajusta só o protocolo `CajuRenderResidency` e a cola; os tipos de valor deste PR não mudam.

### 7.2 O que R-1b exige de AN-1 (pose)
- **Componente `CajuSkinPose`** (vive em módulo que AN-1 e R-1 já dependam: proposta `CajuScene`, PR de contrato pequeno do dono de `CajuScene`; alternativa: `CajuCore`. Decisão no ADR 0027).
- Conteúdo: `jointCount ≤ 128` `(?)` e a **paleta de matrizes de skinning já multiplicada** (`jointWorld × inverseBind`), em espaço do modelo, `CajuMat4` coluna-principal como o resto do `CajuMath`, contígua. O AN-1 escreve; R-1b só copia para o buffer de pose do quadro e referencia por `poseIndex`.
- **Quem multiplica `inverseBind`:** AN-1 (a malha skinned traz os `inverseBindMatrices` via A-1; AN-1 já tem as juntas). R-1b não conhece esqueleto nem clipes.
- **Frequência:** pose atualizada pelo AN-1 antes da extração (`postUpdate`); `cull` fora da tela e taxa reduzida são decisão do AN-1 (plano §4); pose congelada = mesma pose no quadro seguinte (R-1b não recopia se um contador de versão não mudou `(?)`).
- Normais/tangentes: skinning de posição, normal e tangente no vertex shader; sem *blend shapes* no MVP.

## 9. Testes, goldens e benchmark (quando implementar)
- **Já neste PR:** testes puros da `CajuDrawKey` (ordem de fila, frente-para-trás, trás-para-frente em `blend`, saturação, `NaN`) em `CajuRenderContractTests`.
- **R-1a:** extração com ECS sintético (headless, null device): entidade com/sem componente, hierarquia, handle em `.loading` usa substituto; goldens Metal: cubo unlit, esfera PBR, luz direcional; golden Vulkan quando V-1 fechar. **Benchmark de CPU da extração** (N = 1 000 e 10 000 entidades) com meta `(?)` (< 0,5 ms para 1 000 no aparelho alto, hipótese), e do *sort* da draw list.
- **R-1b:** golden de sombra (tolerância SSIM, plano §testes), contagem de draw calls antes/depois de instancing, golden de skinning com pose sintética.
- **Alocação por quadro estável = 0:** verificada por SIL/instrumentação nos módulos quentes (`performance.md`).
- Números de aparelho ficam `(?)` até medir em iPhone 16 Pro e Galaxy S22+.

## 10. Riscos, kill-criteria e perguntas abertas
- **Sem Swift na nuvem:** tipos e testes deste PR só são verificados pelo CI; números `(?)`.
- **Extração cheia estoura o orçamento** (> 1 ms para 1 000 entidades `(?)`): passar para extração diferencial (ADR de revisão), sem mudar os tipos públicos.
- **`Package.swift` trancado:** nenhuma dependência nova é necessária. Se A-1 exigir que `CajuAssets` seja visível a `CajuRender`, abrir PR dedicado de pacote (não previsto).
- **Perguntas ao dono:** (1) aceitar a cola de aplicação como ponto de união A-1 ↔ R-1? (2) `CajuSkinPose` em `CajuScene` ou `CajuCore`? (3) ID de componente 8 livre? (4) uma única luz direcional no MVP basta para o vertical slice?

## 11. Documentos que este PR atualiza
ADR 0023 (proposto) + `docs/adr/README.md`; plano (§8 Onda 1); `docs/standards/performance.md` (metas de R-1 `(?)`) e `testes.md` (goldens de cena); `Sources/CajuRender/README.md` e DocC.
