# ADR 0023: Mundo de render separado, extração e draw list (R-1)

**Status:** Proposto (esboço publicado com o contrato em PR draft; vira Aceito no merge do contrato). Implementa o ADR 0001 (RHI próprio) e o ADR 0015 (frame graph); não os substitui.

## Contexto
A Onda 1 ([brief](../briefs/onda-1.md)) pede render completo no `CajuRender`: unlit + PBR simples, luz direcional, 1 sombra, instancing e skinning, sobre o RHI e o frame graph do ADR 0015. A-1 (handles), AN-1 (pose) e U-1b (passe de UI) dependem do formato que R-1 decidir, então o contrato precisa sair antes do código. Detalhe e tabelas: [briefs/r-1-contrato.md](../briefs/r-1-contrato.md).

## Decisão
- **Mundo de render separado do ECS.** Por quadro: extração (copia para `CajuRenderWorld` só o necessário: matriz de mundo, ids, caixa, luz, câmera, pose) e depois cull, ordenação, frame graph e gravação lendo apenas o mundo de render. O desenho nunca consulta o ECS.
- **Extração cheia por quadro em R-1a**, em colunas (SoA), com capacidade reservada e **zero alocação no estado estável**; estouro é `CajuRenderError.capacityExceeded`, nunca crescimento. Extração diferencial só se o benchmark exigir `(?)`.
- **Frame graph de cena sobre o do RHI:** `shadow` (R-1b) → `main` (forward, MSAA transitório, resolve) → UI (passe declarado por U-1b no mesmo grafo) → *backbuffer*. Topologia compilada uma vez; ordem = declaração (ADR 0015).
- **Draw list de valores** (`CajuDrawItem`) ordenada por chave de 64 bits `fila(4) | pipeline(12) | material(16) | profundidade(32)`; opacos frente-para-trás, `blend` trás-para-frente. Instancing agrupa itens consecutivos de mesma `(mesh, material, pipeline)` (R-1b).
- **Materiais:** `unlit` e `pbr` (base color, metálico/rugosidade, normal, emissivo; sem IBL no MVP). **Luz:** uma direcional + ambiente. Variantes por permutação no PSO, não por ramo dinâmico.
- **Fronteira com A-1 (revisada 2026-11-15 após estudo e avaliação independente; substitui a "cola de aplicação" do rascunho):** `CajuRender` **depende de `CajuAssets`** e é dono da **residência na GPU**; **`CajuAssets` nunca importa `CajuRHI` nem `CajuRender`** (A-1 é só CPU, testável em Linux).
  - **Extração:** o servidor (`CajuAssetServing`, não `Sendable`, pertence à thread de jogo) é consultado **só na extração, na thread de jogo**. A extração copia para o mundo de render o **valor de CPU `Sendable`** do asset (ou uma referência imutável a ele) e o handle; o desenho nunca toca o servidor.
  - **Invalidação por eventos:** o render consome `drainEvents` (loaded, reloaded, unloaded, failed) uma vez por quadro para criar, recriar e descartar recursos; **não** compara `revision` item a item por quadro. A `revision` serve só para o primeiro encontro com um handle e para conferência em testes.
  - Cache de residência em colunas indexado por `handle.index` (validado por `generation`), upload sob `CajuUploadBudget`, substituto enquanto o asset não está `loaded`, descarte com atraso de quadros em voo. Testes headless usam `CajuAssetServing` falso.
  - **`Package.swift` (entra no PR único final da Onda 1, `integracao/onda-1`, por decisão do dono em 2026-11-16; sem PR de pacote separado):** adicionar `CajuRender` → `CajuAssets` **e remover `CajuAssets` → `CajuRHI`** (nenhum arquivo de `CajuAssets` a usa). Plano B se o dono recusar a dependência: protocolo de residência implementado pela aplicação.
  - **Comparação honesta:** só o Bevy faz exatamente isto (`RenderAssets` no mundo de render, alimentado por eventos de asset). No Godot o recurso chama o `RenderingServer` por conta própria; no Filament a ponte é um módulo à parte (`gltfio`). Nosso argumento não é "todos fazem": é manter o A-1 só em CPU, sem GPU, testável em Linux, com upload sob o orçamento do frame graph.
- **Fronteira com AN-1 (revisada):** o AN-1 entrega **pose em espaço do modelo sem `inverseBind`**; o R-1b multiplica pelo `inverseBind` da malha ao copiar para o buffer do quadro (só para o que passou no *cull*; uma pose serve a várias malhas). `CajuSkinPose` (só referência: slot na arena, `jointCount`, `version`; ID 9 `(?)`) e a arena `CajuPoseArena` (matrizes, capacidade reservada) ficam em **`CajuScene`**, que AN-1 e R-1 já consomem, sem AN-1 → CajuRender. Rejeitado: juntas como entidades (Bevy), por custo de entidades e propagação; paleta dentro do componente (8 KB por coluna). `jointCount ≤ 128 (?)`. Formato fino no ADR 0027.
- **Divisão:** R-1a (extração, unlit/PBR, luz, câmera, cull, PSO em memória) e R-1b (sombra, instancing, skinning, PSO persistido). R-1a não espera AN-1.
- **Este PR não muda `Package.swift`;** a mudança de dependências acima vai em PR dedicado (nenhuma dependência externa nova).

## Alternativas
- **Desenhar direto do ECS** (sem mundo de render): menos código inicial, mas acopla o desenho a arquétipos, impede sobrepor jogo e render e dificulta testes headless.
- **Cola de aplicação entre A-1 e R-1** (rascunho inicial): peça de integração sem dono que todo jogo reescreveria; rejeitada após comparar com Bevy, Godot, Filament e Unity.
- **A-1 sobe a GPU (estilo Unity `Mesh`):** acopla A-1 ao RHI e tira o upload do orçamento por quadro do render.
- **AN-1 multiplica o `inverseBind`:** antecipa trabalho para malhas fora do *cull* e amarra a pose a uma malha.
- **Vários materiais/luzes dinâmicas no MVP:** fora do escopo do vertical slice; reabrir com medida.
- **Extração diferencial desde o início:** mais complexa; só com benchmark.

## Consequências
- Cada quadro paga uma cópia de extração (custo medido no benchmark de R-1a `(?)`); em troca o desenho é linear e testável sem ECS.
- Mudar o formato de `CajuDrawKey` ou `CajuRenderWorld` depois de A-1/AN-1/U-1b consumirem exige novo ADR.
- `CajuRender` fica acoplado a `CajuAssets` (e a A-1 não precisa de GPU); AN-1 não conhece render nem malhas.
- Verificação deste contrato só pelo CI (sem Swift na nuvem); números marcados `(?)`.

## Decisões do dono (2026-11-15)
Uma luz direcional basta para o vertical slice; ID de componente 8 livre; prefixo `Caju*` mantido na API de render. A ponte A-1 ↔ R-1 e o lugar da pose foram entregues ao estudo (acima). Aberto: PR de `Package.swift` e contrato em `CajuScene`.

## Quando reabrir
Extração custar > 1 ms para 1 000 entidades `(?)`; Vulkan exigir semântica de passe que o frame graph não expressa (ver ADR 0015); vertical slice pedir mais de uma luz, IBL ou cascatas de sombra.
