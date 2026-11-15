# ADR 0021: Assets: handles geracionais, estados de carga e ciclo de vida (A-1)

**Status:** Proposto (esboço do contrato; vira Aceito no merge da implementação da A-1, ou é ajustado antes disso).

## Contexto
A Onda 1 (brief `docs/briefs/onda-1.md`) exige que A-1 publique o contrato do `AssetServer` antes da implementação, porque R-1 (malhas e texturas na GPU) e AN-1 (clipes) consomem handles. O ECS guarda componentes em colunas `BitwiseCopyable` sem ARC (ADR 0014), o caminho quente não pode alocar (CLAUDE.md) e os parsers (`CajuAssetsCore`, ADR 0017) já devolvem dados validados a partir de bytes.

## Decisão
1. **Handle tipado de geração + índice** (`CajuAssetHandle<A>`, 8 bytes, `BitwiseCopyable`, `Hashable`, `Sendable`), igual ao padrão de `CajuEntity`. Geração começa em 1; `invalid` (tudo zero) nunca resolve. Handle velho nunca falha: devolve `.stale`/`nil`.
2. **O handle não é dono.** A posse é contada pelo servidor (`load` soma, `retain`/`release` ajustam); ao zerar, o slot é liberado e a geração sobe. Motivo: handle em componente não pode ter ARC. Custo: o código de jogo precisa chamar `release` (um sistema de limpeza por componente de handle fica para a implementação).
3. **Estados:** `queued → loading → loaded | failed`; `loaded → reloading → loaded`; `stale`. Falha de recarga mantém o valor antigo (erro em `error(of:)`). `revision` sobe a cada valor publicado, para consumidores recriarem recursos de GPU.
4. **Deduplicação** por (tipo, caminho lógico): o mesmo par devolve o mesmo handle.
5. **Carga fora do quadro.** `CajuAssetSource` (bytes, `async`) e `CajuAssetLoader` (decodifica com `CajuAssetsCore`, `async throws(CajuAssetError)`) rodam em tarefas fora do quadro. O resultado entra numa caixa de correio e só é aplicado em `applyCompletions()`, **uma vez por quadro, no início**. Assim o estado nunca muda no meio do quadro e as consultas não precisam de trava.
6. **Consultas síncronas e sem alocação** (`state`, `value`, `error`, `revision`), sem `await`. O servidor pertence à *thread* do jogo, como o `CajuWorld` (ADR 0003/0008).
7. **Eventos** (`CajuAssetEvent`: loaded, failed, reloaded, unloaded) `BitwiseCopyable`, entregues por `drainEvents` ou por `CajuMessageQueue`.
8. ***Hot reload* local:** `CajuAssetWatching.changes()` (só desenvolvimento) dispara `reload(path:)`; o handle é o mesmo, o valor antigo vale até a troca.
9. **Erros tipados** (`CajuAssetError`, embrulha `AssetError`). Foundation só nas implementações de `CajuAssetSource` (bordas, ADR 0005). Caminho lógico validado (`CajuAssetPath`): sem `..`, `\`, barra inicial/final ou byte nulo.

## Alternativas
- **Handle forte com ARC (`final class`):** simples, mas não cabe em coluna `BitwiseCopyable` do ECS e aloca por handle.
- **Handle por caminho (`String`):** aloca e compara strings no caminho quente.
- **`actor AssetServer`:** consultas viram `await` e quebram o quadro síncrono do ECS; a trava só é necessária na caixa de correio.
- **Entregar a carga no meio do quadro:** estado instável durante sistemas; descartado.

## Consequências
- R-1 e AN-1 podem depender já de `CajuAssetHandle`, `CajuAssetState`, `CajuAssetEvent` e `CajuAssetServing`.
- A implementação precisa de uma caixa de correio *thread-safe* sem Foundation (`Synchronization.Mutex` exige iOS 18; o mínimo é iOS 17): escolha na implementação, medida, com TSan.
- Testes do contrato ficam em `CajuModulesTests` até existir o alvo `CajuAssetsTests` (PR dedicado ao `Package.swift`).

## Quando reabrir
- Se o *release* manual se mostrar propenso a vazamento (avaliar handle forte opcional por cima do fraco).
- Se R-1 precisar de carga síncrona de asset embutido (pode virar `loadImmediate`).
- Se medição mostrar alocação na consulta de handle.
