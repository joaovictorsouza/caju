# ADR 0018: BVH dinâmica, primitivas espaciais e empacotamento da trilha P-3

**Status:** Aceito (implementado na trilha P-3; decisão revista na integração da Onda 0.5 antes do merge em `main`).

## Contexto
A trilha P-3 (`CajuPhysicsSpatial`, camada 1) roda em paralelo com P-1 (`CajuMath`) durante a Onda 0.5, com `Package.swift` trancado (`CLAUDE.md`, ADR 0010). Inicialmente, `CajuPhysicsSpatial` definiu `CajuAABB` e `CajuRay` próprios para não tocar em `CajuMath`; porém, ao integrar com `CajuMath` (que já expôs `CajuAABB`, `CajuSphere`, `CajuRay` e `CajuRayTriangleHit`), a duplicação causou ambiguidade de nomes nos consumidores (`Tests/CajuModulesTests`).

Era necessário alinhar as primitivas entre `CajuMath` e `CajuPhysicsSpatial` sem editar `CajuMath`, mantendo validação rigorosa por erros tipados na BVH, consulta de raio com intervalo `[tMin, tMax]` e `inverseDirection` pré-calculada, além de travessia sem alocação no caminho quente.

## Decisão
- **Reuso de primitivas de `CajuMath` (`CajuAABB`, `CajuSphere`, `CajuRayTriangleHit`):** removem-se as definições duplicadas de `CajuPhysicsSpatial`. Como `CajuAABB` em `CajuMath` não tem inicializador validante, a validação de finitude e `min <= max` (mantendo volume zero válido) é feita pelas APIs da BVH (`insert`, `update`, `build(from:)`, `query(overlapping:)`, `shapecast(swept:displacement:)`), devolvendo `CajuSpatialError` tipado; helpers internos (`internal`) fornecem área superficial, contenção AABB–AABB, expansão gorda saturada e sobreposição esfera–AABB segura contra *overflow* sem editar `CajuMath`.
- **Tipo de consulta de raio próprio (`CajuRayQuery`) e `CajuTriangle` único:** como `CajuRay` em `CajuMath` não armazena `tMin`, `tMax` nem `inverseDirection`, o tipo do módulo passa a se chamar `CajuRayQuery` (`CajuRayQuery.swift`), construível a partir de `CajuRay` (`init(ray:tMin:tMax:) throws(CajuSpatialError)`) ou de origem/direção, validando `NaN`/infinito, direção nula e intervalo `[tMin, tMax]`. `CajuTriangle` permanece em `CajuPhysicsSpatial` (nome único, sem colisão em `CajuMath`) com Möller–Trumbore retornando `CajuRayTriangleHit?`, SAT de 13 eixos contra `CajuAABB` e distância por regiões de Voronoi contra `CajuSphere`.
- **BVH dinâmica (`CajuBVH`):** árvore binária em array contíguo com *free lists* de nós e slots, handles geracionais (`CajuBVHProxy`), AABBs gordas com margem configurável (`fatMargin`) e predição por deslocamento, balanceamento por rotações AVL na inserção/remoção incremental e construção em lote via SAH *binned* (16 *bins*).
- **BVH estática de triângulos (`CajuTriangleBVH`):** SAH *binned* (16 *bins*, até 4 triângulos por folha) com `CajuRayQuery`, `CajuAABB` (SAT de 13 eixos) e `CajuSphere` (Voronoi).
- **Travessia sem alocação no caminho quente (`CajuBVHTraversalStack`):** pilha explícita com capacidade *inline* de 64 entradas (`4 x SIMD16`) e *overflow* reutilizável; variantes com `stack: inout CajuBVHTraversalStack` não alocam após aquecidas, enquanto sobrecargas sem `stack:` ficam documentadas como conveniência que cria pilha local por chamada.
- **Testes e benchmarks temporários:** suítes unitárias e de propriedade (`CajuFuzz.run` com `10_000` iterações contra força bruta) residem em `Tests/CajuModulesTests/` e o benchmark em `caju-bench` permanece pendente `(?)` até PR dedicado no `Package.swift` para ligar `CajuPhysicsSpatial` a `CajuBenchmarks` e a um alvo de teste próprio.

## Alternativas
- Manter `CajuAABB` e `CajuRay` duplicados em `CajuPhysicsSpatial`: gera conflito de lookup (`ambiguous for type lookup`) em qualquer alvo que importe `CajuMath` e `CajuPhysicsSpatial`.
- Adicionar `tMin`, `tMax`, `inverseDirection` ou inicializador validante em `CajuMath`: violaria a regra de um dono por diretório durante a Onda 0.5 (`CajuMath` é de P-1).
- Usar alocação por consulta ou pilha recursiva: violaria a regra de zero alocação no caminho quente e arriscaria estouro de *stack* em árvores desbalanceadas.

## Consequências
- Contratos de `CajuPhysics` (camada 3) e demais módulos consomem diretamente `CajuAABB`, `CajuSphere` e `CajuRayTriangleHit` de `CajuMath` junto com `CajuBVH`, `CajuTriangleBVH`, `CajuRayQuery` e `CajuTriangle` de `CajuPhysicsSpatial`, sem ambiguidade de nomes.
- Consumidores que chamam `query(overlapping:)` passam a tratar `throws(CajuSpatialError)` porque `CajuMath.CajuAABB` não valida limites na construção.
- Quando `Package.swift` for aberto em PR dedicado, pode-se criar `CajuPhysicsSpatialTests` e ligar `CajuPhysicsSpatial` ao `CajuBenchmarks` para medir vazão e latência (atualmente `(?)`).

## Quando reabrir
- Se `CajuRender` ou outros módulos precisarem de `CajuTriangle` ou `CajuRayQuery` na camada 0 (promover ou alinhar contratos em `CajuMath` via PR de contrato).
- Se medições em aparelho mostrarem necessidade de BVH 4-way/8-way (QBVH) ou `maxLeafTriangles` diferente.
