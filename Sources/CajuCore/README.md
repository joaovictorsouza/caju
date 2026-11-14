# CajuCore

ECS, agendador, tempo, mensagens e log.

- **Camada:** 0 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** TB-1.
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuCoreModule`.

## Dependências
- nenhuma

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.
