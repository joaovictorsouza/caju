# ADRs (Architecture Decision Records)

Uma página curta por decisão. Formato: **Status**, **Contexto**, **Decisão**, **Alternativas**, **Consequências**, **Quando reabrir**. Datas em 2026-11-14 salvo indicação. Estimativas marcadas com (?) não foram medidas. ADRs não se apagam: se a decisão muda, escreva ADR novo que substitui e marque o antigo.

| ADR | Tema | Status |
|---|---|---|
| [0001](0001-rhi-proprio.md) | GPU: RHI próprio (Metal + Vulkan) e Slang | Aceito |
| [0002](0002-ui-declarativa.md) | UI declarativa e reatividade | Aceito |
| [0003](0003-ecs-e-agendador.md) | ECS híbrido e agendador single-thread primeiro | Aceito |
| [0004](0004-scripts.md) | Scripts: embarcados, adiados, Luau | Aceito |
| [0005](0005-dependencias-e-foundation.md) | Política de dependências e Foundation | Aceito |
| [0006](0006-ordem-de-execucao.md) | Ordem de execução: M0, tracer bullet, núcleos puros, gate | Aceito |
| [0007](0007-plataformas-e-aparelhos.md) | Plataformas, SO mínimo e aparelhos de referência | Aceito |
| [0008](0008-android-game-thread.md) | Android: Game Thread própria e build nativo | Aceito |
| [0009](0009-qualidade-e-padroes.md) | M-1: qualidade e padrões antes de começar | Aceito |
| [0010](0010-fundacao-m0.md) | Fundação do M0: pacote, CI, host, prefixo `Caju*` | Aceito |
| [0011](0011-kill-criteria-tb-android.md) | Kill-criteria do TB-Android (limite de 3 dias) | Aceito |
| [0012](0012-texto-p5.md) | Texto do MVP (P-5): TrueType em Swift, shaper plugável, MSDF em CPU | Aceito |
| [0013](0013-layout-de-ui-por-faixas.md) | Layout de UI por faixas de tamanho (P-4) | Aceito |
| [0014](0014-ecs-query-e-component.md) | ECS da TB-1: Query por aridade 1..8 e Component por protocolo | Aceito |
| [0015](0015-contrato-rhi-e-platform.md) | Contrato do RHI e da Platform (TB-2, Fase 1) | Aceito |
| [0017](0017-parsers-de-assets-puros.md) | Parsers de assets em Swift puro; Basis/JPEG pixels fora | Aceito |
| [0018](0018-bvh-e-primitivas-espaciais.md) | P-3: BVH dinâmica, primitivas espaciais e consultas sem alocação | Aceito |
| [0019](0019-host-android-build-e-link.md) | Host Android: NativeActivity em Swift, `CVulkan` e link com o NDK | Aceito |
| [0020](0020-macro-component.md) | Macro `@Component(id:)` com `swift-syntax` | Aceito |
