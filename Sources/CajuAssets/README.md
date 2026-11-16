# CajuAssets

`CajuAssetServer` (`AssetServer`), handles tipados, estados de carga, *hot reload* local e integração de posse com o ECS. Decisões: [ADR 0021](../../docs/adr/0021-assets-handles-e-ciclo-de-vida.md) (aceito).

- **Camada:** 3 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** A-1 (Onda 1).
- **Estado:** **implementado** (contrato + `CajuAssetServer`, caixa de correio *thread-safe*, fontes sintética e local com *hot reload* por `mtime`, rastreador de handles em componentes ECS).

## API estável (consumidores R-1 e AN-1 podem depender)
| Tipo | O que é |
|---|---|
| `CajuAssetHandle<A>` / `CajuAnyAssetHandle` | Handle de 8 bytes (índice + geração), `BitwiseCopyable`: serve em componentes do ECS. `invalid` nunca resolve; handle velho vira `.stale` |
| `CajuAssetState` | `queued`, `loading`, `loaded`, `reloading`, `failed`, `stale`; `hasValue`, `isPending` |
| `CajuAssetEvent` | loaded / failed / reloaded / unloaded, `BitwiseCopyable` |
| `CajuAssetError`, `CajuAssetPath` | Erro tipado (embrulha `AssetError`) e caminho lógico validado |
| `CajuAssetServing` | Consultas síncronas sem alocação (`state`, `value`, `error`, `revision`), `load`, `retain`/`release`, `reload(path:)`, `applyCompletions()`, `drainEvents` |
| `CajuAssetSource`, `CajuAssetWatching`, `CajuAssetLoader` | Pontos de extensão `async` (bytes, observação de arquivos, decodificação) |
| `CajuAssetStore<A>` | Tabela de slots (geração, estados, posse, revisão) com as regras de transição |

Regras que **não mudam sem novo ADR**: handle não é dono (posse explícita); estado só muda em `applyCompletions()`; consultas não esperam nem alocam; o valor antigo vale durante `reloading`.

## Implementação entregue
| Tipo | Papel |
|---|---|
| `CajuAssetServer` (`AssetServer`) | Implementa `CajuAssetServing`, registra `CajuAssetLoader` por tipo (`registerLoader`), agenda leitura/decodificação em `Task.detached`, aplica conclusões e descargas em `applyCompletions()`, e encaminha eventos via `drainEvents(into: CajuMessageQueue<CajuAssetEvent>)` |
| `CajuMemoryAssetSource` | Fonte de bytes sintética em memória (`CajuAssetWatching`) para testes determinísticos e ferramentas headless |
| `CajuFileAssetSource` | Fonte local via POSIX (`open`/`fstat`/`read`) com verificação prévia de `AssetLimits.maxInputBytes` e *hot reload* por polling de `mtime`/tamanho em `changes()`, sem Foundation nem dependências externas |
| `CajuAssetComponent`, `CajuAssetHandleTracker<C>` | Sincroniza `retain`/`release` de handles guardados em componentes do `CajuWorld` sem alocação no quadro estável |

## Decisões e pendências
- Caixa de correio *thread-safe* implementada com `pthread_mutex_t` (`CajuPosixLock`), evitando `Synchronization.Mutex` (exige iOS 18, acima do mínimo iOS 17) e mantendo o núcleo livre de Foundation (ADR 0005).
- Carga síncrona de assets embutidos (`loadImmediate`) não entrou ainda; abrir se R-1 precisar.
- Alvo dedicado `CajuAssetsTests` aguarda PR dedicado ao `Package.swift`.

## Dependências
- `CajuCore`
- `CajuAssetsCore`
- `CajuRHI`

## Como testar
Os testes ficam em `Tests/CajuModulesTests/` (`CajuAssetsContractTests.swift` e `CajuAssetServerTests.swift`) até existir o alvo `CajuAssetsTests`:
- `swift test --filter "CajuAssetsContractTests|CajuAssetServerTests"`
- `swift test --sanitize=thread --filter "CajuAssetsContractTests|CajuAssetServerTests"`
