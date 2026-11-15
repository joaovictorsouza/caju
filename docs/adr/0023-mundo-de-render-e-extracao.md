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
- **Fronteira com A-1:** `CajuRender` **não** depende de `CajuAssets`. A cola da aplicação implementa `CajuRenderResidency` e traduz handle de asset em `CajuRenderMeshID`/`CajuRenderMaterialID`; asset em `.loading`/`.failed` desenha substituto, sem bloquear nem lançar.
- **Fronteira com AN-1:** R-1b recebe `CajuSkinPose` (paleta `jointWorld × inverseBind`, espaço do modelo, `jointCount ≤ 128 (?)`) e só a copia; não conhece esqueleto nem clipes. Onde o componente vive (`CajuScene` ou `CajuCore`) fecha no ADR 0027.
- **Divisão:** R-1a (extração, unlit/PBR, luz, câmera, cull, PSO em memória) e R-1b (sombra, instancing, skinning, PSO persistido). R-1a não espera AN-1.
- **Sem dependência nova e sem mudança em `Package.swift`.**

## Alternativas
- **Desenhar direto do ECS** (sem mundo de render): menos código inicial, mas acopla o desenho a arquétipos, impede sobrepor jogo e render e dificulta testes headless.
- **`CajuRender` depender de `CajuAssets`:** mesma camada e exigiria `Package.swift`; a cola mantém os módulos independentes.
- **Vários materiais/luzes dinâmicas no MVP:** fora do escopo do vertical slice; reabrir com medida.
- **Extração diferencial desde o início:** mais complexa; só com benchmark.

## Consequências
- Cada quadro paga uma cópia de extração (custo medido no benchmark de R-1a `(?)`); em troca o desenho é linear e testável sem ECS.
- Mudar o formato de `CajuDrawKey` ou `CajuRenderWorld` depois de A-1/AN-1/U-1b consumirem exige novo ADR.
- A cola da aplicação vira ponto de integração (precisa de dono no vertical slice).
- Verificação deste contrato só pelo CI (sem Swift na nuvem); números marcados `(?)`.

## Perguntas abertas ao dono
1. Aceitar a cola de aplicação como união A-1 ↔ R-1? 2. `CajuSkinPose` em `CajuScene` ou `CajuCore`? 3. ID de componente 8 livre para `CajuRenderMesh`? 4. Uma luz direcional basta para o vertical slice?

## Quando reabrir
Extração custar > 1 ms para 1 000 entidades `(?)`; Vulkan exigir semântica de passe que o frame graph não expressa (ver ADR 0015); vertical slice pedir mais de uma luz, IBL ou cascatas de sombra.
