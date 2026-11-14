# CajuTesting

Utilitários de teste: `CajuPCG32` (PRNG semeável) e `CajuFuzz.run` (laço de *fuzz* reproduzível).

- **Camada:** 4. **Dependências:** `CajuCore`.
- **Estado:** M0 entrega PRNG e *fuzz*; `TestApp`/`NullRenderer` chegam na trilha dona (ver plano).

## Como testar
`swift test --filter CajuTestingTests`.
