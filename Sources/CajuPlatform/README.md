# CajuPlatform

Janela/superfície, ciclo de vida e laço principal, independentes de plataforma; hosts por plataforma implementam `CajuPlatformHost` ([ADR 0015](../../docs/adr/0015-contrato-rhi-e-platform.md)).

- **Camada:** 2. **Trilha dona:** TB-2 (Android: TB-Android, ADR 0008). **Estado:** contrato publicado (Fase 1); implementação Apple na Fase 2.

## Peças
- `CajuPlatformSurface`, `CajuWindowConfiguration`, `CajuEdgeInsets`.
- `CajuLifecycleState`/`CajuLifecycleEvent`: máquina de estados (`active`, `inactive`, `background`, `terminated`) que tolera eventos duplicados e o pulo do Android (`background` → `didBecomeActive`).
- `CajuPlatformEvent` e `CajuEventQueue` (anel fixo; nunca perde evento de ciclo de vida).
- `CajuMainLoop<App>`: valor puro dirigido por `tick(at:)`; delta limitado e zerado depois do segundo plano; política `continuous`/`onDemand`.
- `CajuApplication` (lado do jogo) e `CajuPlatformHost` (lado da plataforma).

## Dependências
`CajuCore`.

## Como testar
`swift test` na raiz (`Tests/CajuModulesTests/CajuPlatformTests.swift`, inclui 50 ciclos de background/resume no laço puro).


## Android (TB-Android)
Parte Android, sem `CajuRHI` ([ADR 0008](../../docs/adr/0008-android-game-thread.md), [ADR 0019](../../docs/adr/0019-host-android-build-e-link.md)):
- `CajuMailbox<Event>`: anel pré-alocado e seguro entre threads (UI thread → Game Thread); sem alocação depois do `init`.
- `CajuHandshake`: a Activity espera a Game Thread soltar a janela/fila de entrada antes de devolver o controle ao sistema.
- `CajuGameThread` (pthread), `CajuAndroidGameLoop` e `CajuAndroidGameDelegate`: laço da Game Thread (bloqueia quando inativo, desenha quando há superfície e a Activity está em primeiro plano).
- `CajuAndroidEvent`, `CajuNativeWindow`, `CajuTouchEvent`: eventos de ciclo de vida/superfície/entrada.
- `#if os(Android)`: `CajuAndroidActivity.onCreate` (ponte `ANativeActivity` → `CajuMailbox`) e leitura de toques por `AInputQueue`.

Integração pendente com o contrato do TB-2 (ADR 0015): a Game Thread deve alimentar o `CajuMainLoop` com `CajuPlatformEvent`; os tipos do Android têm nomes próprios (`CajuAndroidEvent`, `CajuMailbox`) para não colidir.

