# ``CajuRender``

Mundo de render separado do ECS: extração, draw list ordenada, materiais e luz (contrato da trilha R-1).

## Visão geral

O render copia do ECS, no fim de cada quadro, só o que o desenho precisa e trabalha sobre essa cópia. Cada item a desenhar é um ``CajuDrawItem`` com uma ``CajuDrawKey`` que agrupa por pipeline e material e ordena por profundidade. Esta versão é o **contrato** (ADR 0023, proposto): extração, frame graph de cena, sombra, instancing e skinning chegam em R-1a e R-1b.

## Tópicos

### Identificadores
- ``CajuRenderMeshID``
- ``CajuRenderMaterialID``

### Material e luz
- ``CajuMaterialParams``
- ``CajuMaterialModel``
- ``CajuAlphaMode``
- ``CajuDirectionalLight``

### Draw list
- ``CajuDrawItem``
- ``CajuDrawKey``
- ``CajuRenderQueue``
