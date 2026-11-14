# CajuPhysics

Integração de física com o ECS.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** Onda 1 / posterior (ver plano).
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuPhysicsModule`.

## Dependências
- `CajuCore`
- `CajuPhysicsSpatial`
- `CajuScene`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
