# Discussão de arquitetura (Claude × Argon): resultado

Três rodadas de crítica e réplica sobre `planejamento-engine.md` e o adendo de liberdade, usando o modelo Argon pelo plugin antigravity. **Onde este documento diverge do plano, este documento prevalece.** Números marcados com (?) são estimativas **não verificadas** e devem ser medidas nos spikes.

## 1. Acordos por tema

### 1.1 GPU / RHI
- **Metal próprio** no Apple. A semântica do RHI parte de **render pass/subpass + `TransientAttachment` (memoryless)**, e não de "WebGPU-like". Metal e Vulkan são desenhados **juntos**, não "Vulkan depois".
- **Shaders: Slang offline** (MSL + SPIR-V + reflexão para structs Swift). Fecha a decisão D6.
- **Fork de `wgpu-native` descartado** (custo de Rust/cargo/NDK no build Swift). Fica como candidato no spike do Android.
- **Correção de critério:** em GPUs TBDR a perda de banda por MSAA não ocorre com clear/discard + resolve. O custo real sem memoryless é **footprint** (~96 MB para ~3 MP × 32 B (?), cerca de 1/3 do teto de 300 MB do NFR-004).
- **Spike Android (~1 semana):** Vulkan próprio + VMA vs `wgpu-native` stock. Métricas: PSS/footprint com MSAA 4x, tamanho do `.so` por ABI (teto ~3 MB), p95 de CPU com ~1000 draws, 50 ciclos de rotação/background sem vazamento. Verificar também se o wgpu atual expõe transient attachments.

### 1.2 UI
O §6.4 do plano estava tecnicamente incorreto como escrito: argumentos Swift são avaliados *eagerly* (`pressed ? 0.97 : 1`) e `withObservationTracking` é *one-shot* e dispara em `willSet`. Correção acordada:
- Núcleo retido mantido.
- **1 tracking por View**: o `onChange` só marca um bit de "suja"; `body` é reexecutado **em lote no fim do quadro**, com re-arme do tracking.
- `State` em **slot table** própria.
- Propriedades de desenho (animação, scroll, transform, opacidade) ligadas **direto ao nó retido**, sem passar por `body` (como `graphicsLayer` do Compose).
- Identidade posicional (ViewBuilder) + `ForEach(id:)` explícito, memoização por `Equatable`, `LazyVStack` virtualizado.
- D3 do plano passa a ser: *reatividade em lote por View com bindings diretos de desenho*, não "granularidade fina por propriedade".

### 1.3 ECS
- **100% Swift.** Flecs foi proposto e retirado; fica só como régua de benchmark (meta ≤ 1,2× do C).
- **Armazenamento híbrido:** arquétipos SoA + sparse/bitset para tags (arquétipo puro obriga a copiar a entidade a cada `Dead`/`Stunned`).
- **PoC de `Query` com parameter packs** e inspeção de SIL (zero `swift_allocObject`, sem witness tables) **antes** de congelar a API. Fallback: overloads gerados de aridade 1..8.
- **Agendador single-thread correto primeiro**, já validando o grafo de acesso Read/Write no registro. O pool work-stealing só entra quando o benchmark provar ganho.

### 1.4 Scripts
- **Luau embarcado, mais tarde.** **WASM sai do roadmap por ora** (binários Swift→wasm grandes, interpretador 15–30× mais lento (?), custo de cruzar memória linear).
- Fase 1 mantém só **`componentID` estável** (hash determinístico) e **tabela de reflexão estática** via `@Component`. A API dinâmica do `World` (S1 do plano) é **adiada**.
- `dlopen` só serve para funções `@_cdecl` de layout fixo no macOS; o runtime Swift não recarrega metadados de tipo, então não substitui scripting.
- App Store 2.5.2: só scripts embarcados no bundle são seguros (revisar o texto vigente antes de qualquer script remoto).

### 1.5 Trilhas e ordem de execução
A divisão em "Fase 0 + 8 trilhas cegas" foi rejeitada: "contratos antes de código" vira waterfall e contratos de RHI/UI/texto não sobrevivem ao primeiro contato com a GPU. Nova ordem:

1. **M0** (1 sessão): `Package.swift` trancado, CI Linux/macOS, host iOS/macOS, tipos primitivos de `CajuMath`.
2. **Onda 0.5**, em paralelo:
   - **Tracer bullet:** TB-1 (Core/ECS mínimo + Scene) e TB-2 (Platform + RHI + Metal + spike Android).
   - **Núcleos puros de CPU (sem GPU/ECS):** P-1 Math, P-2 parsers glTF/KTX2/meshopt (+ fuzz), P-3 BVH, P-4 UI layout, P-5 texto (shaping + atlas MSDF em bitmap de CPU).
   - **TB-Android:** trilha separada com timebox de 5 dias (Gradle/CMake/JNI/`libswiftCore`). Se travar, iOS/macOS e módulos puros seguem sem esperar.
3. **Gate de saída** (§3) e então **Onda 1** (Assets+ECS, Render completo, Input, UI, Anim, Physics, Audio, Tools).

## 2. Mudanças ao plano (por impacto)
1. Substituir "Fase 0 + 8 trilhas" por M0 → Onda 0.5 → Gate → Onda 1.
2. **Android:** laço de jogo/render em **Game Thread própria**, fora da UI thread do Java. O §3.4 (`@MainActor` para tudo) está errado para Android. Build Gradle/CMake/JNI vira trilha própria com timebox.
3. RHI redesenhado (render pass + transient) e decisão Android por spike medido.
4. Reescrever §6.4 (e D3 do §12) como em 1.2.
5. ECS híbrido, PoC de packs com SIL, agendador sequencial primeiro.
6. Slang como compilador único de shaders (fecha D6).
7. Cortar API dinâmica do `World` e WASM da Fase 1.
8. **`miniaudio`** no lugar de mixer próprio (CoreAudio + AAudio prontos).
9. Foundation completo fora do caminho quente (adendo), medindo tamanho no gate.
10. Física no MVP: só BVH de consultas; reavaliar Jolt/embree se física dinâmica entrar.
11. Itens esquecidos pelo plano: Gradle/CMake/JNI/empacotamento do `libswiftCore.so`, Game Thread no Android, `miniaudio`.

## 3. Gate de saída da Onda 0.5 (proposta)
- 50 ciclos de background/resume, rotação e recriação de superfície com ΔRSS ≤ 1 MB e zero erro de validação.
- Soak de 5 min (500 malhas instanciadas + 200 nós de UI com texto), p95 < 16 ms. **Ressalva:** parâmetros devem ser definidos por aparelho de referência (D7) e com degradação controlada (p95), não "zero throttling".
- TSan limpo em Linux/macOS; SIL do `Query` sem alocação.
- `Observation` + `FoundationEssentials` funcionando em aparelho Android real (hoje é inferência não verificada).
- Compilação incremental de módulo ≤ 5 s.
- `.apk` arm64 stripped ≤ 18 MB. **Ressalva:** incompatível com "Foundation completo" se o ICU for incluído; o teto é um número sem fonte e deve ser medido antes de virar critério.

## 4. Pontos em aberto
- Vulkan+VMA vs `wgpu-native` no Android (empírico).
- Parameter packs vs overloads gerados no `Query` (empírico).
- Kill-criteria explícitos para o bring-up Android: quando decidir que Android sai do vertical slice.
- Estimativas não verificadas: wgpu-native 1,8–3 MB por ABI (?); Vulkan próprio no Android 2–3 meses-engenheiro no escopo MVP (?); `body` < 100 ns (?); RHI próprio 7,5–11 mil LOC (?).
- Ainda valem D1 (reduzida ao spike), D4, D7 e D8 do plano.
