# CajuRHIMetal

Backend Metal do RHI (Apple).

- **Camada:** 2 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** TB-2.
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuRHIMetalModule`.

## Dependências
- `CajuRHI`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
