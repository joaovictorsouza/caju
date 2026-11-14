# CajuPlatform

Janela, ciclo de vida e laço principal por plataforma.

- **Camada:** 2 (dependências só para baixo; ver §5 do plano).
- **Trilha dona:** TB-2.
- **Estado:** apenas declarado (M0); sem API pública além do marcador `CajuPlatformModule`.

## Dependências
- `CajuCore`

## Como testar
`swift test` na raiz; o alvo `CajuModulesTests` garante que o módulo compila e linka.

## Android (TB-Android)
Parte Android, sem `CajuRHI` ([ADR 0008](../../docs/adr/0008-android-game-thread.md), [ADR 0019](../../docs/adr/0019-host-android-build-e-link.md)):
- `CajuMailbox<Event>`: anel pré-alocado e seguro entre threads (UI thread → Game Thread); sem alocação depois do `init`.
- `CajuHandshake`: a Activity espera a Game Thread soltar a janela/fila de entrada antes de devolver o controle ao sistema.
- `CajuGameThread` (pthread), `CajuAndroidGameLoop` e `CajuAndroidGameDelegate`: laço da Game Thread (bloqueia quando inativo, desenha quando há superfície e a Activity está em primeiro plano).
- `CajuAndroidEvent`, `CajuNativeWindow`, `CajuTouchEvent`: eventos de ciclo de vida/superfície/entrada.
- `#if os(Android)`: `CajuAndroidActivity.onCreate` (ponte `ANativeActivity` → `CajuMailbox`) e leitura de toques por `AInputQueue`.

Integração pendente com o contrato do TB-2 (ADR 0015): a Game Thread deve alimentar o `CajuMainLoop` com `CajuPlatformEvent`; os tipos do Android têm nomes próprios (`CajuAndroidEvent`, `CajuMailbox`) para não colidir.

