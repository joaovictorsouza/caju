# CajuPhysicsSpatial

BVH e consultas espaciais (`raycast`, `shapecast`, sobreposição).

- **Camada:** 1 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** P-3.
- **Estado:** implementada (`CajuAABB`, `CajuRay`, `CajuBVH`, `CajuTriangle`, `CajuTriangleBVH`, `CajuBVHTraversalStack`, `CajuSpatialError`), mantendo `CajuPhysicsSpatialModule`.

## Dependências
- `CajuMath`
- `CajuCollections` (declarada no manifesto; sem uso nesta versão)
- Sem `Foundation`, `Glibc` ou `Darwin`.

## API pública
- `CajuSpatialError`: erros tipados (`nonFiniteBounds`, `invalidBounds`, `nonFiniteRay`, `zeroDirectionRay`, `invalidRayRange`, `nonFiniteSphere`, `invalidRadius`, `nonFiniteVector`, `nonFiniteVertex`, `invalidVertexCoordinateCount`, `invalidTriangleIndexCount`, `invalidTriangleIndex`, `invalidHandle`, `capacityExceeded`).
- `CajuAABB`: caixa delimitadora (`SIMD3<Float>`) com `init` validado, `center`, `surfaceArea`, `union`, `overlaps`, `contains`, `enlarged(margin:)`, `intersect(ray:)` (slab robusto para raios paralelos/`0 * inf`, origem interna e volume zero) e `intersects(sphereCenter:radius:)`.
- `CajuRay`: raio paramétrico validado (`origin`, `direction`, `inverseDirection`, `tMin`, `tMax`, `point(at:)`).
- `CajuBVHTraversalStack`: pilha reutilizável com buffer inline de 64 `Int32` (crescimento em heap apenas se a profundidade ultrapassar 64).
- `CajuBVH<UserData>`: BVH dinâmica com handles versionados (`CajuBVHProxy`), construção em lote SAH com 16 bins (`build(from:)`), `insert`, `remove` (free list com reuso de slots), `update` (AABB gorda com margem e reinserção só ao escapar), `refit`, `validate()`, `raycastFirst`, `raycastAll`, `query(overlapping:)`, `query(sphereCenter:radius:)` e `query(sweptAABB:displacement:)`.
- `CajuTriangle` e `CajuTriangleBVH`: interseção Möller–Trumbore (`intersect(ray:twoSided:)`), testes exatos de sobreposição com AABB e esfera, e BVH estática com SAH (16 bins), `validate()`, `raycastFirst`, `raycastAll`, `query(overlapping:)` e `query(sphereCenter:radius:)`.

## Como testar
- `swift test` na raiz (suítes em `Tests/CajuModulesTests/`, incluindo propriedade contra força bruta com `CajuFuzz.run(iterations: 10_000)` e casos degenerados).
- `scripts/check-forbidden.sh` e `swift format lint --strict -r Sources/CajuPhysicsSpatial Tests/CajuModulesTests`.

## Limites conhecidos
- `CajuBVHTraversalStack` evita alocação em árvores até 64 níveis de profundidade `(?)`; árvores mais profundas usam overflow em array reutilizável.
- Índices internos de nós usam `Int32` (limite teórico de ~2 bilhões de nós; `capacityExceeded` ao exceder `maxCapacity` ou `Int32.max`).
- Ainda sem medição em `caju-bench` (o alvo `CajuBenchmarks` depende apenas de `CajuMath`/`CajuCore`); tempos de construção e consulta ficam pendentes de medição `(?)`.
