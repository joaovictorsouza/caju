# CajuMath

Matemática 3D de `Float` (SIMD, mão direita, coluna-maior `M * v`). Sem Foundation (libc via `CajuLibm.swift`), sem alocação, sem `!`/`try!`/`fatalError`: operações que podem falhar devolvem `nil`.

- **Layout:** todos os tipos POD (`CajuVec2/3/4`, `CajuQuat`, `CajuMat4`, `CajuColor`, volumes e `CajuRay`) são `BitwiseCopyable`, para uso em armazenamento do ECS (pedido da TB-1).
- **Camada:** 0 (puro, sem dependências).
- **Trilha dona:** P-1.
- **Estado:** P-1 entregue (ver abaixo). Tolerância numérica nos testes: 1e-5 (relativa).

## API pública
| Arquivo | Conteúdo |
|---|---|
| `CajuScalar.swift` | `lerp`, `clamp`, `saturate`, `smoothstep`, `inverseLerp`, `remap`, graus↔radianos, `approximatelyEqual` |
| `CajuVec.swift` | `CajuVec2/3/4`: operadores, `dot`/`cross`, `length`, `normalized()`, `distance`, `lerp`, `clamp`, min/max/abs/floor/ceil, `reflect`, `project`, `angle(to:)`, base ortonormal |
| `CajuMat4.swift` | `CajuMat4`: TRS, `inverse`, `inverseAffine`, `determinant`, `decompose()`, `lookAt`, `perspective`/`orthographic` (profundidade 0…1), `transformPoint/Direction` |
| `CajuQuat.swift` | `CajuQuat`: eixo-ângulo (de/para), de/para matriz, yaw-pitch-roll, `slerp`/`nlerp`, `init?(from:to:)`, `lookRotation`, `inverse` |
| `CajuIntersect.swift` | `CajuRay`, `CajuAABB`, `CajuSphere`, `CajuPlane`, `CajuFrustum`: raio×AABB/esfera/plano/triângulo (Möller–Trumbore), AABB/esfera/plano entre si |
| `CajuColor.swift` | `CajuColor` (linear): sRGB↔linear, hex, HSV, `lerp`, `premultiplied`, `luminance` |
| `CajuEasing.swift` | `CajuEasing` (31 curvas) e `cubicBezier` |

## Como testar
`swift test --filter CajuMathTests` (propriedade com PCG semeado, 10 000 casos por teste) e
`swift run -c release caju-bench` para o harness de benchmark.

## Benchmarks (`caju-bench`, suíte `CajuMath`)
Medido em Apple M1 (macOS, `swift run -c release caju-bench`, menor de 5 amostras, 1 execução; **não** é linha de base de aparelho de referência):

| Operação | ns/op |
|---|---|
| `mat4.mul` | 4,0 |
| `mat4.inverse` | 22,0 |
| `mat4.inverseAffine` | 16,8 |
| `quat.slerp` | 24,8 |
| `ray.intersects(aabb)` | 7,5 |
| `ray.intersectsTriangle` | 12,5 |

Pendente: medir em iPhone 16 Pro / Galaxy S22 (ADR 0007) para o gate de 10 %.
