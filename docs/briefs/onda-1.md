# Briefs das trilhas da Onda 1 (proposta)

Formato da skill `caju-track-brief`. Base: plano §8 ("Onda 1"), ADR 0006 (gate), ADR 0014, 0015, 0017, 0018, 0019. Números marcados `(?)` não foram medidos. **Este brief é proposta para revisão do dono; nenhuma trilha começa antes do aceite (merge deste PR).**

## 1. Ponto de partida (estado em 2026-11-14)
A Onda 0.5 está mergeada, mas o **gate de saída do ADR 0006 não está fechado**. Pendências herdadas que a Onda 1 precisa absorver, porque bloqueiam trilhas:

| Pendência | Bloqueia | Onde entra |
|---|---|---|
| `Package.swift` trancado: alvos de teste e benchmark de P-3/P-4/P-2, alvo `CajuTools`, dependência `miniaudio` | A-1, AU-1, T-1, benchmarks | **S-0** |
| Backend Vulkan do `CajuRHI` (hoje só o triângulo do ADR 0019): falta VMA, rotação, CI do APK | R-1 em Android, gate em Android | **V-1** |
| TB-2: iPhone 16 Pro, toque e aliasing por heap sem medição (`(?)`) | R-1, I-1, gate em iOS | **S-0** (medição) |
| `Observation` em Android real, tamanho do `.apk`, compilação incremental ≤ 5 s, soak p95 | Gate | **S-0** |
| Transcodificação Basis/Zstd e pixels JPEG (ADR 0017) | A-1 (texturas) | **A-2** |
| HarfBuzz/FreeType (ADR 0012) só se o shaper puro não bastar para latino | U-1 (texto) | decisão em U-1, PR dedicado |
| Macro `@Component` adiada (exige `swift-syntax`, ADR 0014) | Ergonomia | fora da Onda 1; reavaliar no vertical slice |

Observação de numeração: o ADR 0016 (P-1) foi reservado e nunca escrito; **não reutilizar**. Os ADRs da Onda 1 começam em 0020.

## 2. Ordem e dependências
```
S-0 (sequencial, curta): Package.swift + gate + linhas de base em aparelho
        │
        ├── A-1 Assets+ECS ──────────────┐   (contrato de handles primeiro: PR de contrato)
        ├── V-1 Backend Vulkan ──────────┤
        ├── I-1 Input                    ├── R-1 Render (usa contrato do A-1; extração depende de CajuScene)
        ├── AU-1 Audio                   │        │
        ├── T-1 Tools (texture/validate) │        ├── U-1b UI integrada: batcher/render
        ├── U-1a UI núcleo (DSL, @State) ┘        │
        └── PH-1 Physics (raycast no ECS)         └── AN-1 Anim (skinning na GPU depende de R-1)
                                                       │
                                              Gate da Onda 1 → Vertical slice (M4)
```
Regra: dentro da onda, **um diretório = um dono**; mudança de API entre módulos entra em PR de contrato antes do uso. Contratos a publicar primeiro (cedo, como a Fase 1 da TB-2 fez): **A-1** (handles/`AssetServer`), **R-1** (mundo de render e extração), **U-1** (display list).

## 3. Divisão de execução (regra do dono)
Antigravity (plugin no Claude Code do Mac, via Remote Control) recebe tudo o que for código comum com contrato claro; **Hydrogen** por padrão, **Argon** só quando a trilha exigir raciocínio de arquitetura. Claude coordena, revisa e executa o que precisa de aparelho/Mac ou de decisão. Se o Claude se aproximar do limite de 5 h/semanal, mover trilhas "Claude" marcadas como *movível* para o Antigravity até o reset. **Cada trilha usa `git worktree` próprio** (lição da Onda 0.5: clone compartilhado vazou commits) e `git add <paths>`, nunca `-A`. Ao terminar, cada sessão junta na branch local `integracao/onda-1` para um único PR final; sessões que caem por limite são retomadas.

## 4. Trilhas
Todas: não tocam `Package.swift`/CI (só **S-0** e PRs dedicados), seguem `caju-new-module`, `caju-swift-quality`, `caju-testing`, `caju-docs-sync`; erros tipados; sem alocação no caminho quente; DocC e `README.md` do módulo.

| Trilha | Dono (diretórios) | Entrada → saída | Pronto quando | Executor |
|---|---|---|---|---|
| **S-0** Preparação e gate | `Package.swift`, CI, `docs/` (gate) | Pendências da Onda 0.5 → PR dedicado de pacote (alvos de teste e benchmark de P-2/P-3/P-4, `CajuTools`, `miniaudio` como target C, versões fixas) e relatório do gate | CI verde com os novos alvos; benchmarks P-3/P-4 com linha de base; 50 ciclos em iPhone 16 Pro; `Observation` no S22+; `.apk` e compilação incremental medidos; ADR 0020 (resultado do gate) | Claude (Mac/aparelhos via RC) |
| **A-1** Assets + ECS | `CajuAssets` | `CajuAssetsCore` + `CajuCore` → `AssetServer`, handles tipados (geração+índice), estados de carga, carga assíncrona fora do quadro, *hot reload* local | Testes headless com assets sintéticos; fuzz herdado de P-2; sem alocação na consulta de handle (SIL); handles `Sendable` corretos, TSan limpo; **ADR 0021** (modelo de handles/ciclo de vida) | Argon (contrato) → Hydrogen (loaders) |
| **A-2** Texturas | `CajuAssetsCore` (só PR dedicado se houver dependência C) | KTX2 → transcodificação Basis/Zstd; JPEG pixels | Fuzz sem crash/OOB; limites antes de alocar; dependência C via PR de `Package.swift` (ADR 0005); **ADR 0022** se mudar a decisão do ADR 0017 | Hydrogen |
| **R-1** Render | `CajuRender` | `CajuScene` + assets → mundo de render separado com extração, *frame graph* real, unlit + PBR simples, luz direcional, 1 sombra, instancing/batching, skinning (GPU), cache de PSO | Goldens Metal (e Vulkan quando V-1 fechar); benchmark de CPU da extração; draw calls medidos; sem alocação no quadro estável; **ADR 0023** (extração/mundo de render). Divide em **R-1a** (extração + unlit/PBR + luz) e **R-1b** (sombra, instancing, skinning) | Claude (R-1a, *movível* após contrato) / Argon (R-1b) |
| **V-1** Backend Vulkan | `CajuRHIVulkan`, parte Android de `CajuPlatform`, `Hosts/Android` | Contrato do ADR 0015 + triângulo do ADR 0019 → `CajuRHI` completo em Vulkan (VMA, render pass, transient, swapchain com rotação/recriação) | Mesmos goldens de conformidade do Metal; 50 ciclos de background/resume/rotação no S22+ (ΔRSS ≤ 1 MB, zero erro de validação); CI do APK; **ADR 0024** (VMA e sincronização) | Claude (aparelho) |
| **I-1** Input | `CajuInput` | Eventos de `CajuPlatform` → toque, *pointer* unificado, reconhecedores (tap, long press, pan, pinch), integração ao ECS como mensagens | Máquinas de estado testadas headless com sequências sintéticas e *fuzz* de eventos; latência de despacho sem alocação; **ADR 0025** só se o modelo de eventos mudar | Hydrogen |
| **U-1a** UI núcleo | `CajuUI` (DSL, `@State`, núcleo retido) | `CajuUILayout` + `CajuText` → DSL, `ViewBuilder`, slot table, reatividade em lote por View, widgets básicos (ADR 0002), display list | Testes headless; quadro sem mudança só checa sujeira (zero alocação); layout 1 000 nós < 1 ms `(?)`; **ADR 0026** (display list e contrato com o batcher). Sem pack no caminho quente (lição do ADR 0014) | Argon → Hydrogen (widgets) |
| **U-1b** UI render | `CajuUI` (batcher, SDF/MSDF) | Display list + RHI → batcher, SDF para retângulos/sombras, MSDF para texto | ≤ 40 draw calls na tela de loja `(?)`; goldens; depende de R-1a (contrato) | Claude |
| **AN-1** Animação | `CajuAnim` | glTF (via A-1) + `CajuMath` → clipes, player, crossfade, máscaras, amostragem SIMD, pose para skinning | Testes de propriedade (interpolação, normalização de `Quat`); benchmark de amostragem `(?)`; *cull* fora da tela; **ADR 0027** (formato de pose e fronteira com R-1b) | Hydrogen |
| **PH-1** Physics (ECS) | `CajuPhysics` | `CajuPhysicsSpatial` + `CajuScene` → *raycast*/*shapecast* como consulta do ECS, *picking* por toque, kinematic simples | Teste contra força bruta no mundo ECS; sem alocação por consulta; física dinâmica **fora** (opcional) | Hydrogen |
| **AU-1** Audio | `CajuAudio` | `miniaudio` (target C via S-0) → engine de áudio, fontes 2D/3D, mixagem, pausa/resume com o ciclo de vida | Teste de ciclo de vida headless (dispositivo nulo); sem alocação no *callback* de áudio; **ADR 0028** (política de áudio e dependência) | Hydrogen |
| **T-1** Tools | `Sources/CajuTools` (alvo novo em S-0) | CLI: `texture` (KTX2/ASTC), `validate-gltf`, `manifest` básico | Testes com *goldens* de saída; fuzz do `validate-gltf` (reaproveita P-2); saída determinística | Hydrogen |

## 5. Gate de saída da Onda 1 (proposta; números a calibrar)
1. Cena glTF com skinning e UI integrada rodando em **iPhone 16 Pro e S22+** (marco M3).
2. Goldens de conformidade iguais em Metal e Vulkan.
3. TSan limpo; SIL das consultas de handle e do `Query` sem alocação; zero alocação por quadro estável.
4. p50/p95 de quadro, draw calls e memória medidos nos dois aparelhos (`docs/standards/performance.md`); regressão > 10 % bloqueia.
5. Tempo de compilação incremental e tamanho do `.apk` dentro do teto definido em S-0.

Depois do gate: **vertical slice** (personagem animado, UI de loja, câmera, toque; marco M4).

## 6. Riscos e kill-criteria
- **Gate da Onda 0.5 aberto:** se S-0 mostrar vazamento ou p95 ruim em aparelho, R-1 em Android para até corrigir; iOS/macOS e trilhas puras seguem.
- **V-1 estourar:** se o backend Vulkan completo passar de 2 semanas `(?)` sem os goldens, abrir ADR para reavaliar o ADR 0001 (D1 só reabre por problema grave).
- **Contratos mudando sob as trilhas:** A-1, R-1 e U-1 publicam contrato em PR draft antes de implementar; consumidores só começam depois.
- **Limite de uso do Claude:** R-1a, A-1 (contrato) e U-1b são as trilhas candidatas a mover para Argon/Hydrogen.
- **`Package.swift` como gargalo:** tudo que precisar dele é agrupado em S-0; pedidos novos viram PR curto e dedicado.
- **Swift indisponível no ambiente de nuvem:** testes rodam no Mac ou no CI; números ficam `(?)` até medir.

## 7. ADRs reservados
0020 gate/S-0, 0021 A-1, 0022 A-2, 0023 R-1, 0024 V-1, 0025 I-1, 0026 U-1, 0027 AN-1, 0028 AU-1, 0029 PH-1/T-1 (reserva; usar só se houver decisão). Quem não tomar decisão nova não escreve ADR.

## 8. Documentos que este brief atualiza (neste PR)
Plano (§8 "Onda 1": link para este brief e ordem) e `docs/adr/README.md` (nota dos números reservados). Cada trilha atualiza plano, ADR, standards e README do módulo no próprio PR.

## 9. Perguntas para o dono
1. S-0 antes de todas as outras, ou deixamos A-1/I-1/AU-1 já começarem em paralelo e S-0 só abre o `Package.swift` quando houver pedido acumulado? (Proposta: S-0 primeiro, em dias; as trilhas puras de Hydrogen começam já com contrato em PR draft.)
2. Física dinâmica e `@Component` por macro seguem fora da Onda 1?
3. `miniaudio` e eventual HarfBuzz/FreeType: aprova a política do ADR 0005 (target C, versão fixa, PR dedicado)?
