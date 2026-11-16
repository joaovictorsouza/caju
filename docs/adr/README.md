# ADRs (Architecture Decision Records)

Uma página curta por decisão. Formato: **Status**, **Contexto**, **Decisão**, **Alternativas**, **Consequências**, **Quando reabrir**. Datas em 2026-11-14 salvo indicação. Estimativas marcadas com (?) não foram medidas. ADRs não se apagam: se a decisão muda, escreva ADR novo que substitui e marque o antigo.

| ADR | Tema | Status |
|---|---|---|

**Números reservados:** 0016 (P-1, nunca escrito, não reutilizar); 0020 a 0029 para a Onda 1 (0021 já em uso pela A-1) (ver [briefs/onda-1.md](../briefs/onda-1.md)); usar só se houver decisão. O 0030 é da macro `@Component` (PR #20, fora das trilhas da Onda 1).

**Números reservados:** 0016 (P-1, nunca escrito, não reutilizar); 0021, 0022, 0024 a 0026, 0028 e 0029 para a Onda 1 (0023 já usado: R-1; 0027 já usado: AN-1) (ver [briefs/onda-1.md](../briefs/onda-1.md)); usar só se houver decisão. O 0030 é da macro `@Component` (PR #20, fora das trilhas da Onda 1).
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
| [0019](0019-host-android-build-e-link.md) | Host Android: NativeActivity em Swift, `CVulkan` e link com o NDK | Aceito (link manual substituído pelo 0024) |
| [0020](0020-gate-da-onda-0-5.md) | Resultado do gate de saída da Onda 0.5 (S-0): medidas e teto do `.apk` | Aceito (parcial) |
| [0021](0021-assets-handles-e-ciclo-de-vida.md) | Assets: handles geracionais, estados de carga e ciclo de vida (A-1) | Aceito |
| [0023](0023-mundo-de-render-e-extracao.md) | R-1: mundo de render separado, extração e draw list | Aceito |
| [0024](0024-vulkan-vma-e-sincronizacao.md) | Backend Vulkan do `CajuRHI`: VMA, ligação de recursos, layouts e swapchain | Aceito |
| [0026](0026-ui-display-list-e-dsl.md) | Display list da UI e contrato da DSL (U-1) | Proposto |
| [0027](0027-formato-de-pose-e-fronteira-r1b.md) | AN-1: formato de pose em espaço do modelo, arena e fronteira com R-1b | Proposto |
| [0028](0028-audio-miniaudio.md) | Política de áudio e dependência sobre miniaudio (AU-1) | Aceito |
| [0030](0030-macro-component.md) | Macro `@Component(id:)` com `swift-syntax` | Aceito |

**Números reservados:** 0016 (P-1, nunca escrito, não reutilizar); 0020 a 0029 para a Onda 1 (ver [briefs/onda-1.md](../briefs/onda-1.md)); usar só se houver decisão (0026 já em uso, Proposto, pelo contrato U-1). O 0030 é da macro `@Component` (PR #20, fora das trilhas da Onda 1).
