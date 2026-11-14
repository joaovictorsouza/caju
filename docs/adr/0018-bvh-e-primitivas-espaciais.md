# ADR 0018: BVH dinâmica, primitivas espaciais e empacotamento da trilha P-3

**Status:** Aceito (implementado na trilha P-3).

## Contexto
A trilha P-3 (`CajuPhysicsSpatial`, camada 1) roda em paralelo com P-1 (`CajuMath`) durante a Onda 0.5, com `Package.swift` trancado (`CLAUDE.md`, ADR 0010). Era necessário definir onde ficam as primitivas espaciais usadas pelas consultas, a estrutura da BVH dinâmica e estática, o modelo de memória das consultas no caminho quente e onde alocar testes e benchmarks enquanto o manifesto não é alterado.

## Decisão
- **Primitivas espaciais próprias do módulo (`CajuAABB`, `CajuRay`, `CajuTriangle`):** definidas em `CajuPhysicsSpatial` (sobre `SIMD3<Float>` e pontes para `CajuVec3`), evitando editar `CajuMath` (dono P-1) e mantendo `CajuPhysicsSpatial` autossuficiente e sem `Foundation`.
- **BVH dinâmica (`CajuBVH`):** árvore binária em array contíguo com *free lists* de nós e slots, handles geracionais (`CajuBVHProxy`), AABBs gordas com margem configurável (`fatMargin`) e predição por deslocamento, balanceamento por rotações AVL na inserção/remoção incremental e construção em lote via SAH *binned* (16 *bins*).
- **BVH estática de triângulos (`CajuTriangleBVH`):** SAH *binned* (16 *bins*, até 4 triângulos por folha) com interseção Möller–Trumbore, SAT de 13 eixos para sobreposição triângulo–AABB e distância exata por regiões de Voronoi para triângulo–esfera.
- **Travessia sem alocação no caminho quente (`CajuBVHTraversalStack`):** pilha explícita com capacidade *inline* de 64 entradas (`4 x SIMD16`) e *overflow* reutilizável; variantes com `stack: inout CajuBVHTraversalStack` não alocam após aquecidas, enquanto sobrecargas sem `stack:` ficam documentadas como conveniência que cria pilha local por chamada.
- **Testes e benchmarks temporários:** suítes unitárias e de propriedade (`CajuFuzz.run` com `10_000` iterações contra força bruta) residem em `Tests/CajuModulesTests/` e o benchmark em `caju-bench` permanece pendente `(?)` até PR dedicado no `Package.swift` para ligar `CajuPhysicsSpatial` a `CajuBenchmarks` e a um alvo de teste próprio.

## Alternativas
- Colocar `CajuAABB`/`CajuRay` em `CajuMath` durante a Onda 0.5: violaria a regra de um dono por diretório em paralelo com P-1.
- Usar alocação por consulta ou pilha recursiva: violaria a regra de zero alocação no caminho quente e arriscaria estouro de *stack* em árvores desbalanceadas.

## Consequências
- Contratos de `CajuPhysics` (camada 3) já podem consumir `CajuBVH`, `CajuTriangleBVH`, `CajuAABB`, `CajuRay` e `CajuTriangle` sem depender de mudanças em `CajuMath`.
- Quando `Package.swift` for aberto em PR dedicado, pode-se criar `CajuPhysicsSpatialTests` e ligar `CajuPhysicsSpatial` ao `CajuBenchmarks` para medir vazão e latência (atualmente `(?)`).

## Quando reabrir
- Se `CajuRender` ou `CajuScene` precisarem de `CajuAABB`/`CajuRay` na camada 0 (mover primitivas para `CajuMath` via PR de contrato).
- Se medições em aparelho mostrarem necessidade de BVH 4-way/8-way (QBVH) ou `maxLeafTriangles` diferente.
