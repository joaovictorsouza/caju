# CajuUILayout

Árvore retida e layout de UI, sem GPU.

- **Camada:** 1 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** P-4.
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuUILayoutModule`.

## Dependências
- `CajuMath`
- `CajuCollections`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
