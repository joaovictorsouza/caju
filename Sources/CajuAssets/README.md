# CajuAssets

`AssetServer`, handles tipados, estados de carga e *hot reload*. Decisões: [ADR 0021](../../docs/adr/0021-assets-handles-e-ciclo-de-vida.md) (proposto).

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** A-1 (Onda 1).
- **Estado:** **contrato publicado** (tipos, protocolos e a tabela de slots); o `AssetServer` concreto (carga assíncrona, caixa de correio, *hot reload*) ainda **não** existe.

## Estável (consumidores R-1 e AN-1 podem depender)
| Tipo | O que é |
|---|---|
| `CajuAssetHandle<A>` / `CajuAnyAssetHandle` | Handle de 8 bytes (índice + geração), `BitwiseCopyable`: serve em componentes do ECS. `invalid` nunca resolve; handle velho vira `.stale` |
| `CajuAssetState` | `queued`, `loading`, `loaded`, `reloading`, `failed`, `stale`; `hasValue`, `isPending` |
| `CajuAssetEvent` | loaded / failed / reloaded / unloaded, `BitwiseCopyable` |
| `CajuAssetError`, `CajuAssetPath` | Erro tipado (embrulha `AssetError`) e caminho lógico validado |
| `CajuAssetServing` | Consultas síncronas sem alocação (`state`, `value`, `error`, `revision`), `load`, `retain`/`release`, `reload(path:)`, `applyCompletions()`, `drainEvents` |
| `CajuAssetSource`, `CajuAssetWatching`, `CajuAssetLoader` | Pontos de extensão `async` (bytes, observação de arquivos, decodificação) |
| `CajuAssetStore<A>` | Tabela de slots (geração, estados, posse, revisão) com as regras de transição; núcleo da implementação |

Regras que **não mudam sem novo ADR**: handle não é dono (posse explícita); estado só muda em `applyCompletions()`; consultas não esperam nem alocam; o valor antigo vale durante `reloading`.

## Pode mudar na implementação
Tipo concreto do servidor e seu `init`; caixa de correio (mecanismo de trava); política de cancelamento; sistema de limpeza de handles em componentes; carga síncrona de assets embutidos (`loadImmediate`); registro de `CajuAssetLoader` por tipo.

## Dependências
- `CajuCore`
- `CajuAssetsCore`
- `CajuRHI`

## Como testar
`swift test` na raiz. Os testes do contrato estão em `Tests/CajuModulesTests/CajuAssetsContractTests.swift` até existir o alvo `CajuAssetsTests` (PR dedicado ao `Package.swift`).
