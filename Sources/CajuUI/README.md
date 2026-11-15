# CajuUI

UI declarativa (DSL, widgets, batcher).

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** U-1 (Onda 1): **U-1a** núcleo (DSL, `@State`, display list) e **U-1b** render (batcher, SDF/MSDF).
- **Estado:** **contrato em rascunho** (PR de contrato da U-1). Ainda sem API pública além do marcador `CajuUIModule`; nada do contrato abaixo existe em código.

## Contrato (rascunho)
- Brief e assinaturas: [docs/briefs/u-1.md](../../docs/briefs/u-1.md). Decisão: [ADR 0026](../../docs/adr/0026-ui-display-list-e-dsl.md) (Proposto); base nos [ADR 0002](../../docs/adr/0002-ui-declarativa.md) e [0013](../../docs/adr/0013-layout-de-ui-por-faixas.md).
- **Fronteira U-1a ↔ U-1b:** `CajuUIDisplayList` (comandos planos `BitwiseCopyable` em ordem de pintura, instâncias de glifos e tabela de propriedades de camada, com `revision`/`propsRevision`).
- **U-1a** (sem `import CajuRHI`, headless): `CajuView`, `CajuViewBuilder` (aridade fixa 1..10, sem *packs*), `CajuState`/`CajuBinding`/`CajuEnvironment`, slot table, reconciliador, `CajuUIRuntime.update`, widgets básicos.
- **U-1b:** batcher (mescla por pipeline/textura/scissor, ≤ 40 draw calls `(?)`), SDF (retângulos, sombras), MSDF (texto). A parte de GPU **depende do contrato da R-1a**.
- Estrutura planejada: `Core/` (U-1a) e `Render/` (U-1b).

## Dependências
- `CajuCore`
- `CajuUILayout`
- `CajuText`
- `CajuRHI` (só `Render/`)
- `CajuInput`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka. Testes próprios (`CajuUITests`) e benchmark dependem de S-0 (`Package.swift`).
