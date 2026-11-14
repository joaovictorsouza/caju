# CajuPhysicsSpatial

BVH dinâmica e estática e consultas espaciais (*raycast*, sobreposição, *shapecast*) para a trilha P-3 da engine Caju.

- **Camada:** 1 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** P-3.
- **Estado:** implementado (primitivas `CajuAABB`, `CajuRay`, `CajuTriangle`, pilha `CajuBVHTraversalStack`, `CajuBVH` dinâmica com SAH *binned* / rotações AVL e `CajuTriangleBVH` estática com SAH *binned* e Möller–Trumbore). Sem medições de benchmark dedicadas até o momento (`(?)`).

## Dependências
- `CajuMath`
- `CajuCollections` (declarada no manifesto; sem uso atual neste módulo)

Sem dependência de `Foundation`, `Glibc` ou `Darwin`. Construído com `.swiftLanguageMode(.v6)` (`StrictConcurrency`) e `.treatAllWarnings(as: .error)`.

## API pública

- **Marcador e erros:**
  - `CajuPhysicsSpatialModule`: marcador do módulo para verificação de linkagem.
  - `CajuSpatialError`: erro tipado (`nonFiniteBounds`, `invalidBounds`, `nonFiniteRay`, `invalidRayDirection`, `invalidRayRange`, `invalidHandle`, `capacityExceeded`, `nonFiniteInput`, `invalidRadius`, `invalidTriangleIndices`).
- **Primitivas:**
  - `CajuAABB`: AABB (`min`, `max` em `SIMD3<Float>`) validada na construção (aceita volume zero; rejeita `NaN`/infinito e `min > max`), `center`, `extents`, `surfaceArea`, `union(_:)`, `overlaps(_:)`, `contains(_:)`, `enlarged(margin:)`, `intersect(ray:tMaxLimit:)`.
  - `CajuRay`: raio paramétrico (`origin`, `direction`, `inverseDirection`, `tMin`, `tMax`) validado na construção, `point(at:)`, `intersect(_:tMaxLimit:)` via método *slab* robusto contra `0 * inf = NaN`, origem interna e AABBs de volume zero.
  - `CajuTriangle` e `CajuTriangleHit`: interseção Möller–Trumbore (`intersect(ray:twoSided:tMaxLimit:)` rejeitando triângulos degenerados), `bounds`, `overlaps(_:)` (SAT de 13 eixos), `closestPoint(to:)`, `overlapsSphere(center:radius:)`.
- **Travessia sem alocação:**
  - `CajuBVHTraversalStack`: pilha reutilizável com capacidade *inline* para 64 entradas (`SIMD16`) e crescimento em *heap* apenas acima da profundidade 64; `reset()` preserva capacidade já alocada.
- **BVH dinâmica (`CajuBVH`):**
  - Handles geracionais `CajuBVHProxy` (`isValid(_:)`, `bounds(for:)`, `userData(for:)`) e resultados `CajuBVHRayHit` / `CajuBVHSweptHit`.
  - Construção em lote com SAH *binned* (16 *bins*) via `build(from:)`; inserção incremental por custo de área + rotações (`insert(bounds:userData:)`); remoção com *free list* de nós e slots (`remove(_:)`); atualização com AABB gorda e margem (`update(_:bounds:displacement:)`); `refit()`; `clear()`; `validate()`.
  - Consultas com *visitors* não-escapantes ou preenchimento de *buffers*: `raycastFirst`, `raycastAll`, `query(overlapping:)`, `shapecast(sphereCenter:radius:)`, `shapecast(swept:displacement:)`.
- **BVH estática de triângulos (`CajuTriangleBVH`):**
  - Construção com SAH *binned* (16 *bins*, até 4 triângulos por folha) a partir de `[CajuVec3]`, `[SIMD3<Float>]` ou `packedPositions: [Float]` e `indices: [UInt32]`, validando finitude e limites de índices.
  - `triangleCount`, `isEmpty`, `bounds`, `triangle(at:)`, `validate()`, `raycastFirst`, `raycastAll` (`CajuTriangleBVHHit`), `query(overlapping:)` (SAT) e `query(overlappingSphereCenter:radius:)`.

## Como testar

Os testes ficam em `Tests/CajuModulesTests/` (`CajuPhysicsSpatialPrimitivesTests.swift`, `CajuPhysicsSpatialBVHTests.swift` e `CajuPhysicsSpatialTriangleTests.swift`) usando Swift Testing e `CajuTesting` (`CajuPCG32` e `CajuFuzz.run` com `10_000` iterações por propriedade, tolerância relativa `1e-4` para valores `Float` e igualdade exata de conjuntos de handles/índices):

```bash
swift test --filter CajuModulesTests
```

Ou na raiz do repositório:

```bash
swift test
./scripts/check-forbidden.sh
```

## Limites conhecidos

- Capacidade máxima suportada em `CajuBVH` e `CajuTriangleBVH`: `Int(Int32.max / 2)` elementos (índices internos `Int32`).
- `CajuBVHTraversalStack` evita alocações de *heap* até profundidade 64; árvores mais profundas que 64 níveis alocam no *buffer* de *overflow* na primeira ultrapassagem (reaproveitado após `reset()`).
- Componentes não-nulos subnormais em `CajuRay.direction` cujo recíproco `1.0 / component` sature em `±infinity` são tratados como paralelos (testam contenção da origem no *slab* do eixo correspondente).
- `CajuTriangle.intersect(ray:)` descarta triângulos colineares/degenerados com razão área²/arestas² `<= 1e-12` (em `Float32`) para evitar hits espúrios, e `CajuTriangleBVH` aplica folga `1e-6` na poda de AABBs durante o *raycast* para absorver arredondamento entre *slabs* e Möller–Trumbore.
- Este módulo ainda não possui alvo de benchmark ligado no `caju-bench`; números de vazão e latência de consultas permanecem não medidos (`(?)`).
