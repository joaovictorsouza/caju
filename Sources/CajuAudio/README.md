# CajuAudio

Áudio sobre miniaudio.

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** Onda 1 / posterior (ver plano).
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuAudioModule`.

## Dependências
- `CajuCore`
- `CajuMath`
- `CMiniaudio` (miniaudio 0.11.26 vendorizado; ADR 0005). Ainda não importado: a trilha AU-1 escreve a API.

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
