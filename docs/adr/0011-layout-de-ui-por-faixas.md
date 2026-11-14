# ADR 0011: Layout de UI por faixas de tamanho (P-4)

**Status:** Aceito. Detalha o item "layout no estilo SwiftUI" do [ADR 0002](0002-ui-declarativa.md).

## Contexto
O ADR 0002 pede layout "proposta de tamanho → medida → posicionamento". A implementação literal do SwiftUI (o pai consulta o filho várias vezes com propostas diferentes para medir a flexibilidade) custa 3^profundidade em pilhas aninhadas sem *cache*, e a meta é 1 000 nós em < 1 ms sem alocação (NFR-009).

## Decisão
- Cada nó informa uma **faixa de tamanho** `(min, ideal, max)` por eixo, calculada **uma vez, de baixo para cima** (O(n)). Depois um passo **de cima para baixo** dá a cada filho `clamp(proposta, min, max)` e o posiciona. Duas passadas lineares, sem consultas repetidas.
- Pilhas dividem o eixo principal pelo "nível de água": cada filho recebe `clamp(nível, min, max)` e o nível sobe/desce até a soma fechar (equivalente ao *flex* do CSS; sem ordenar, sem alocar). `Spacer` é flexível só ao longo do eixo da pilha pai.
- `frame`: tamanho do filho limitado a `[minW, maxW]`; com `max` explícito o quadro cresce até ele (`maxWidth: .infinity` preenche); `width/height` fixos vencem. Se `max` < mínimo do filho, o filho transborda (como no SwiftUI).
- Árvore em arrays contíguos (`CajuLayoutTree`), identificadores com geração, profundidade máxima 128 (a recursão é limitada), **sem alocação** em árvore estável e **sem recálculo** se nada mudou e o tamanho disponível é o mesmo.
- Hit-testing sem recursão nem alocação: o último nó, na ordem de pintura, cuja moldura contém o ponto e que seja *hit-testable*; filhos fora da moldura do pai não são testados (equivale a recortar).
- Valores negativos/`NaN` vindos de fora são normalizados para 0 (dado externo é hostil).

## Alternativas
SwiftUI literal com *cache* por nó (mais código e memória); Flexbox/Grid CSS (adiado no ADR 0002).

## Consequências
- Conteúdo cujo tamanho depende da largura (texto que quebra linha) **não** cabe numa faixa fixa: o integrador (`CajuUI` + `CajuText`) mede o texto e atualiza a folha (`update`), ou o contrato ganha um *callback* de medida por largura em PR de contrato futuro (a decidir com a P-5).
- Invalidação é por árvore inteira (um bit); invalidação por subárvore fica para quando a medição pedir.
- Sem `Grid`, `LazyVStack`, `offset`, `aspectRatio`, âncoras de alinhamento personalizadas nem espelhamento RTL nesta versão.

## Quando reabrir
Se o texto com quebra de linha exigir proposta de largura durante a medida; se a invalidação por árvore inteira ultrapassar o orçamento em telas grandes.
