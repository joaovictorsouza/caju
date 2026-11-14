# CajuScene

Transform, hierarquia e cena sobre o ECS.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** TB-1.
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuSceneModule`.

## Dependências
- `CajuCore`
- `CajuMath`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
