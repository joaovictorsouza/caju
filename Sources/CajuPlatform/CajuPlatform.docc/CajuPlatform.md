# ``CajuPlatform``

Superfície, ciclo de vida e laço principal independentes de plataforma.

## Visão geral

A plataforma traduz notificações nativas em ``CajuPlatformEvent``; ``CajuMainLoop`` mantém o estado (``CajuLifecycleState``) e chama ``CajuApplication/update(_:)`` a cada *tick* quando há superfície e o app está ativo.

## Tópicos

### Laço
- ``CajuMainLoop``
- ``CajuApplication``
- ``CajuPlatformHost``

### Ciclo de vida
- ``CajuLifecycleState``
- ``CajuLifecycleEvent``
- ``CajuPlatformEvent``
