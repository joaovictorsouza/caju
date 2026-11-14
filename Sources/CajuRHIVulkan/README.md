# CajuRHIVulkan

Backend Vulkan do RHI (Android/Linux).

- **Camada:** 2 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** TB-Android.
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuRHIVulkanModule`.

## Dependências
- `CajuRHI`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
