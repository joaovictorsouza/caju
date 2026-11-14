# CajuAssets

AssetServer, handles e hot reload.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** Onda 1 / posterior (ver plano).
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuAssetsModule`.

## Dependências
- `CajuCore`
- `CajuAssetsCore`
- `CajuRHI`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
