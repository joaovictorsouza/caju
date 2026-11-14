# CajuPhysicsSpatial

BVH e consultas espaciais (raycast, shapecast).

- **Camada:** 1 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** P-3.
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuPhysicsSpatialModule`.

## Dependências
- `CajuMath`
- `CajuCollections`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
