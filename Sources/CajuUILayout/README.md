# CajuUILayout

Árvore retida e layout de UI, sem GPU e sem Foundation. Decisões: [ADR 0002](../../docs/adr/0002-ui-declarativa.md) e [ADR 0013](../../docs/adr/0013-layout-de-ui-por-faixas.md).

- **Camada:** 1 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** P-4.
- **Estado:** implementado (P-4). Sem integração com texto (P-5) nem com a DSL (`CajuUI`).

## API pública
- `CajuLayoutTree`: `add(_:to:)`, `update(_:kind:)`, `remove(_:)`, `setHitTestable`, `layout(in:)`, `frame(of:)`, `hitTest(_:)`, `children(of:)`, `invalidate()`.
- `CajuLayoutKind`: `hStack`, `vStack`, `zStack`, `frame`, `padding`, `spacer`, `leaf(CajuSizeRange)`.
- Auxiliares: `CajuSizeRange` (`.fixed`, `.flexible`), `CajuFrameConstraints`, `CajuInsets`, `CajuAlignment`, `CajuUIRect`, `CajuLayoutNodeID`, `CajuLayoutError`.
- `CajuUILayoutModule` é só o marcador do M0 (usado por `CajuModulesTests`).

## Como funciona
Duas passadas lineares: faixas `(min, ideal, max)` de baixo para cima e molduras de cima para baixo. Pilhas dividem o eixo principal pelo "nível de água". `layout(in:)` não aloca em árvore estável e não recalcula se nada mudou. Coordenadas: origem no canto superior esquerdo, y para baixo; `leading` = esquerda.

## Dependências
- `CajuMath`
- `CajuCollections` (declarada; ainda não usada)

## Como testar
`swift test --filter CajuUILayoutTests` (exemplos, propriedades com PCG semeado, estabilidade de armazenamento) e `swift run -c release caju-bench` (entrada `uilayout.relayout_1000_nodes`). O alvo `CajuModulesTests` garante que o módulo compila e linka.

## Medidas (Linux x86-64, release; `(?)` em aparelho)
~1 000 nós, relayout completo ≈ 45 µs; 0 `malloc` em 10 000 relayouts + hit-tests (contador via `LD_PRELOAD`); hit-test ≈ 0,1–0,3 µs.
