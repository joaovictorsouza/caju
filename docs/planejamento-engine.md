# Caju: planejamento da engine 3D em Swift (v2)

> **Status:** v2, integra o plano original, a discussão de arquitetura com o Argon e as decisões do dono (2026-11-14). Justificativas detalhadas ficam nos [ADRs](adr/README.md); este documento é a **visão atual**. O rascunho `engine-swift-especificacao.md` continua como **catálogo de requisitos**, não como contrato: qualquer restrição dele pode ser trocada por algo melhor.
> Estimativas marcadas com (?) não foram medidas. Nenhum código da engine existe ainda.
> Histórico: [discussao-arquitetura-argon.md](discussao-arquitetura-argon.md).

## 1. Resumo
- Engine 3D mobile-first em Swift (iOS, Android, macOS para desenvolvimento), ECS próprio, UI declarativa estilo SwiftUI, leve e medida desde o primeiro módulo.
- **GPU:** RHI próprio (Metal + Vulkan), shaders Slang offline ([ADR 0001](adr/0001-rhi-proprio.md)).
- **UI:** DSL SwiftUI-like, reatividade em lote por View, núcleo retido próprio ([ADR 0002](adr/0002-ui-declarativa.md)).
- **ECS:** 100 % Swift, híbrido (arquétipos + sparse), agendador single-thread primeiro com grafo de acesso desde o início ([ADR 0003](adr/0003-ecs-e-agendador.md)).
- **Scripts:** só embarcados e só no futuro; Luau quando vier ([ADR 0004](adr/0004-scripts.md)).
- **Dependências:** livres com critério; Foundation completo fora do caminho quente ([ADR 0005](adr/0005-dependencias-e-foundation.md)).
- **Execução:** M0 → tracer bullet + núcleos puros em paralelo → gate → trilhas por módulo ([ADR 0006](adr/0006-ordem-de-execucao.md)).
- **Aparelhos:** Galaxy S22 e iPhone 16 Pro; iOS 17 / Android API 29 ([ADR 0007](adr/0007-plataformas-e-aparelhos.md)). Android com Game Thread própria ([ADR 0008](adr/0008-android-game-thread.md)).

## 2. Princípios
1. Dados primeiro, sem alocação no caminho quente (arenas por quadro, `~Copyable`, `Span`).
2. Pague só pelo que usa: módulos opcionais por *package traits*; tamanho de binário medido em CI.
3. Núcleo puro e testável sem GPU/janela (Linux no CI).
4. Interfaces validadas por código real (tracer bullet) antes de abrir muitas trilhas.
5. Extensão por protocolo/plugin, nunca por *fork*.
6. Medir cedo: benchmarks de ECS, layout, draw calls e quadro em aparelho.
7. Dado externo é hostil: limites e *fuzz* nos parsers desde o primeiro commit.

## 3. Swift idiomático
- **Swift 6.2+**, concorrência estrita; Swift Testing; Swift SDK para Android desde o M0.
- **Parameter packs** para `Query`/`SystemParam`/`ViewBuilder` (com PoC e fallback de overloads, ADR 0003); **macros** (`@Component`, `@Message`, `@Resource`, `#shader`) para registro e reflexão estática; **`~Copyable`/`~Escapable`** para handles únicos, encoders e tokens; **`Span`/`MutableSpan`/`InlineArray`** em colunas e buffers; **typed throws** em loaders/parsers; **`sending`/`Sendable`** nas fronteiras.
- Evitar no caminho quente: `any Protocol`, `class` por entidade/componente, `Dictionary<String,_>` por quadro, `Codable` em assets pesados, `async/await` no laço.
- **Threads:** iOS/macOS laço por *display link*; **Android com Game Thread própria** (ADR 0008). O `World` é isolado por disciplina e tipos, não por ator.
- Estilo de sistema: função livre com parâmetros tipados (`Res`, `Query`, `Commands`), ordenação por `.before/.after/.runIf`.

## 4. Escopo
| Perfil | Conteúdo |
|---|---|
| **MVP** | Core/ECS/agendador, Math, Scene, Platform (iOS/Android/macOS), Input (toque + gestos básicos), RHI + Render (PBR simples, unlit, luz direcional, 1 sombra, skinning, instancing), Assets (glTF/KTX2, handles, hot reload local), Anim (clipes, player, crossfade, máscaras), UI (DSL + layout + texto latino + widgets básicos), Log/Diag, Testing, Tools (texture, validate-gltf, manifest básico), áudio via `miniaudio` |
| **v1.0** | + BVH/raycast/kinematic, rede, texto completo (RTL/CJK/emoji), acessibilidade nativa, i18n, ToonMaterial, LOD, quirks remotos, conteúdo remoto |
| **Opcional (traits)** | Camera rig/virtual cameras, máquina de estados de animação, Draco, `ViewportNode`, scripting (Luau), DoF, projeções avançadas, física dinâmica |

Adiados: camera rig completo (só `Follow`/`Orbit` sobre o protocolo `CameraBehavior`), Grid CSS, templates XML, `MeshMerge`/`AtlasMerge`, API dinâmica do `World`, WASM.

## 5. Módulos
```
Camada 0 (puros):   CajuMath   CajuCore(ECS, agendador, log)   CajuCollections
Camada 1 (puros):   CajuAssetsCore(parsers)  CajuText(shaping/medida)  CajuUILayout  CajuPhysicsSpatial(BVH)
Camada 2:           CajuPlatform  CajuRHI (+ Metal, + Vulkan)
Camada 3:           CajuScene CajuInput CajuRender CajuAssets CajuAnim CajuAudio CajuUI CajuPhysics
Camada 4:           CajuNet CajuTesting CajuTools CajuScripting(futuro)
```
Dependências só para baixo; cada módulo compila e testa isolado; sem conceitos de jogo específico nos módulos.

## 6. UI
Resumo (detalhes no ADR 0002): DSL → núcleo retido (`CajuUICore`) → layout puro → display list → RHI (SDF para retângulos/sombras, MSDF para texto, ≤ 40 draw calls). `@State` em slot table, tracking por View com `body` em lote no fim do quadro, propriedades de desenho ligadas direto ao nó. Quadro sem mudança custa só uma checagem de sujeira. Hot reload: *previews* offscreen no macOS (`ViewPreview`) e, no futuro, UI como dado. Equivalência Compose documentada (`Column`≈`VStack`, `remember`≈`@State`, `LaunchedEffect`≈`.task`). Acessibilidade: campos `role/label` no nó desde o início; espelho nativo na v1.0.

## 7. Leveza e performance
- Arquétipos SoA, *change ticks*, arenas por quadro, handles numéricos, propagação de transform por subárvore suja.
- Render: mundo de render separado com extração, *frame graph* com aliasing de memória, forward com MSAA e attachments transitórios, instancing/batching automáticos, ASTC/KTX2, geometria quantizada + meshopt, pipelines pré-compiladas e cache de PSO persistido, `UploadBudget`, modo reativo sem *submit* quando nada muda.
- Animação: amostragem SIMD, taxa reduzida, *cull* fora da tela, skinning na GPU.
- Build: traits, *dead stripping*, `-Osize` fora do caminho quente; medir tempo de compilação (packs/macros) no CI.
- Benchmarks em CI desde o primeiro módulo; regressão > 10 % bloqueia merge. Metas: NFR-008 (ECS), NFR-009 (layout), draw calls, p50/p95 de quadro nos aparelhos de referência.

## 8. Plano de execução
### M0: fundação (sequencial, 1 sessão)
`Package.swift` com todos os targets (trancado depois), CI Linux/macOS + build iOS/Android, host iOS/macOS, tipos primitivos de `CajuMath`, convenções (`CONTRIBUTING.md`, swift-format, typed throws), `CODEOWNERS`, harness de benchmark e fuzz, renomear prefixo `Caju*`.

### Onda 0.5: em paralelo (≈ 8 sessões)
| Trilha | Módulo(s) | Entrega |
|---|---|---|
| **TB-1** | `CajuCore`, `CajuScene` | ECS mínimo híbrido, `Query` com PoC de packs + SIL, agendador single-thread com validação de acesso, mensagens, estados, tempo, `@Component` com `componentID` e reflexão estática, Transform/hierarquia |
| **TB-2** | `CajuPlatform`, `CajuRHI`, backend Metal | Janela iOS/macOS, RHI com render pass + transient + frame graph, Slang → MSL, cubo e botão com texto em aparelho real |
| **TB-Android** | Platform Android, backend Vulkan | Gradle/CMake/JNI/`libswiftCore.so`, Game Thread, Vulkan próprio + VMA no S22; **timebox de 5 dias**, kill-criteria definidos antes de começar |
| **P-1** | `CajuMath` completo | SIMD, interseções, cor, easing, testes de propriedade |
| **P-2** | `CajuAssetsCore` | glTF (validação rigorosa), KTX2/Basis, meshopt, PNG/JPEG, *fuzz* |
| **P-3** | `CajuPhysicsSpatial` | BVH dinâmica, raycast/shapecast/sobreposição |
| **P-4** | `CajuUILayout` | Árvore retida, protocolo de layout SwiftUI-like, stacks/ZStack/frame/Spacer, hit-testing |
| **P-5** | `CajuText` | Shaping, medida, quebra de linha, atlas MSDF em bitmap de CPU, modelo do `TextEditor` |

P-1 a P-5 não dependem de GPU nem de ECS e têm contrato estável (dados de entrada → dados de saída), por isso rodam em paralelo desde o início.

### Gate de saída da Onda 0.5
Ver ADR 0006 (ciclos de background/resume e recriação de superfície sem vazamento, soak por aparelho com p95, TSan limpo, SIL do `Query` sem alocação, `Observation` em Android real, compilação incremental ≤ 5 s, tamanho do `.apk` medido). Números a calibrar com o S22 e o iPhone 16 Pro.

### Onda 1: integração por módulo (depende de TB-1, TB-2 e do gate)
Assets+ECS (`AssetServer`, handles, hot reload), Render completo, Input e gestos, UI integrada (DSL, widgets, batcher), Anim, Physics (ECS), Audio (`miniaudio`), Tools (texture, validate-gltf, manifest). Dentro da onda, módulos diferentes continuam paralelos (um diretório por dono).

### Depois
**Vertical slice medido** (personagem animado com skinning, UI de loja, câmera, toque; NFR-001/002/003/008/009 nos aparelhos de referência) → v1.0 (texto completo, acessibilidade, i18n, LOD, quirks, conteúdo remoto, Toon) → opcionais (camera rig, Luau, física dinâmica, backend WebGPU).

### Regras de paralelismo
1. Um diretório = um dono por vez. 2. `Package.swift` e CI trancados (PR dedicado e curto para mudar). 3. Mudança de API entre módulos: PR de contrato antes do uso. 4. Sem `Utils.swift` compartilhado. 5. Gerados em `Generated/`, determinísticos. 6. PRs pequenos, *rebase* frequente, `CODEOWNERS`. 7. ADRs e docs de arquitetura só pela sessão coordenadora; trilhas propõem em PR separado.

### O que não começa antes
Render integrado, UI integrada, animação e input integrados dependem de TB-1/TB-2 e do gate. Scripting, camera rig e otimização fina só depois do vertical slice e com benchmark.

## 9. Marcos
| Marco | Critério |
|---|---|
| M0 | Pacote compila em macOS/Linux; iOS e Android compilam; CI verde |
| M1 | Núcleos puros P-1..P-5 com testes e fuzz; benchmarks ECS/layout dentro da meta |
| M2 | Cubo texturizado e botão com texto em iPhone 16 Pro (Metal) e, se o timebox permitir, no S22 (Vulkan) |
| Gate | Critérios do ADR 0006 |
| M3 | Cena glTF com skinning e UI em demo |
| M4 | Vertical slice medido nos aparelhos de referência |
| M5 | v1.0 |
| M6 | Scripting Luau embarcado (opcional) |

## 10. Riscos
| Risco | Mitigação |
|---|---|
| Swift no Android tem arestas (SDK, build, depuração) | TB-Android com timebox e kill-criteria; iOS/macOS não esperam |
| Vulkan próprio é o maior risco de esforço | Validar no S22 cedo; reabrir ADR 0001 se estourar |
| Compilação lenta (packs/macros) | Medir no CI; fronteiras de módulo |
| Escopo do rascunho | Perfil MVP e módulos opcionais |
| ECS + concorrência estrita | PoC de `Query`/SIL antes de congelar API; TSan |
| Dependências C/C++ | Targets SwiftPM, versões fixas, CI nos SOs |
| Texto internacional | Escalonar por script; IME de plataforma no início |
| Perda de superfície/dispositivo | Testes forçados desde M2 |
| Tamanho de binário (Foundation completo no Android) | Medir no gate antes de fixar teto |

## 11. Decisões
| ID | Decisão | Estado |
|---|---|---|
| D1 | RHI próprio Metal + Vulkan, sem spike wgpu | **Decidido** |
| D2 | Núcleo retido de UI | **Decidido** (ADR 0002) |
| D3 | Reatividade em lote por View | **Decidido** (ADR 0002) |
| D4 | Scripts embarcados, no futuro | **Decidido** |
| D5 | Prefixo `Caju*` | Proposto; fazer no M0 |
| D6 | Slang | **Decidido** |
| D7 | Galaxy S22 e iPhone 16 Pro | **Decidido**; aparelho de piso sugerido |
| D8 | iOS 17 / Android API 29 | **Decidido** |

Em aberto: confirmar variante do S22 (Snapdragon ou Exynos), definir kill-criteria do TB-Android, confirmar o prefixo `Caju*`.
