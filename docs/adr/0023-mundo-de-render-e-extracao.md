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
- **Fronteira com A-1 (revisada 2026-11-15 após estudo; substitui a "cola de aplicação" do rascunho):** `CajuRender` **depende de `CajuAssets`** e é dono da **residência na GPU**. Componentes guardam `CajuAssetHandle`; a extração copia o handle; o render mantém um cache de residência em colunas indexado por `handle.index`, validado por `generation` e pela `revision` do asset (ADR 0021), sobe o dado de CPU sob `CajuUploadBudget` e desenha um substituto enquanto o asset não está `loaded`. Descarte com atraso de quadros em voo. Padrão: Bevy (`RenderAssets` a partir de eventos de asset), Godot e Filament (render dono dos recursos de GPU). Testes headless usam `CajuAssetServing` falso. Custo: uma linha em `Package.swift` em PR dedicado depois do aceite do contrato A-1 (#26); plano B: protocolo de residência implementado pela aplicação.
- **Fronteira com AN-1 (revisada):** o AN-1 entrega **pose em espaço do modelo sem `inverseBind`**; o R-1b multiplica pelo `inverseBind` da malha ao copiar para o buffer do quadro (só para o que passou no *cull*; uma pose serve a várias malhas). `CajuSkinPose` (só referência: slot na arena, `jointCount`, `version`; ID 9 `(?)`) e a arena `CajuPoseArena` (matrizes, capacidade reservada) ficam em **`CajuScene`**, que AN-1 e R-1 já consomem, sem AN-1 → CajuRender. Rejeitado: juntas como entidades (Bevy), por custo de entidades e propagação; paleta dentro do componente (8 KB por coluna). `jointCount ≤ 128 (?)`. Formato fino no ADR 0027.
- **Divisão:** R-1a (extração, unlit/PBR, luz, câmera, cull, PSO em memória) e R-1b (sombra, instancing, skinning, PSO persistido). R-1a não espera AN-1.
- **Sem dependência nova e sem mudança em `Package.swift`.**

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
Uma luz direcional basta para o vertical slice; ID de componente 8 livre; prefixo `Caju*` mantido na API de render. A ponte A-1 ↔ R-1 e o lugar da pose foram entregues ao estudo (acima). Aberto: PR de `Package.swift` e PR de contrato em `CajuScene`.

## Quando reabrir
Extração custar > 1 ms para 1 000 entidades `(?)`; Vulkan exigir semântica de passe que o frame graph não expressa (ver ADR 0015); vertical slice pedir mais de uma luz, IBL ou cascatas de sombra.
