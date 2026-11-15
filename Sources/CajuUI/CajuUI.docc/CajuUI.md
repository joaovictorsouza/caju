# ``CajuUI``

UI declarativa (DSL no estilo SwiftUI), núcleo retido e display list para o batcher.

## Visão geral

> Estado: **contrato em rascunho (U-1)**. Ainda não há API pública além de `CajuUIModule`; o desenho da API está em `docs/briefs/u-1.md` e no ADR 0026.

A trilha divide-se em duas partes separadas pela *display list*:

- **U-1a (núcleo, headless):** `View` e `ViewBuilder` (sobrecargas fixas, sem *parameter packs*), `State` em slot table, reatividade em lote por View, integração com `CajuUILayout` e `CajuText`, widgets básicos e a produção de `CajuUIDisplayList`.
- **U-1b (render):** batcher, SDF para retângulos e sombras, MSDF para texto. A parte de GPU depende do contrato de render da R-1a.

A display list é plana, contígua e `BitwiseCopyable`, em ordem de pintura. Quadro sem mudança só checa sujeira; mudanças só de desenho (opacidade, deslocamento, escala) alteram apenas a tabela de propriedades de camada.

## Tópicos

### Marcador do módulo
- ``CajuUIModule``
