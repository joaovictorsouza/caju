# ADR 0026: Display list da UI e contrato da DSL (U-1)

**Status:** Proposto (esboço do contrato, U-1). Detalha o [ADR 0002](0002-ui-declarativa.md) e usa o [ADR 0013](0013-layout-de-ui-por-faixas.md) e o [ADR 0012](0012-texto-p5.md). Passa a Aceito quando a U-1a mergear implementação que o cumpra; assinaturas completas em [briefs/u-1.md](../briefs/u-1.md).

## Contexto
O ADR 0002 definiu a DSL, o núcleo retido e a reatividade em lote, mas não o ponto de encontro entre a lógica de UI e o desenho. A Onda 1 divide a UI em **U-1a** (núcleo, puro, headless) e **U-1b** (batcher, SDF/MSDF, GPU) com donos/momentos diferentes, e a U-1b depende do contrato de render da R-1a. É preciso uma fronteira estável, testável sem GPU e sem alocação em quadro estável. A lição do ADR 0014 vale aqui: *parameter packs* custaram ~10× por despacho via *witness table* dentro do laço.

## Decisão
1. **Display list plana como fronteira.** A U-1a produz `CajuUIDisplayList`: `ContiguousArray` de `CajuDrawCommand` (tamanho fixo, `BitwiseCopyable`, em ordem de pintura), de `CajuUIGlyphInstance` e uma tabela pequena `CajuUILayerProps`. Sem pack, existencial, closure ou `String` no caminho quente. A U-1b só lê.
2. **Comandos:** `rect` (SDF: raio por canto, borda, sombra), `glyphRun` (faixa de instâncias MSDF), `image`, `pushClip`/`popClip` (*scissor* retangular). Clip arredondado e opacidade de grupo com *offscreen* ficam fora da v1.
3. **Dois contadores de revisão.** `revision` (comandos/glifos mudaram) e `propsRevision` (só propriedades de desenho mudaram). Mudança só de opacidade/deslocamento/escala/scroll altera apenas `layerProps`, sem reexecutar `body` nem reconstruir comandos (`graphicsLayer`, ADR 0002). Revisões iguais ⇒ a U-1b não faz trabalho de CPU.
4. **Capacidade reservada e erro tipado.** Limites em `CajuUIConfiguration`; reconstruir reaproveita armazenamento (0 alocação em quadro estável); estourar capacidade é `CajuUIError`, nunca crescimento silencioso.
5. **Batcher:** comandos consecutivos com mesmo `(pipeline, textura, scissor)` viram um draw call; ordem de pintura intocada; instâncias escritas direto no buffer de upload do RHI. Meta ≤ 40 draw calls na tela de loja `(?)`.
6. **Separação por diretório dentro de `CajuUI`:** `Core/` (U-1a) não importa `CajuRHI`; `Render/` (U-1b) sim. Verificação por script/revisão (`Package.swift` é alvo único).
7. **DSL:** `CajuView` + `@resultBuilder CajuViewBuilder` com **sobrecargas de aridade fixa 1..10**, não *packs*; `CajuState` em **slot table** contígua indexada por `(nó, slot)` com geração, alocação só no mount; `CajuBinding` antigo vira *no-op* seguro; profundidade máxima 128; erros `throws(CajuUIError)`.
8. **Texto com quebra de linha (resolve a ressalva do ADR 0013, proposta):** o integrador mede com `CajuTextLayout` e atualiza a folha; **no máximo 2 passadas** de layout por quadro (layout → remedir rótulos cuja largura mudou → layout). Sem callback de medida em `CajuUILayout` na v1.
9. **Divisão e dependências:** a U-1a não depende de `CajuRHI`, GPU nem R-1; a **U-1b-cpu** (batcher sobre `CajuNullDevice`) é headless; só a **U-1b-gpu** depende do contrato da R-1a (passe de UI no *frame graph*, cache de PSO, anel de upload, shaders Slang, harness de golden). `WorldAnchor` espera a extração de câmera da R-1a.

## Alternativas
- **Árvore de comandos aninhada ou protocolo `DrawCommand`:** existenciais e ponteiros espalhados; pior contiguidade e alocação. Rejeitada.
- **A U-1a falar direto com o RHI (sem display list):** acopla DSL e GPU, impede testes headless e bloqueia a U-1a pela R-1a. Rejeitada.
- **`ViewBuilder` com *parameter packs*:** menos código, mas o padrão de custo do ADR 0014 e mais lento de compilar. Rejeitada para o caminho de reconciliação; sobrecargas fixas até 10.
- **Uma entidade ECS por nó:** já rejeitada no ADR 0002.
- **Opacidade de grupo por *offscreen* desde já:** custo de memória/banda sem medida; adiada.

## Consequências
- A U-1a pode ser testada inteira no CI Linux, com *dump* textual da display list como golden; a U-1b-cpu também (buffers de instâncias).
- Exige do `Package.swift` (S-0): alvo `CajuUITests` e benchmark. Sem isso, os testes da U-1a não têm onde viver.
- A entrega entre Game Thread e render thread (se separadas, ADR 0008) fica para V-1/R-1; na v1 é o mesmo *thread*.
- Limitação conhecida: opacidade de grupo é aplicada por comando (sobreposição interna aparece).
- Números do plano (`body` < 100 ns, layout 1 000 nós < 1 ms, ≤ 40 draw calls) seguem `(?)` até haver implementação e medida em aparelho.

## Quando reabrir
Se `Observation` não rodar em Android real (S-0); se 2 passadas de layout para texto estourarem o orçamento (abrir PR de contrato em `CajuUILayout`); se a tela de loja passar de 40 draw calls com a regra de mescla; se o custo de `body` > 100 ns `(?)`; se a opacidade por comando for visualmente inaceitável.
