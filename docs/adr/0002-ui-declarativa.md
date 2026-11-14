# ADR 0002: UI declarativa (DSL estilo SwiftUI) e reatividade

**Status:** Aceito. Corrige o §6.4 do plano original.

## Contexto
Devs mobile devem reconhecer a sintaxe (SwiftUI/Compose). O plano original afirmava "granularidade fina por propriedade" via Observation, o que é tecnicamente incorreto: argumentos Swift são avaliados *eagerly* (`pressed ? 0.97 : 1`) e `withObservationTracking` é *one-shot* e dispara em `willSet`.

## Decisão
- **API pública:** DSL declarativa (`View`, `@State`, `@Environment`, `@Observable`, modificadores, `ForEach`, `LazyVStack`, `NavigationStack`...).
- **Núcleo retido próprio** de nós (sem uma entidade ECS por nó); integração com o ECS nas bordas (`WorldAnchor`, eventos de ponteiro, `Environment`).
- **Reatividade em lote por View:** 1 tracking por View; o `onChange` só marca bit de "suja"; `body` reexecuta em lote no fim do quadro, com re-arme do tracking.
- `State` em **slot table** própria.
- Propriedades de **desenho** (animação, scroll, transform, opacidade) ligadas **direto ao nó retido**, sem passar por `body` (como `graphicsLayer` do Compose).
- Identidade posicional (ViewBuilder) + `ForEach(id:)` explícito; memoização por `Equatable`; listas virtualizadas.
- **Layout** no estilo SwiftUI (proposta de tamanho → medida → posicionamento). Flex/Grid CSS fica adiado.
- **Templates XML e compilador Tailwind saem da v1.** "UI como dado" (árvore serializada da DSL) é o caminho para hot reload e UI remota no futuro.

## Alternativas
UI 100 % ECS (custo de memória por nó, perde contiguidade); diff completo após reexecutar `body` (custo proporcional à árvore).

## Consequências
Exige medir o custo de `body` (meta < 100 ns (?)); nomes de tipos próprios onde a semântica difere do SwiftUI.

## Quando reabrir
Se o tracking por View mostrar custo alto em telas com muitas Views pequenas.
