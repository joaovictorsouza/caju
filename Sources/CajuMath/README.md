# CajuMath

Tipos matemáticos primitivos: `CajuVec2/3/4`, `CajuQuat`, `CajuMat4` (SIMD, `Float`, coluna-maior).

- **Camada:** 0 (puro, sem dependências, sem Foundation; `sinf`/`cosf` da libc).
- **Trilha dona:** P-1 (Math completo: interseções, cor, easing, `CajuMat4` inverso etc.).
- **Estado:** tipos primitivos do M0. Divergências numéricas toleradas nos testes: 1e-5 (relativo).

## Como testar
`swift test --filter CajuMathTests` (propriedade com PCG semeado, 10 000 casos por teste) e
`swift run -c release caju-bench` para o harness de benchmark.
