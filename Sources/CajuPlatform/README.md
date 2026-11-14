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
