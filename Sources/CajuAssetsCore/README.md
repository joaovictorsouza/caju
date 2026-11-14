# CajuAssetsCore

Parsers puros de assets (glTF, KTX2, meshopt, PNG/JPEG).

- **Camada:** 1 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** P-2.
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuAssetsCoreModule`.

## Dependências
- `CajuMath`
- `CajuCollections`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
